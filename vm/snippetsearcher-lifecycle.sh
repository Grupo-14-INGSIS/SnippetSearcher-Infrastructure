#!/usr/bin/env bash
# Ciclo de vida del stack de Swarm al apagar y prender la VM (lo corre systemd, ver
# snippetsearcher-lifecycle.service).
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

STACK="snippetsearcher"
STATE_DIR="/var/lib/snippetsearcher"
STATE_FILE="$STATE_DIR/replicas"
# Orden de apagado: lo que depende de otros primero, las bases y el almacenamiento al final
APP_SERVICES="reverse-proxy snippetsearcher-ui snippetsearcher-app snippetsearcher-runner snippetsearcher-accessmanager"
INFRA_SERVICES="asset-service azurite redis appdb runner-db accessmanager-db"

log() { echo "[snippetsearcher-lifecycle] $*"; }

swarm_active() { [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" = "active" ]; }

service_exists() { docker service inspect "${STACK}_$1" >/dev/null 2>&1; }

running_containers() {
    # Contenedores corriendo de un servicio (o de todo el stack si no se pasa servicio)
    if [ $# -eq 0 ]; then
        docker ps -q --filter "label=com.docker.stack.namespace=$STACK"
    else
        docker ps -q --filter "label=com.docker.swarm.service.name=${STACK}_$1"
    fi
}

scale_down() {
    local group="$1" svc
    for svc in $group; do
        service_exists "$svc" || continue
        docker service scale -d "${STACK}_${svc}=0" >/dev/null && log "bajando $svc"
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
        n="$(docker service inspect "${STACK}_${svc}" --format '{{if .Spec.Mode.Replicated}}{{.Spec.Mode.Replicated.Replicas}}{{end}}')"
        [ -n "$n" ] && [ "$n" -gt 0 ] && echo "$svc $n" >> "$tmp"
    done
    if [ -s "$tmp" ]; then mv "$tmp" "$STATE_FILE"; log "réplicas guardadas: $(tr '\n' ' ' < "$STATE_FILE")"; else rm -f "$tmp"; fi

    scale_down "$APP_SERVICES"
    scale_down "$INFRA_SERVICES"
    # Margen para que Swarm termine de borrar tareas y desarmar endpoints de red antes de que
    # systemd detenga Docker
    sleep 15
    log "stack detenido en orden"
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
    local svc n
    # Primero bases y almacenamiento, después la aplicación
    for group in "$INFRA_SERVICES" "$APP_SERVICES"; do
        for svc in $group; do
            n="$(awk -v s="$svc" '$1 == s { print $2 }' "$STATE_FILE")"
            [ -n "$n" ] && service_exists "$svc" && docker service scale -d "${STACK}_${svc}=$n" >/dev/null && log "subiendo $svc a $n"
        done
        sleep 20
    done
    rm -f "$STATE_FILE"
}

# Un contenedor corriendo del stack que tenga `getent` (las imágenes Debian/Ubuntu: postgres, redis,
# las de Java). Desde ahí se prueba si cada servicio resuelve en el DNS interno de Swarm.
probe_container() {
    local c
    for c in $(running_containers); do
        docker exec "$c" getent hosts localhost >/dev/null 2>&1 && { echo "$c"; return 0; }
    done
    return 1
}

# Repara los servicios que están corriendo pero no resuelven. Un servicio sin tareas corriendo
# todavía no tiene registro (es normal mientras arranca): ese se mira en la próxima vuelta.
check_dns_once() {
    local probe svc name broken=0
    probe="$(probe_container)" || { log "todavía no hay un contenedor para probar el DNS"; return 1; }
    for svc in $(docker stack services "$STACK" --format '{{.Name}}'); do
        name="${svc#"${STACK}"_}"
        [ -z "$(running_containers "$name")" ] && continue
        if ! docker exec "$probe" getent hosts "$name" >/dev/null 2>&1; then
            log "$name corre pero no resuelve en el DNS: docker service update --force"
            docker service update --force -d "$svc" >/dev/null
            broken=$((broken + 1))
        fi
    done
    return "$broken"
}

cmd_check() {
    # Revisa durante hasta 20 minutos (las JVM tardan en arrancar en 2 CPUs): termina cuando una
    # vuelta completa no encuentra nada roto y todos los servicios tienen sus réplicas.
    local deadline=$((SECONDS + 1200)) pending
    while :; do
        if check_dns_once; then
            pending="$(docker stack services "$STACK" --format '{{.Replicas}}' | awk -F/ '$1 != $2' | wc -l)"
            [ "$pending" -eq 0 ] && { log "todos los servicios corren y resuelven"; return 0; }
        fi
        [ $SECONDS -ge $deadline ] && { log "fin de la revisión: quedan servicios sin terminar de arrancar"; docker stack services "$STACK" --format '{{.Name}} {{.Replicas}}'; return 0; }
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
