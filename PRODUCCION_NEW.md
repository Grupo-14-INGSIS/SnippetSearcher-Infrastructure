# Guía Operativa de Producción: Docker Swarm y Mantenimiento

> **Estado verificado (Noviembre 2026):**  
> El ambiente de **Producción** (`https://snippet26prod.duckdns.org`, VM Azure `4.222.216.199`) ya se encuentra completamente migrado y operativo bajo **Docker Swarm**. Todos los 12 servicios corren con su imagen de producción (`:production-<commit>` en los microservicios), las réplicas stateless están en 2/2, la base de datos `appdb` tiene la columna `compliant boolean`, el home del usuario `azureuser` está 100% limpio y la renovación SSL con `certbot` en contenedor (modo webroot) está validada y funcionando.

---

## 1. Arquitectura y Despliegue en Producción

### Cómo llega el código a Producción

| Repositorio | Rama Prod | Tag de Imagen | Disparador / Workflow |
| :--- | :---: | :---: | :--- |
| **Microservicios** (`App`, `Runner`, `AccessManager`, `printscript-ui`) | `production` | `:production` y `:production-<commit>` | Merge o push a `production` → CI compila imagen, publica en GHCR y el job `update-infra` escribe `:production-<commit>` en `docker-stack.yml` de la rama `main` de Infra. Ese push dispara `deploy.yml`. |
| **Infraestructura** (`SnippetSearcher-Infrastructure`) | `main` | N/A | Push a `main` o *Run workflow* manual → `deploy.yml` conecta con el contexto de Docker `swarm-vm`, inyecta Swarm Configs inmutables con hash SHA256, despliega el stack completo sin tocar archivos en la VM y verifica que cada servicio corra la imagen pedida. Un commit humano que toque algo más que `.md` fuerza además el reinicio de los cuatro microservicios; *Run workflow* y los commits automáticos no. |

`main` solo difiere de `develop` en las cuatro líneas `image:` de `docker-stack.yml`, y las ramas de Infra **no se mergean entre sí**. Ver [Pipeline CI/CD](Documentación/PIPELINE_CI_CD.md).

---

## 2. Estado de los Servicios en la VM de Producción

Ejecutando `docker stack services snippetsearcher` en la VM de producción:

```text
ID             NAME                                            MODE         REPLICAS   IMAGE                                                              PORTS
u4tkwqktzvf2   snippetsearcher_accessmanager-db                replicated   1/1        postgres:16                      
dodr3lhwzri6   snippetsearcher_appdb                           replicated   1/1        postgres:16                      
xhibejawawc5   snippetsearcher_asset-service                   replicated   1/1        ghcr.io/austral-ingsis/snippet-asset-service:main.14
t35l7foqb3lm   snippetsearcher_azurite                         replicated   1/1        mcr.microsoft.com/azure-storage/azurite:latest
uh69qbb5kmq8   snippetsearcher_certbot                         replicated   1/1        certbot/certbot:v2.11.0          
jpqge9u6t341   snippetsearcher_redis                           replicated   1/1        redis:7                          
yopllwpftxzd   snippetsearcher_reverse-proxy                   replicated   1/1        nginx:stable-alpine                                                *:80->80/tcp, *:443->443/tcp
yud8pjo2sy3j   snippetsearcher_runner-db                       replicated   1/1        postgres:16                      
r8542wtrdtak   snippetsearcher_snippetsearcher-accessmanager   replicated   2/2        ghcr.io/grupo-14-ingsis/snippetsearcher-accessmanager:production-<commit>
nsw0s2t6ovio   snippetsearcher_snippetsearcher-app             replicated   2/2        ghcr.io/grupo-14-ingsis/snippetsearcher-app:production-<commit>
0kmwqvioju8v   snippetsearcher_snippetsearcher-runner          replicated   2/2        ghcr.io/grupo-14-ingsis/snippetsearcher-runner:production-<commit>
wvwdv6ohnb6s   snippetsearcher_snippetsearcher-ui              replicated   2/2        ghcr.io/grupo-14-ingsis/printscript-ui:production-<commit>
```

* **Puertos externos:** Solo `reverse-proxy` expone `80` y `443`. Los microservicios no tienen puertos publicados hacia internet.
* **Base de datos:** `appdb` cuenta con la columna `compliant boolean` en la tabla `snippet`.
* **Certificados SSL:** Let's Encrypt opera en modo `webroot` a través del volumen `/var/www/certbot`. La renovación automática cada 12 horas la ejecuta el contenedor `certbot`.

---

## 3. Pendiente Crítico: Instalación del Servicio de Ciclo de Vida (`snippetsearcher-lifecycle`)

> [!WARNING]
> La verificación en la VM de producción reveló que **el servicio `snippetsearcher-lifecycle` NO está instalado**:
> ```bash
> azureuser@prod:~$ systemctl is-enabled snippetsearcher-lifecycle
> not-found
> azureuser@prod:~$ grep ^APP_SERVICES /usr/local/sbin/snippetsearcher-lifecycle.sh
> grep: /usr/local/sbin/snippetsearcher-lifecycle.sh: No such file or directory
> ```
> **Riesgo:** Si la VM de producción se apaga o reinicia (por mantenimiento de Azure o apagado automático), Docker detiene el demonio antes de que Swarm cierre ordenadamente las tareas y endpoints de red. Esto puede causar inconsistencias en el DNS interno (`UnknownHostException` entre servicios) al volver a encender la máquina.

### Pasos para instalarlo en la VM de Producción (Una sola vez)

Dado que la VM de producción tiene el home limpio y no contiene el código fuente clonado, instala el script ejecutando lo siguiente por SSH:

