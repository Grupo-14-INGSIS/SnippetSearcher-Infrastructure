# Pasar producción al esquema Docker Swarm (`docker-stack.yml`)

Estado al 2026-10-08: dev (`snippet26dev.duckdns.org`, VM `dev`) ya corre con Swarm.
Prod (`snippet26prod.duckdns.org`, IP actual en DuckDNS) todavía está con `docker compose`
y, al momento de escribir esto, la VM no respondía en los puertos 22/80/443 (apagada o con IP cambiada).

## Cómo llega el código a cada ambiente

| Repo | Rama dev | Rama prod | Imagen |
|---|---|---|---|
| SnippetSearcher-App / Runner / AccessManager / printscript-ui | `develop` | `production` | `ghcr.io/grupo-14-ingsis/<svc>:<rama>` |
| SnippetSearcher-Infrastructure | `develop` | `main` | (no construye imagen) |

- Push a una rama de un servicio → su CI construye `:<rama>` y hace `repository_dispatch` a Infrastructure
  con `environment=<rama>` → `update_service.yml` hace `docker service update` en la VM del
  GitHub Environment con ese nombre (`develop` o `production`).
- Push a `main`/`develop` de Infrastructure → `deploy.yml` copia `docker-stack.yml`, `reverse-proxy/` y `db/`
  a `~/` de la VM y hace `docker stack deploy -c docker-stack.yml snippetsearcher`.

## Checklist (hacer en este orden)

### 1. VM de prod encendida y DNS correcto
1. Encender la VM en Azure y verificar la IP pública. Si cambió, actualizar `snippet26prod` en duckdns.org
   (ver TROUBLESHOOTING.md §6). El NSG tiene que permitir 22, 80 y 443.
2. Actualizar el secret `SSH_HOST` del environment `production` en GitHub si la IP cambió
   (`SSH_USER=azureuser`, `SSH_PRIVATE_KEY` = `prod_key`).

### 2. Preparar la VM (una sola vez)
```bash
# bajar el esquema viejo (libera 80/443 y la red reverse-proxy-network)
cd ~/SnippetSearcher-Infrastructure && docker compose down
sudo systemctl stop nginx && sudo systemctl disable nginx   # si hay nginx nativo (TROUBLESHOOTING §5)

# swarm
docker swarm init

# el deploy espera el .env en el HOME (no en ~/SnippetSearcher-Infrastructure)
cat > ~/.env <<'EOF'
DOMAIN_NAME=snippet26prod.duckdns.org
IMAGE_TAG=production
GITHUB_TOKEN=ghp_xxx            # read:packages, para docker login en ghcr
NEW_RELIC_APP_NAME_APP=AppIngsis
NEW_RELIC_APP_NAME_RUNNER=RunnerIngsis
NEW_RELIC_APP_NAME_ACCESS=AccessManagerIngsis
EOF

# certificados (el nginx del stack los monta desde /etc/letsencrypt)
sudo ls /etc/letsencrypt/live/snippet26prod.duckdns.org/   # fullchain.pem y privkey.pem
ls /etc/letsencrypt/options-ssl-nginx.conf /etc/letsencrypt/ssl-dhparams.pem
# si no existen: sudo certbot certonly --standalone -d snippet26prod.duckdns.org  (con el puerto 80 libre)

mkdir -p ~/db/app-init ~/db/runner-init ~/db/accessmanager-init ~/reverse-proxy/nginx/conf.d
```
Los volúmenes del stack (`snippetsearcher_app-pgdata`, etc.) son nuevos: la base arranca vacía.
Si hace falta conservar datos de prod, hacer `pg_dump` de los contenedores de compose antes del `down`
y restaurarlos en los nuevos `*-db` después del primer deploy.

### 3. Crear el stack: mergear Infrastructure `develop` → `main`
Dispara `deploy.yml` sobre el environment `production`. Verificar en la VM:
```bash
docker stack services snippetsearcher      # todo N/N
docker service logs snippetsearcher_reverse-proxy --tail 20
```
En este punto el stack corre con las imágenes `:production` que existan en GHCR (las viejas, si las hay).
Si alguna imagen `:production` no existe todavía, ese servicio queda en 0/N hasta el paso 4.

### 4. Publicar el código: mergear `develop` → `production` en los 4 repos de servicios
App, Runner, AccessManager y printscript-ui. Cada merge construye `:production` y hace el
`docker service update` en prod (los dispatches ya no se cancelan entre sí: la concurrencia es por servicio).
Esperar el CI de cada repo en GitHub Actions; un CI rojo = ese servicio no se actualiza.

### 5. Auth0
En la aplicación de Auth0 agregar `https://snippet26prod.duckdns.org` en Allowed Callback URLs,
Allowed Logout URLs, Allowed Web Origins y Allowed Origins (CORS) (TROUBLESHOOTING.md §8).
El frontend usa `window.location.origin` para la API, así que no hay que rebuildear la UI por el dominio.

### 6. Verificar
```bash
# en la VM
docker stack services snippetsearcher
docker service inspect snippetsearcher_snippetsearcher-runner --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'
```
Desde afuera: entrar a https://snippet26prod.duckdns.org, crear un snippet, abrirlo, ejecutarlo, guardarlo.
Opcional: `VITE_FRONTEND_URL=https://snippet26prod.duckdns.org npm run cypress:run` en printscript-ui.

## Notas
- Los servicios Java tardan 2 a 4 minutos en arrancar en estas VMs; durante un deploy el proxy devuelve 502
  hasta que el contenedor nuevo levanta. No tienen healthcheck, así que `order: start-first` no espera.
- Si un `docker stack deploy` falla con `update out of sequence` es porque otro `docker service update`
  estaba corriendo a la vez (por ejemplo un dispatch de CI); basta con reintentar.
