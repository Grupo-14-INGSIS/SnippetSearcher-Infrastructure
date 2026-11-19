#!/usr/bin/env bash
# Ciclo de vida de los 5 stacks de Swarm (infra, accessmanager, runner, app, ui) al apagar y
# prender la VM (lo corre systemd, ver snippetsearcher-lifecycle.service).
#
#   stop  -> al apagar, ANTES de que se detenga Docker: guarda las réplicas de cada servicio y los
#            baja en orden (aplicación primero, después bases), esperando a que Swarm termine de
#            limpiar. Sin esto, Docker se apagaba con limpiezas de Swarm a medio hacer ("remove task
#            failed ... context canceled") y al prender algunos servicios quedaban sin nombre en el
#            DNS interno (UnknownHostException).
#   start -> al prender: restaura las réplicas y revisa que cada servicio que está corriendo resuelva
#            por nombre; a los que no, les hace `docker service update --force` (los vuelve a registrar).
#
# No necesita ningún archivo del proyecto: trabaja sobre los servicios que ya tiene Swarm. El estado
# (réplicas guardadas) va a /var/lib/snippetsearcher, no al home.
#
# Uso manual:  sudo snippetsearcher-lifecycle.sh stop|start|check
set -uo pipefail

STACKS="infra accessmanager runner app ui"
STATE_DIR="/var/lib/snippetsearcher"
STATE_FILE="$STATE_DIR/replicas"
# Orden de apagado: lo que depende de otros primero, las bases y el almacenamiento al final
APP_SERVICES="infra_certbot infra_reverse-proxy ui_snippetsearcher-ui app_snippetsearcher-app runner_snippetsearcher-runner accessmanager_snippetsearcher-accessmanager"
INFRA_SERVICES="infra_nginx-logs infra_dns-watchdog infra_asset-service infra_azurite infra_redis app_appdb runner_runner-db accessmanager_accessmanager-db"

# Servicios que se prueban por DNS en la red compartida (snippetsearcher-net) vs red privada de su stack
SHARED_PROBES="infra_redis app_snippetsearcher-app runner_snippetsearcher-runner accessmanager_snippetsearcher-accessmanager"
SHARED_SERVICES="infra_redis infra_asset-service infra_reverse-proxy ui_snippetsearcher-ui app_snippetsearcher-app runner_snippetsearcher-runner accessmanager_snippetsearcher-accessmanager"
PRIVATE_SERVICES="app_appdb runner_runner-db accessmanager_accessmanager-db infra_azurite"

log() { echo "[snippetsearcher-lifecycle] $*"; }