```bash
# 1. Crear el script de ciclo de vida en /usr/local/sbin/
sudo tee /usr/local/sbin/snippetsearcher-lifecycle.sh > /dev/null << 'EOF'
#!/usr/bin/env bash
set -uo pipefail

STACK="snippetsearcher"
STATE_DIR="/var/lib/snippetsearcher"
STATE_FILE="$STATE_DIR/replicas"
APP_SERVICES="certbot reverse-proxy snippetsearcher-ui snippetsearcher-app snippetsearcher-runner snippetsearcher-accessmanager"
INFRA_SERVICES="asset-service azurite redis appdb runner-db accessmanager-db"

log() { echo "[snippetsearcher-lifecycle] $*"; }
swarm_active() { [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" = "active" ]; }
service_exists() { docker service inspect "${STACK}_$1" >/dev/null 2>&1; }

running_containers() {
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
    local deadline=$((SECONDS + 120)) left
    while :; do
        left=0
        for svc in $group; do
            [ -n "$(running_containers "$svc")" ] && left=$((left + 1))
        done
        [ "$left" -eq 0 ] && break
        [ $SECONDS -ge $deadline ] && { log "timeout esperando que bajen $left servicio(s)"; break; }
        sleep 2
    done
}

cmd_stop() {
    swarm_active || { log "Swarm no está activo: nada que hacer"; return 0; }
    mkdir -p "$STATE_DIR"
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
    [ -s "$STATE_FILE" ] || { log "sin réplicas guardadas: se dejan como están"; return 0; }
    local svc n
    for group in "$INFRA_SERVICES" "$APP_SERVICES"; do
        for svc in $group; do
            n="$(awk -v s="$svc" '$1 == s { print $2 }' "$STATE_FILE")"
            [ -n "$n" ] && service_exists "$svc" && docker service scale -d "${STACK}_${svc}=$n" >/dev/null && log "subiendo $svc a $n"
        done
        sleep 20
    done
    rm -f "$STATE_FILE"
}

probe_container() {
    local c
    for c in $(running_containers); do
        docker exec "$c" getent hosts localhost >/dev/null 2>&1 && { echo "$c"; return 0; }
    done
    return 1
}

check_dns_once() {
    local probe svc name broken=0
    probe="$(probe_container)" || { log "esperando contenedor para probar DNS"; return 1; }
    for svc in $(docker stack services "$STACK" --format '{{.Name}}'); do
        name="${svc#"${STACK}"_}"
        [ -z "$(running_containers "$name")" ] && continue
        if ! docker exec "$probe" getent hosts "$name" >/dev/null 2>&1; then
            log "$name corre pero no resuelve en el DNS: forzando update"
            docker service update --force -d "$svc" >/dev/null
            broken=$((broken + 1))
        fi
    done
    return "$broken"
}

cmd_check() {
    local deadline=$((SECONDS + 1200)) pending
    while :; do
        if check_dns_once; then
            pending="$(docker stack services "$STACK" --format '{{.Replicas}}' | awk -F/ '$1 != $2' | wc -l)"
            [ "$pending" -eq 0 ] && { log "todos los servicios corren y resuelven"; return 0; }
        fi
        [ $SECONDS -ge $deadline ] && { log "fin de revisión con pendientes"; return 0; }
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
EOF

# 2. Dar permisos de ejecución
sudo chmod 0755 /usr/local/sbin/snippetsearcher-lifecycle.sh

# 3. Crear la unidad de systemd
sudo tee /etc/systemd/system/snippetsearcher-lifecycle.service > /dev/null << 'EOF'
[Unit]
Description=SnippetSearcher: baja el stack de Swarm en orden al apagar y lo revisa al prender
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/snippetsearcher-lifecycle.sh start
ExecStop=/usr/local/sbin/snippetsearcher-lifecycle.sh stop
TimeoutStartSec=30min
TimeoutStopSec=10min

[Install]
WantedBy=multi-user.target
EOF

# 4. Habilitar e iniciar la unidad
sudo systemctl daemon-reload
sudo systemctl enable snippetsearcher-lifecycle.service
sudo systemctl start snippetsearcher-lifecycle.service

# 5. Verificar que figure activa
systemctl is-active snippetsearcher-lifecycle
systemctl is-enabled snippetsearcher-lifecycle
```

---

## 4. Comandos de Diagnóstico y Monitoreo en Producción

### Ver estado general del cluster
```bash
# Ver servicios y réplicas (debe mostrar 2/2 en microservicios, 1/1 en stateful)
docker stack services snippetsearcher

# Ver detalle de tareas, réplicas y errores recientes
docker stack ps snippetsearcher --no-trunc
```

### Inspección de logs en tiempo real
```bash
# Reverse Proxy (Nginx)
docker service logs -f snippetsearcher_reverse-proxy

# Microservicio App
docker service logs -f snippetsearcher_snippetsearcher-app

# Microservicio Runner
docker service logs -f snippetsearcher_snippetsearcher-runner

# Certbot (renovación de certificados)
docker service logs snippetsearcher_certbot --tail 50
```

### Probar renovación SSL manualmente
```bash
docker exec -it $(docker ps -q -f name=snippetsearcher_certbot) certbot renew --dry-run --webroot -w /var/www/certbot
```

### Si la VM estuvo apagada
Si la máquina virtual estuvo apagada durante commits a `main` o a microservicios:
1. Enciende la VM en Azure y verifica que la IP pública coincida con DuckDNS (`snippet26prod.duckdns.org`).
2. En GitHub: entra a **Actions** → **Deploy Stack** → **Run workflow** (sobre la rama `main`).
3. El workflow conectará por SSH y pondrá cada servicio en la versión anotada en `docker-stack.yml`.
