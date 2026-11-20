#!/usr/bin/env bash
set -uo pipefail

STATE_DIR="/var/lib/snippetsearcher"
STATE_FILE="$STATE_DIR/replicas"
STACKS="infra accessmanager runner app ui"
# Orden de apagado: lo que depende de otros primero, las bases y el almacenamiento al final
APP_SERVICES="infra_certbot infra_reverse-proxy ui_snippetsearcher-ui
  app_snippetsearcher-app runner_snippetsearcher-runner accessmanager_snippetsearcher-accessmanager"
INFRA_SERVICES="infra_asset-service infra_azurite infra_redis app_appdb runner_runner-db accessmanager_accessmanager-db"
log() { echo "[snippetsearcher-lifecycle] $*"; }

swarm_active() { [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" = "active" ]; }

service_exists() { docker service inspect "$1" >/dev/null 2>&1; }

running_containers() { docker ps -q --filter "label=com.docker.swarm.service.name=$1"; }

# Todos los servicios de los 5 stacks (nombre completo)
all_services() {
    local s
    for s in $STACKS; do docker stack services "$s" --format '{{.Name}}' 2>/dev/null; done
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
    # Margen para que Swarm termine de borrar tareas y desarmar endpoints de red
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

# Una réplica lista del servicio: healthy, o sin healthcheck. Las de Java en "health: starting" todavía
# no están en el DNS de Swarm, así que no se miran (se verán en la próxima vuelta).
ready_container() {
    local c
    c="$(docker ps -q --filter "label=com.docker.swarm.service.name=$1" --filter health=healthy | head -n 1)"
    [ -z "$c" ] && c="$(docker ps -q --filter "label=com.docker.swarm.service.name=$1" --filter health=none | head -n 1)"
    echo "$c"
}

# Repara los servicios que están corriendo pero no resuelven. Se prueba desde la propia réplica: es el
# único contenedor que seguro comparte red con el servicio (las bases solo están en la red de su stack).
check_dns_once() {
    local svc c name broken=0
    for svc in $(all_services); do
        c="$(ready_container "$svc")"
        [ -z "$c" ] && continue
        docker exec "$c" getent hosts localhost >/dev/null 2>&1 || continue   # imagen sin getent
        name="${svc#*_}"
        if ! docker exec "$c" getent hosts "$name" >/dev/null 2>&1; then
            log "$svc corre pero no resuelve en el DNS: docker service update --force"
            docker service update --force -d "$svc" >/dev/null
            broken=$((broken + 1))
        fi
    done
    return "$broken"
}

pending_services() {
    local s
    for s in $STACKS; do docker stack services "$s" --format '{{.Replicas}}' 2>/dev/null; done \
        | awk -F/ '$1 != $2' | wc -l
}

cmd_check() {
    # Revisa durante hasta 20 minutos (las JVM tardan en arrancar en 2 CPUs): termina cuando una
    # vuelta completa no encuentra nada roto y todos los servicios tienen sus réplicas.
    local deadline=$((SECONDS + 1200)) s
    while :; do
        if check_dns_once; then
            [ "$(pending_services)" -eq 0 ] && { log "todos los servicios corren y resuelven"; return 0; }
        fi
        if [ $SECONDS -ge $deadline ]; then
            log "fin de la revisión: quedan servicios sin terminar de arrancar"
            for s in $STACKS; do docker stack services "$s" --format '{{.Name}} {{.Replicas}}' 2>/dev/null; done
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