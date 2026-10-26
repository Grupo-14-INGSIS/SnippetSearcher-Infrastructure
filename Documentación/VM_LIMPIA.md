# VM limpia: deploy sin archivos en el home

## Objetivo
En la VM solo queda lo que trae de fábrica más Docker: `~/.ssh` (lo usa Actions para entrar) y
`/etc/letsencrypt` (certificados del sistema, los renueva certbot). Nada del proyecto vive en el home. Lo único
instalado del proyecto es el servicio de systemd de apagado y arranque ordenados, fuera del home y versionado
en `vm/` (ver [Apagado y arranque ordenados](#apagado-y-arranque-ordenados-systemd)).

| Antes (en la VM) | Ahora |
| :--- | :--- |
| `~/.env` con `GITHUB_TOKEN` (login a GHCR) | Login en el **runner de Actions** con el secret `PAT`; `--with-registry-auth` le pasa la credencial a Swarm |
| `~/.env` con `DOMAIN_NAME` / `IMAGE_TAG` | **Variables del environment de GitHub** (`vars.DOMAIN_NAME`); `IMAGE_TAG` sale de la rama de Infra (`develop` → `develop`, `main` → `production`) |
| `~/docker-stack.yml` (copiado con `scp`) | Se lee del checkout: `DOCKER_HOST=ssh://vm docker stack deploy ...` corre en Actions contra el Docker de la VM |
| `~/reverse-proxy/` (bind mount de `app.conf`) | **Config de Swarm** `nginx_conf_<hash>` |
| `~/db/*-init` (bind mount de los SQL) | **Configs de Swarm** `app_init_<hash>`, `accessmanager_init_<hash>` (`runner-init` estaba vacío) |
| `~/.docker/config.json` (lo dejaba `docker login`) | No hace falta: el login es en Actions |

## Cómo funciona

```
GitHub Actions (runner)                              VM (Swarm manager)
  checkout del repo
  docker login ghcr.io  (secret PAT)
  DOCKER_HOST=ssh://vm  ── SSH (secret SSH_PRIVATE_KEY) ──▶  dockerd
  docker stack deploy -c docker-stack.yml                     guarda servicios, configs y la auth del registry
```

Con `DOCKER_HOST=ssh://...` el CLI de Docker corre en el runner y habla con el daemon de la VM por SSH
(en la VM ejecuta `docker system dial-stdio`). Los archivos que referencia el stack (`file:` de los configs)
se leen en el runner y viajan por la API: no se copia nada a disco en la VM.

**Configs inmutables.** Swarm no deja modificar un config. El nombre lleva el hash del contenido
(`nginx_conf_${NGINX_CONF_HASH}`, lo calcula `deploy.yml`): si el archivo cambia se crea uno nuevo y el
servicio se actualiza; si no cambia, el nombre es el mismo y no se reinicia nada. Los viejos se borran al
final de cada deploy (`docker config rm` no puede borrar los que están en uso).

## Por qué la VM ya no necesita los scripts SQL de inicialización

El script sigue existiendo y se sigue usando: lo que cambió es **dónde vive**.

| | Antes | Ahora |
| :--- | :--- | :--- |
| Dónde está el SQL | Archivo en la VM: `~/db/app-init/01-init-snippet.sql` (lo copiaba `scp`) | Dentro de Swarm, como **config** `app_init_<hash>` (y `accessmanager_init_<hash>`) |
| Cómo llega al contenedor | Bind mount `./db/app-init:/docker-entrypoint-initdb.d` desde el home | Swarm monta el config en `/docker-entrypoint-initdb.d/01-init-snippet.sql` |
| Quién lo pone ahí | El workflow viejo, copiando archivos a la VM | `docker stack deploy` desde Actions: lee el archivo del repo y lo guarda en la base interna (raft) de Swarm |

```yaml
# docker-stack.yml
appdb:
  configs:
    - source: app_init_sql
      target: /docker-entrypoint-initdb.d/01-init-snippet.sql
configs:
  app_init_sql:
    name: app_init_${APP_INIT_HASH}
    file: ./db/app-init/01-init-snippet.sql      # se lee en el runner de Actions, no en la VM
```

Para Postgres no cambia nada: ve el mismo archivo en la misma ruta. Un config de Swarm es eso, un archivo que
el orquestador guarda y entrega a los contenedores que lo piden, sin que exista en el disco del host. Se ve con
`docker config ls` y su contenido con `docker config inspect --pretty app_init_<hash>`.

Además, la imagen de Postgres **solo ejecuta `/docker-entrypoint-initdb.d/` cuando el volumen de datos está
vacío**, es decir, la primera vez que se crea la base. En dev y prod ya se aplicó hace tiempo: el config está
para que una base nueva (otra VM, o si se borra el volumen) se cree con el esquema correcto. Los cambios de
esquema sobre una base existente no van ahí sino en `db/migrations/` y se corren a mano (ver USO_DE_REDIS.md §11).

`db/runner-init` estaba vacío (las tablas del Runner las crea Hibernate), así que ese montaje se sacó.

## Apagado y arranque ordenados (systemd)

**Problema.** Al apagar la VM, Docker se detenía con limpiezas de Swarm a medio hacer (`remove task failed ...
context canceled`, `network ingress remove failed`). Al prender, Docker encontraba contenedores rotos (`RW layer
for container ... not found`), Swarm recreaba todo de golpe y, a veces, algún servicio quedaba corriendo con su
IP virtual pero **sin nombre en el DNS interno**: los que dependían de él caían con `UnknownHostException`. Le
pasaba a uno distinto cada vez (`appdb`, después `runner-db` y `asset-service`), siempre se arreglaba con
`docker service update --force`. La relación entre las limpiezas cortadas y el DNS perdido es la explicación más
consistente con los logs, pero no está probada.

**Solución (sugerida por la cátedra).** Un servicio de systemd en cada VM, versionado en `vm/` de este repo:

| Archivo en el repo | Se instala en |
| :--- | :--- |
| `vm/snippetsearcher-lifecycle.sh` | `/usr/local/sbin/snippetsearcher-lifecycle.sh` |
| `vm/snippetsearcher-lifecycle.service` | `/etc/systemd/system/snippetsearcher-lifecycle.service` |
| `vm/install.sh` | (no se instala: copia los dos de arriba y habilita el servicio) |

- **Al apagar** (`ExecStop`): como la unidad tiene `After=docker.service`, systemd la detiene **antes** que Docker.
  Guarda las réplicas de cada servicio en `/var/lib/snippetsearcher/replicas`, baja los servicios en orden
  (aplicación → bases) y espera a que Swarm termine de limpiar.
- **Al prender** (`ExecStart`): espera a que Swarm esté activo, restaura las réplicas (bases primero) y durante
  hasta 20 minutos revisa que cada servicio **que está corriendo** resuelva por nombre desde otro contenedor; a
  los que no, `docker service update --force`. Un servicio sin tareas corriendo todavía no tiene registro DNS:
  eso es normal mientras arranca y se revisa en la vuelta siguiente.
- No usa archivos del proyecto: trabaja sobre los servicios que ya tiene Swarm. El home sigue limpio.

Logs: `journalctl -u snippetsearcher-lifecycle -b` (este arranque) y `-b -1` (el apagado anterior).
Revisión a mano en cualquier momento: `sudo snippetsearcher-lifecycle.sh check`.

**Requisito:** que el apagado sea un apagado normal del sistema operativo (systemd corre los `ExecStop`). Hay que
confirmar en el log que el apagado automático de Azure lo cumple: después de un apagado automático,
`journalctl -u snippetsearcher-lifecycle -b -1` tiene que mostrar `stack detenido en orden`.

**Reset de Swarm.** Para limpiar un estado ya inconsistente (también sugerido por la cátedra):
`docker stack rm snippetsearcher`, esperar a que se borren las redes, `docker swarm leave --force`,
`docker swarm init` y volver a desplegar con *Deploy Stack → Run workflow*. Los volúmenes con nombre (datos de
las bases, Redis, Azurite) son de Docker y no de Swarm: sobreviven.

## Cuándo se despliega
- **Push a Infra** (`develop` o `main`) → `deploy.yml` despliega **todo el stack**. `docker stack deploy
  --resolve-image always` resuelve cada tag (`develop`, `production`) a su digest actual y solo actualiza los
  servicios cuya especificación cambió: un push que no cambia el stack no reinicia nada.
- **Push a un microservicio** (`develop` o `production`) → `update_service.yml` actualiza **solo ese servicio**,
  también por `DOCKER_HOST`, pineando el digest de la imagen.
- **VM apagada durante un push**: el deploy falla y nadie lo reintenta. Al prenderla, Swarm levanta lo que tenía
  y, para traer lo último, *Actions → Deploy Stack → Run workflow* sobre `develop` o `main`.

## Cómo se elige el environment y de dónde salen los valores

El mismo workflow despliega en dev o en prod sin ningún `if`: lo que cambia es el **environment de GitHub** del
job, y con él los `vars.*` y `secrets.*` que ve.

**`deploy.yml`**
```yaml
on:
  push: { branches: [main, develop] }       # 1. la rama pusheada es el ambiente
  workflow_dispatch:                        #    (o la elegida en Run workflow)

deploy:
  if: github.ref_name == 'develop' || github.ref_name == 'main'
  environment: ${{ github.ref_name == 'main' && 'production' || 'develop' }}   # 2. la rama elige el environment
  env:                                                                         # 3. valores de ESE environment
    IMAGE_TAG: ${{ github.ref_name == 'main' && 'production' || 'develop' }}   # tag de las imágenes
    DOMAIN_NAME: ${{ vars.DOMAIN_NAME }}
    NEW_RELIC_APP_NAME_APP: ${{ vars.NEW_RELIC_APP_NAME_APP }}
    ...
```

1. Se decide qué rama se despliega.
2. `environment:` es lo único que conecta el job con un environment: `main` → `production`, `develop` → `develop`.
   Ojo con los nombres: la rama de prod de **Infra** es `main`, pero la de los **microservicios** es
   `production` (su `main` quedó sin uso). Por eso las imágenes de prod tienen el tag `:production` y
   `IMAGE_TAG` se traduce: Infra `main` → imágenes `:production`.
3. Dentro del job, `vars.X` y `secrets.X` se resuelven contra ese environment. Si un secret no está en el
   environment, GitHub usa el del repositorio o el de la organización (así llegan `PAT` y `GHCR_USER`).
4. El bloque `env:` los pone como variables del shell, y `docker stack deploy` las reemplaza en
   `docker-stack.yml` **en el runner**, antes de mandar el stack a la VM.

**`update_service.yml`**: la rama la manda el microservicio en el dispatch (`"environment": "$branch"` en su
`ci-cd.yml`). Esa rama (`develop` / `production`) es a la vez el tag de la imagen y el nombre del environment;
cualquier otra rama (features) se saltea:
```yaml
environment: ${{ github.event.client_payload.environment == 'production' && 'production' || 'develop' }}
if: contains(fromJSON('["develop", "production"]'), github.event.client_payload.environment)
```
Detalle completo del pipeline en [PIPELINE_CI_CD.md](PIPELINE_CI_CD.md).

**Valores por defecto en `docker-stack.yml`.** `${VARIABLE:-valor}` usa `valor` si la variable no existe o
está vacía:
```yaml
NEW_RELIC_APP_NAME: ${NEW_RELIC_APP_NAME_APP:-AppIngsis_dev}
```
Si `NEW_RELIC_APP_NAME_APP` no está cargada en GitHub, `vars.NEW_RELIC_APP_NAME_APP` llega vacía y se usa
`AppIngsis_dev`, también en prod (dev y prod quedarían mezclados en New Relic). Por eso conviene cargarlas en
los dos environments: el valor por defecto queda solo como respaldo. `DOMAIN_NAME`, en cambio, no tiene valor
por defecto (`${DOMAIN_NAME:?...}`): sin ella el deploy falla con un mensaje claro en lugar de levantar nginx
con una ruta de certificado inválida.

**Antes** estos valores salían de `~/.env`: el script del deploy hacía `source .env` en la VM y esas variables
pisaban los valores por defecto. Ahora el lugar para cambiarlos es GitHub, no la VM.

## Paso a paso
1. **VM accesible**: prendida y respondiendo por SSH en la IP de `SSH_HOST`.
2. **Ver qué tiene el `.env`** de cada VM (solo nombres): `cut -d= -f1 ~/.env`. Lo que no sea `GITHUB_TOKEN`
   hay que pasarlo a variables de GitHub.
3. **GitHub → Settings → Environments → (environment) → Environment variables** (variables, no secrets):

   | Name | `develop` | `production` | ¿Obligatoria? |
   | :--- | :--- | :--- | :--- |
   | `DOMAIN_NAME` | `snippet26dev.duckdns.org` | `snippet26prod.duckdns.org` | Sí |
   | `NEW_RELIC_APP_NAME_APP` | `AppIngsis_dev` | `AppIngsis_prod` | No |
   | `NEW_RELIC_APP_NAME_RUNNER` | `RunnerIngsis_dev` | `RunnerIngsis_prod` | No |
   | `NEW_RELIC_APP_NAME_ACCESS` | `AccessManagerIngsis_dev` | `AccessManagerIngsis_prod` | No |

   Secrets que ya tienen que existir: `SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY` en cada environment, y `PAT`,
   `GHCR_USER` (están a nivel organización). Ver [Cómo se elige el environment](#cómo-se-elige-el-environment-y-de-dónde-salen-los-valores).
4. **Push a `develop`** de `docker-stack.yml`, `deploy.yml` y `update_service.yml`. Corre "Deploy Stack".
   El primer deploy reinicia una vez las bases y nginx (cambian sus montajes): ~1-2 min de cortes.
5. **Verificar**: el sitio anda; ningún servicio monta algo del home:
   ```bash
   for s in $(docker service ls -q); do docker service inspect $s --format '{{.Spec.Name}} {{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{.Source}} {{end}}'; done
   ```
   Solo deberían aparecer volúmenes con nombre y `/etc/letsencrypt`.
6. **Probar un reinicio**: `sudo reboot`, esperar unos minutos y verificar que el sitio levanta.
7. **Limpiar la VM** (recién ahora):
   ```bash
   rm -rf ~/.env ~/docker-stack.yml ~/reverse-proxy ~/db ~/.docker/config.json
   ```
8. **Producción**: merge a `main` y repetir 4 a 7 en la VM de prod.

## Opcional: contraseñas como secrets de Swarm
El repo es público y `docker-stack.yml` tiene las contraseñas de las bases en texto plano. Para sacarlas:
`docker secret create` (desde Actions, con `DOCKER_HOST`), `POSTGRES_PASSWORD_FILE=/run/secrets/...` en
Postgres y `spring.config.import: optional:configtree:/run/secrets/` en cada servicio Spring. Requiere
cambiar el `application.yml` de App, Runner y AccessManager.