swarm_active() { [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" = "active" ]; }

service_exists() { docker service inspect "$1" >/dev/null 2>&1; }

running_containers() {
    # Contenedores corriendo de un servicio (<stack>_<svc>), o de todos los stacks si no se pasa argumento
    if [ $# -eq 0 ]; then
        local s
        for s in $STACKS; do
            docker ps -q --filter "label=com.docker.stack.namespace=$s"
        done
    else
        docker ps -q --filter "label=com.docker.swarm.service.name=$1"
    fi
}

scale_down() {
    local group="$1" svc
    for svc in $group; do
        service_exists "$svc" || continue
        docker service scale -d "${svc}=0" >/dev/null && log "bajando $svc"
    done
    # Esperar a que se detengan sus contenedores (máximo 2 minutos por grupo)
    local deadline=$((SECONDS + 120)) left
    while :; do
        left=0
        for svc in $group; do
            [ -n "$(running_containers "$svc")" ] && left=$((left + 1))
        done
        [ "$left" -eq 0 ] && break
        [ $SECONDS -ge $deadline ] && { log "timeout esperando que bajen $left servicio(s) de: $group"; break; }
        sleep 2
    done
}

cmd_stop() {
    swarm_active || { log "Swarm no está activo: nada que hacer"; return 0; }
    mkdir -p "$STATE_DIR"
    # Guardar réplicas solo si hay algo levantado (si se llama dos veces no pisa el estado con ceros)
    local tmp svc n
    tmp="$(mktemp)"
    for svc in $APP_SERVICES $INFRA_SERVICES; do
        service_exists "$svc" || continue
        n="$(docker service inspect "$svc" --format '{{if .Spec.Mode.Replicated}}{{.Spec.Mode.Replicated.Replicas}}{{end}}')"
        [ -n "$n" ] && [ "$n" -gt 0 ] && echo "$svc $n" >> "$tmp"
    done
    if [ -s "$tmp" ]; then mv "$tmp" "$STATE_FILE"; log "réplicas guardadas: $(tr '\n' ' ' < "$STATE_FILE")"; else rm -f "$tmp"; fi

    scale_down "$APP_SERVICES"
    scale_down "$INFRA_SERVICES"
    # Margen para que Swarm termine de borrar tareas y desarmar endpoints de red antes de que
    # systemd detenga Docker
    sleep 15
    log "stacks detenidos en orden"
}

wait_for_swarm() {
    local deadline=$((SECONDS + 300))
    until swarm_active; do
        [ $SECONDS -ge $deadline ] && { log "Swarm no quedó activo en 5 minutos"; return 1; }
        sleep 3
    done
}

restore_replicas() {
    [ -s "$STATE_FILE" ] || { log "sin réplicas guardadas (apagado sin el script): se dejan como están"; return 0; }
    local svc n group
    # Primero bases y almacenamiento, después la aplicación
    for group in "$INFRA_SERVICES" "$APP_SERVICES"; do
        for svc in $group; do
            n="$(awk -v s="$svc" '$1 == s { print $2 }' "$STATE_FILE")"
            [ -n "$n" ] && service_exists "$svc" && docker service scale -d "${svc}=$n" >/dev/null && log "subiendo $svc a $n"
        done
        sleep 20
    done
    rm -f "$STATE_FILE"
}

# Un contenedor corriendo en la red compartida que tenga `getent`.
shared_probe_container() {
    local psvc c
    for psvc in $SHARED_PROBES; do
        for c in $(running_containers "$psvc"); do
            docker exec "$c" getent hosts localhost >/dev/null 2>&1 && { echo "$c"; return 0; }
        done
    done
    return 1
}

# Un contenedor corriendo dentro de un stack específico que tenga `getent`.
stack_probe_container() {
    local stack="$1" c
    for c in $(docker ps -q --filter "label=com.docker.stack.namespace=$stack"); do
        docker exec "$c" getent hosts localhost >/dev/null 2>&1 && { echo "$c"; return 0; }
    done
    return 1
}

# Repara los servicios que están corriendo pero no resuelven (tanto en la red compartida como
# en la red privada de cada stack).
check_dns_once() {
    local probe sprobe svc stack name broken=0
    probe="$(shared_probe_container)" || { log "todavía no hay un contenedor compartido para probar el DNS"; return 1; }

    for svc in $SHARED_SERVICES; do
        [ -z "$(running_containers "$svc")" ] && continue
        name="${svc#*_}"
        if ! docker exec "$probe" getent hosts "$name" >/dev/null 2>&1; then
            log "$svc ($name) corre pero no resuelve en el DNS compartido: docker service update --force"
            docker service update --force -d "$svc" >/dev/null
            broken=$((broken + 1))
        fi
    done

    for svc in $PRIVATE_SERVICES; do
        [ -z "$(running_containers "$svc")" ] && continue
        stack="${svc%%_*}"
        name="${svc#*_}"
        sprobe="$(stack_probe_container "$stack")" || continue
        if ! docker exec "$sprobe" getent hosts "$name" >/dev/null 2>&1; then
            log "$svc ($name) corre pero no resuelve en el DNS de $stack: docker service update --force"
            docker service update --force -d "$svc" >/dev/null
            broken=$((broken + 1))
        fi
    done

    return "$broken"
}

cmd_check() {
    # Revisa durante hasta 20 minutos (las JVM tardan en arrancar en 2 CPUs): termina cuando una
    # vuelta completa no encuentra nada roto y todos los servicios tienen sus réplicas.
    local deadline=$((SECONDS + 1200)) pending s p
    while :; do
        if check_dns_once; then
            pending=0
            for s in $STACKS; do
                p="$(docker stack services "$s" --format '{{.Replicas}}' 2>/dev/null | awk -F/ '$1 != $2' | wc -l)"
                pending=$((pending + p))
            done
            [ "$pending" -eq 0 ] && { log "todos los servicios corren y resuelven"; return 0; }
        fi
        if [ $SECONDS -ge $deadline ]; then
            log "fin de la revisión: quedan servicios sin terminar de arrancar"
            for s in $STACKS; do
                docker stack services "$s" --format '{{.Name}} {{.Replicas}}' 2>/dev/null
            done
            return 0
        fi
        sleep 60
    done
}

cmd_start() {
    wait_for_swarm || return 0
    restore_replicas
    cmd_check
}

case "${1:-}" in
    stop) cmd_stop ;;
    start) cmd_start ;;
    check) cmd_check ;;
    *) echo "uso: $0 stop|start|check" >&2; exit 2 ;;
esac
