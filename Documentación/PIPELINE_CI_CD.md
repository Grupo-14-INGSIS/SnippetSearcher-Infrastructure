# Pipeline CI/CD: del push al servicio corriendo en la VM

## Índice
- [1. Vista general](#1-vista-general)
- [2. Ramas, ambientes y tags](#2-ramas-ambientes-y-tags)
- [3. CI/CD de cada microservicio](#3-cicd-de-cada-microservicio)
- [4. Escritura de la versión en Infra](#4-escritura-de-la-versión-en-infra)
- [5. update_service.yml: sin uso](#5-update_serviceyml-sin-uso)
- [6. deploy.yml: desplegar el stack](#6-deployyml-desplegar-el-stack)
- [7. Secrets, variables y environments](#7-secrets-variables-y-environments)
- [8. Qué pasa en la VM: Swarm](#8-qué-pasa-en-la-vm-swarm)
- [9. Qué pasa cuando algo falla](#9-qué-pasa-cuando-algo-falla)
- [10. Problemas conocidos](#10-problemas-conocidos)
- [11. Preguntas para repasar](#11-preguntas-para-repasar)

---

## 1. Vista general

```
 push a develop o production de un microservicio (App, Runner, AccessManager, UI)
   │
   ├─ job de CI ........ lint · detekt · tests · cobertura · build      (falla → no se publica nada)
   ├─ job build-and-push  docker build + push a GHCR:  :<ambiente>  y  :<ambiente>-<sha>
   └─ job update-infra .. commit en docker-stack.yml de Infra con la versión nueva
                          develop → rama develop   ·   production → rama main
                                   │
                                   ▼
 Infra: deploy.yml (push a develop o main, o Run workflow manual)
   ├─ docker stack deploy: todo el stack, solo cambia lo que difiere
   ├─ commit humano (no solo .md): reinicia App, Runner, AccessManager y UI, de a uno
   ├─ espera a que cada servicio corra la imagen de docker-stack.yml (falla si hubo rollback)
   └─ docker image prune: recién después de esa espera
                                   │
                                   ▼
 VM (Swarm manager): rolling update, healthcheck, rollback si la versión nueva no arranca

 pull_request a develop o production: solo corre el job de CI. No publica ni despliega.
```

Hay **un solo camino** a la VM: un push a Infra dispara `deploy.yml`. Corre **desde GitHub Actions**: la VM no
corre ningún script ni guarda archivos del proyecto (ver [VM_LIMPIA.md](VM_LIMPIA.md)).

`docker-stack.yml` es el registro de qué versión corre en cada ambiente: cada deploy de un microservicio queda
como un commit `chore: update Docker image ...` en la rama de Infra que corresponde. Ese commit va directo a la
rama, sin PR. Los PR se abren a mano, de `develop` a `production`, en cada microservicio.

| Qué llega a Infra | Qué hace Deploy Stack |
| :--- | :--- |
| **Commit automático** de `update-infra` | Despliega solo el servicio que cambió |
| **Commit humano** | Redeploya todo: fuerza el reinicio de App, Runner, AccessManager y UI |
| **Commit humano solo de archivos `.md`** | No reinicia nada |
| ***Run workflow*** | Aplica el stack, sin forzar |

El run de Infra que aparece después de un push a un microservicio no es un deploy de más: es **el** deploy,
porque solo Infra tiene acceso a la VM.

No hay deploys automáticos sin un push: si la VM estaba apagada, al prenderla se corre *Deploy Stack* a mano.

---

## 2. Ramas, ambientes y tags

**Los nombres de las ramas de prod no coinciden entre repos.** Es la fuente de confusión más común:

| | Dev | Prod |
| :--- | :--- | :--- |
| Rama de los **microservicios** (App, Runner, AccessManager, UI) | `develop` | **`production`** (`main` / `master` quedaron sin uso) |
| Rama de **Infra** | `develop` | **`main`** |
| **Tag móvil** de las imágenes en GHCR | `:develop` | `:production` |
| **Tag fijo** de las imágenes en GHCR | `:develop-<sha>` | `:production-<sha>` |
| **Environment** de GitHub (en Infra) | `develop` | `production` |
| VM | `snippet26dev.duckdns.org` | `snippet26prod.duckdns.org` |

Cada imagen se publica con dos tags:
- `:<ambiente>-<sha del commit>`: fijo. Es **el que usa el stack**: `update-infra` lo escribe en `docker-stack.yml`.
- `:<ambiente>` (por ejemplo `:develop`): se mueve con cada push y apunta a la última imagen. El stack no lo usa.

Las imágenes viven en GHCR (`ghcr.io/grupo-14-ingsis/...`). La de la UI se llama `printscript-ui`, y el
servicio de Swarm, `snippetsearcher-ui`.

### Qué difiere entre `develop` y `main` de Infra

Solo **cuatro líneas de `docker-stack.yml`**: las `image:` de App, Runner, AccessManager y UI. En `develop`
tienen `develop-<sha>` y en `main`, `production-<sha>`. Todo lo demás (workflows, documentación, configuración y
el resto del stack) tiene que ser idéntico.

- **No mergear una rama de Infra en la otra.** Esas cuatro líneas cambian en las dos ramas, así que un merge da
  conflicto. Si se resuelve mal, producción corre imágenes de desarrollo.
- **Un cambio de otro archivo se aplica en las dos ramas.** Si es un cambio de `docker-stack.yml`, no hay que
  tocar las cuatro líneas de `image:`.
- **Para comprobarlo:** `git diff origin/main origin/develop --stat` tiene que mostrar solo `docker-stack.yml`,
  con 4 líneas cambiadas.

Para pasar un archivo de `develop` a `main`:
```bash
git switch main
git pull
git checkout origin/develop -- <archivo>     # nunca docker-stack.yml entero
git commit -m "..."
git push
```

---

## 3. CI/CD de cada microservicio

Archivo: `.github/workflows/ci-cd.yml` (UI: `ci.yaml`). Se dispara con un **push** o un **pull request** a
`develop` o `production`. Las ramas de features no disparan nada hasta que se abre un PR.

| Evento | Job de CI | `build-and-push` y `update-infra` |
| :--- | :--- | :--- |
| `pull_request` | Corre | Se saltean |
| `push` (también el merge de un PR) | Corre | Corren si pasó el CI |

En la lista de Actions, un run de PR lleva el título del PR y uno de push, el mensaje del commit. Un push a una
rama con un PR abierto dispara los dos.

### Servicios Kotlin (App, Runner, AccessManager)

| Paso | Qué hace | Si falla |
| :--- | :--- | :--- |
| `ktlintFormat` + `git diff` | Formatea; si eso cambió archivos, el código no estaba formateado | Bloquea el build |
| `ktlintCheck` | Estilo | Bloquea |
| `detekt` | Análisis estático (complejidad, malas prácticas) | Bloquea |
| `test` | Tests unitarios | Bloquea |
| `jacocoTestCoverageVerification` | Cobertura mínima (App y AccessManager 80%, Runner 65%) | Bloquea |
| `build` | Arma el `.jar` | Bloquea |
| `build-and-push` (otro job, `needs: ci-cd`) | `docker build` + push a GHCR con `GITHUB_TOKEN` | No hay imagen nueva |
| `update-infra` (otro job, `needs: build-and-push`) | Escribe la versión en Infra (sección 4) | No se despliega |

El job `build-and-push` solo corre si `ci-cd` pasó: **una imagen publicada siempre pasó lint y tests.**
El Runner necesita el token también para compilar (`GITHUB_TOKEN` como build-arg): baja el intérprete de
PrintScript desde GitHub Packages.

### UI (printscript-ui)
`npm ci` → `npm run lint` → `npm test --if-present` → `npm run build` → `docker build` + push → `update-infra`.
- `npm test --if-present` **no ejecuta nada**: no hay script `test`, así que Cypress no corre en CI.
- Las variables `VITE_AUTH0_*` se pasan como build-args (Vite las embebe en el bundle al compilar).
- En el navegador, la URL del backend sale de `window.location.origin` cuando no es `localhost`, así que la
  misma imagen funciona en cualquier dominio (`src/utils/constants.ts`).

---

## 4. Escritura de la versión en Infra

El job `update-infra` es igual en los cuatro microservicios. Primero se traduce la rama, porque los nombres no
coinciden entre repos:

```bash
# Job build-and-push, paso "Store new image version"
echo "version=${GITHUB_REF_NAME}-${GITHUB_SHA}" >> "$GITHUB_OUTPUT"

if [[ "$GITHUB_REF_NAME" == "production" ]]; then
echo "branch=production" >> "$GITHUB_OUTPUT"      # tag móvil de la imagen
echo "infra_branch=main" >> "$GITHUB_OUTPUT"      # rama de Infra
else
echo "branch=develop" >> "$GITHUB_OUTPUT"
echo "infra_branch=develop" >> "$GITHUB_OUTPUT"
fi
```

| Push a | Tag móvil (`branch`) | Tag fijo (`version`) | Rama de Infra (`infra_branch`) |
| :--- | :--- | :--- | :--- |
| `develop` | `:develop` | `:develop-<sha>` | `develop` |
| `production` | `:production` | `:production-<sha>` | `main` |

Después, `update-infra`:

1. Hace checkout de Infra en `infra_branch`, con el `PAT`.
2. Trae lo último de la rama.
3. Reemplaza la versión en la línea `image:` de ese servicio con `sed`. Si no la encuentra, falla.
4. Si la versión ya estaba, termina sin commit.
5. Hace commit como `github-actions[bot]` y `git push` directo a la rama, sin PR.
6. Si rechazan el push, espera entre 5 y 14 segundos y repite desde el paso 2, hasta 6 veces.

Ese push dispara `deploy.yml`. Usa `PAT` porque el `GITHUB_TOKEN` de un repo no puede escribir en otro, y un
push hecho con `GITHUB_TOKEN` tampoco dispararía workflows.

**Concurrencia al mergear varios PR juntos.** Hay dos niveles:

| Nivel | Qué lo resuelve | Comportamiento |
| :--- | :--- | :--- |
| Varios repos escriben en Infra a la vez | Reintentos de `update-infra` | Al que le rechazan el push vuelve a aplicar su versión sobre lo último de la rama |
| Dos runs del mismo repo y la misma rama | `concurrency: update-infra-<rama>` en el job | Corre uno a la vez. Si se acumulan, queda el último, que trae la versión más nueva |
| Varios commits llegan a Infra | `concurrency: stack-<rama>` en `deploy.yml` | Un deploy a la vez; si se acumulan, queda el último, que aplica el `docker-stack.yml` completo |

El arreglo está en cada microservicio y no en Infra, porque GitHub limita `concurrency` a un solo repo: no
puede ordenar runs de repos distintos. Por eso el choque entre repos se resuelve con reintentos.
Si después de 6 intentos sigue fallando, la imagen ya quedó publicada: alcanza con **Re-run failed jobs**.

**Volver a una versión anterior.** Revertir en la rama de Infra el commit `chore: update Docker image ...`:
```bash
git revert <commit>
git push
```
El push despliega la versión anterior. La imagen tiene que seguir en GHCR, y el próximo push de ese servicio
vuelve a escribir su versión, así que el código con problemas también hay que corregirlo en su repo.

---

## 5. `update_service.yml`: sin uso

Es el workflow del esquema anterior: recibía un `repository_dispatch` de tipo `new-image-ready` y actualizaba un
solo servicio. **Ningún microservicio lo dispara desde noviembre de 2026**, porque todos pasaron a `update-infra`.
Sigue en el repo, pero no interviene en ningún deploy.

---

## 6. `deploy.yml`: desplegar el stack

Disparadores:
- `push` a `develop` o `main` (cualquier archivo de Infra).
- `workflow_dispatch` (botón *Run workflow*): para aplicar el stack a mano, por ejemplo al prender la VM. No fuerza reinicios.

`environment` = `develop` para la rama `develop`, `production` para `main`. Sobre otra rama el job no corre.

| Paso | Qué hace |
| :--- | :--- |
| SSH | `webfactory/ssh-agent` carga `SSH_PRIVATE_KEY` y se agrega la VM a `known_hosts`. |
| Login GHCR | En el runner, con `PAT`. |
| Hash de configs | Calcula el hash de `app.conf` y de los SQL (los configs de Swarm son inmutables; ver VM_LIMPIA). |
| Contexto de Docker | Crea `swarm-vm` (`ssh://<SSH_USER>@<SSH_HOST>`): los comandos de Swarm corren contra la VM. |
| Deploy | `docker --context swarm-vm stack deploy --with-registry-auth --resolve-image always --compose-file docker-stack.yml snippetsearcher` |
| Decidir si se fuerza | Mira los commits del push. Fuerza si es un `push` con algún archivo que no sea `.md` en un commit cuyo autor no sea `github-actions[bot]`. |
| Redeploy forzado | Solo si corresponde: `docker service update --force` de AccessManager, Runner, App y UI, de a uno y esperando a cada uno. No toca bases, Redis ni Azurite. |
| Verificación | Espera (hasta 40 min) a que App, Runner, AccessManager y UI corran **exactamente el digest de la imagen que pide `docker-stack.yml`**. Si alguno hizo rollback (por ejemplo, la VM no pudo bajar la imagen), falla en rojo y muestra el error de las tareas. |
| Limpieza | Recién después de la verificación: borra configs viejos que nadie usa e imágenes sin uso. |
| Agente de infraestructura | Mantiene el contenedor `newrelic-infra` en la VM. Solo lo recrea si cambió la imagen o la configuración. |
| Estado | `docker stack services snippetsearcher`. |

**Agente de infraestructura (`newrelic-infra`).** Envía a New Relic las métricas de la VM (`SystemSample`) y de cada
contenedor (`ContainerSample`). No se instala nada en la VM: Deploy Stack lo levanta con `docker run` por el contexto
`swarm-vm`, con `--restart unless-stopped`, así que vuelve solo al prender la VM. No va en `docker-stack.yml` porque
necesita `--privileged` y `--pid=host`, y un servicio de Swarm no los aplica.

- El nombre del host sale de `DOMAIN_NAME` (`snippet26dev` / `snippet26prod`) y el atributo `environment`, de la rama.
- Si falta el secret `NEW_RELIC_LICENSE_KEY`, el paso solo muestra un warning y no frena el deploy.
- La versión de la imagen está fija en `deploy.yml`. Para actualizarla, se cambia en las dos ramas.
- La clave queda en la configuración del contenedor: cualquiera con acceso a Docker en la VM puede leerla con
  `docker inspect`. New Relic desaconseja pasar secretos por variables de entorno. Se eligió así porque la alternativa
  es construir una imagen con la clave adentro.
- Esta imagen no incluye el reenvío de logs. Los logs siguen llegando por el agente de APM.
- Qué se ve en New Relic, las alertas y cómo usarlo: [NEW_RELIC.md](NEW_RELIC.md).

**Para qué está el `docker image prune`.** Para que no se llene el disco de la VM. Cada deploy baja una
imagen nueva de App, Runner, AccessManager y UI (las de Java pesan cientos de MB cada una) y **la vieja no se
borra sola**: queda en disco sin que nadie la use. Tras decenas de deploys son varios GB, y cuando el disco se
llena el siguiente pull falla con `no space left on device` y el servicio queda en la versión vieja.
`docker image prune -f` borra **solo imágenes que no usa ningún contenedor**: nunca las que están corriendo
ni los volúmenes (bases, Redis y Azurite quedan intactos).

Si se saca del workflow, hay que limpiar a mano cada tanto, cuando no haya un deploy corriendo:
```bash
docker system df          # cuánto ocupan imágenes, contenedores y volúmenes
docker image prune -f     # borra las imágenes sin uso
```

**Por qué la limpieza va al final (el bug de "no se actualiza").** `docker stack deploy` no espera: termina
mientras la VM todavía baja las imágenes. Un `docker image prune` en ese momento borra las capas a medio
extraer y el pull falla con `failed to Lchown ... no such file or directory` o `lease does not exist`. Swarm lo
muestra como `No such image`, hace rollback y queda la versión vieja. Pasaba con App y Runner (imágenes Java
grandes) y no con la UI (chica, terminaba antes del prune). El deploy viejo lo evitaba con un candado
(`flock`) en la VM; ahora el prune corre cuando la verificación confirmó que no queda ningún pull en curso.

**Redeploy forzado por un commit humano.** Va de a un servicio porque 2 CPUs
no alcanzan para arrancar todas las JVM a la vez, así que puede tardar bastante. Como la imagen es la misma, la
verificación no detectaría un rollback: si `docker service update` falla, el job termina en rojo en ese paso.
Si el commit también cambia el stack, un servicio puede reiniciarse dos veces en el mismo deploy.

### Cómo distingue un commit automático de uno humano

Lo decide el paso `Decide whether to force a redeploy` de `deploy.yml`, y se basa en el **autor del commit**.

**De dónde sale el autor.** El job `update-infra` de cada microservicio configura ese nombre antes de commitear:
```bash
git config user.name "github-actions[bot]"
```
Un commit hecho por una persona lleva su propio nombre de Git.

**Cómo lo lee Infra.** `github.event.before` es el commit en el que estaba la rama antes del push. El checkout usa
`fetch-depth: 0` para tener el historial, y con eso se recorren los commits de ese push:
```bash
force=false
if [ "$GITHUB_EVENT_NAME" = "push" ]; then
  files="$(
    for commit in $(git rev-list "$BEFORE..$GITHUB_SHA"); do
      [ "$(git log -1 --format=%an "$commit")" = "github-actions[bot]" ] && continue
      git -c core.quotepath=false diff-tree --no-commit-id --name-only -r "$commit"
    done
  )"
  if printf '%s\n' "$files" | grep -v '^$' | grep -qvi '\.md$'; then
    force=true
  fi
fi
```

Se lee así:

1. **`$GITHUB_EVENT_NAME` = `push`:** un *Run workflow* nunca fuerza.
2. **`git rev-list "$BEFORE..$GITHUB_SHA"`:** lista los commits que entraron con este push.
3. **`git log --format=%an`:** lee el autor de cada uno y saltea los automáticos.
4. **`diff-tree`:** lista los archivos de los commits humanos. `core.quotepath=false` evita que Git escape los
   acentos: sin eso, `Documentación/x.md` saldría entre comillas y no terminaría en `.md`.
5. **`grep -qvi '\.md$'`:** busca algún archivo que no termine en `.md`.

Si queda alguno, `force=true` y corre el paso `Force redeploy of the microservices`.

| Push | Commits humanos | Archivos que no son `.md` | ¿Fuerza? |
| :--- | :--- | :--- | :--- |
| `chore: update Docker image ...` de `update-infra` | Ninguno | - | No |
| Cambio en `deploy.yml` o `docker-stack.yml` | Sí | Sí | **Sí** |
| Cambio solo en documentación `.md` | Sí | No | No |
| Cambio en documentación y en `app.conf` | Sí | Sí | **Sí** |
| *Run workflow* | No aplica | - | No |

**Por qué el autor y no quien pushea.** `update-infra` pushea con el `PAT`, así que GitHub registra ese push a
nombre del dueño del token (`github.actor`): parecería hecho por una persona. El autor del commit sí es distinto.

**Casos a tener en cuenta:**
- Un `git revert` hecho a mano es un commit humano: si revierte una versión en `docker-stack.yml`, también
  reinicia los cuatro microservicios.
- El nombre lo define Git y no se valida: un commit humano con el autor `github-actions[bot]` no forzaría nada.
- Si un commit humano queda en espera y otro push lo reemplaza antes de que empiece su deploy, el forzado se
  pierde, porque cada run solo mira los commits de su propio push (ver *Concurrencia*). Se soluciona con otro commit.
- Para ver qué se decidió, abrir el paso en Actions: imprime `Forzar reinicio de los microservicios: true` o `false`.

**Sin redeploy forzado, un push que no cambia el stack no reinicia nada.** `docker stack deploy` compara la especificación nueva con
la que corre. Con `--resolve-image always` traduce cada tag a su digest actual: si es el mismo y los configs
tienen el mismo nombre (mismo hash), no hay diferencia y no se toca ningún servicio. Por eso no hace falta
filtrar qué archivos dispararon el push: uno de docs termina sin cambios. Antes el script forzaba
`docker service update --force` de todos los servicios y cada push de Infra eran ~4 minutos de 502.

**VM apagada.** Si se pushea (a Infra o a un microservicio) con la VM apagada, Deploy Stack falla al conectarse
(`i/o timeout` o error en `Add VM to known hosts`) y nadie lo reintenta. Al prenderla, Swarm levanta lo que tenía;
para traer lo último: *Actions → Deploy Stack → Run workflow* sobre `develop` (dev) o `main` (prod). Ese único run
pone cada servicio en la versión anotada en `docker-stack.yml`. Si fallaron varios deploys seguidos, alcanza con
ese run: cada commit ya quedó en la rama.

**Concurrencia**: `stack-<rama>`, un deploy del stack a la vez por ambiente. Si llegan varios pushes seguidos,
GitHub deja en espera solo el último y cancela los intermedios, que pueden aparecer como `cancelled`. No se
pierden versiones: ese último run aplica el `docker-stack.yml` completo.

**La versión se anota con el commit y se despliega con el próximo run que corra.** El commit de `update-infra`
deja la versión en `docker-stack.yml`, y ese commit dispara un Deploy Stack. Si ese run corre, despliega la
versión. Si lo reemplazan mientras espera, la despliega el run que corra después, porque cada deploy aplica el
archivo completo:

```
                 Corriendo     Esperando
Commit de App    App           -
Commit de Access App           Access
Commit de Runner App           Runner     → Access queda cancelled
Commit de UI     App           UI         → Runner queda cancelled
App termina      UI            -          → aplica las 4 versiones y las verifica
```

- Un run `cancelled` en espera **no ejecutó ningún paso ni tocó la VM**. Se canceló el run, no la versión anotada.
- Un run que ya está corriendo no se cancela (`cancel-in-progress: false`).
- Si el **último** Deploy Stack de la rama está en verde, los `cancelled` anteriores se pueden ignorar.
- Si el deploy falla, por ejemplo con la VM apagada, la versión sigue anotada pero nadie reintenta: se aplica con
  *Run workflow* o con el próximo push a esa rama de Infra.

---

## 7. Secrets, variables y environments

Un **environment** de GitHub agrupa secrets y variables. El job elige uno con `environment:` y, dentro del job,
`secrets.X` y `vars.X` se resuelven contra ese environment. Si un secret no está ahí, GitHub busca en el
repositorio y después en la organización.

| Nombre | Tipo | Dónde | Lo usa | Para qué |
| :--- | :--- | :--- | :--- | :--- |
| `SSH_HOST` | Secret | env `develop` / `production` | Infra | IP o host de cada VM |
| `SSH_USER` | Secret | env `develop` / `production` | Infra | Usuario SSH (tiene que poder usar `docker` sin sudo) |
| `SSH_PRIVATE_KEY` | Secret | env `develop` / `production` | Infra | Clave privada; la pública está en `~/.ssh/authorized_keys` de la VM |
| `PAT` | Secret | organización | Microservicios e Infra | Commit en Infra desde `update-infra` y login a GHCR desde Infra (las imágenes son privadas: Swarm las baja con esta credencial) |
| `NEW_RELIC_LICENSE_KEY` | Secret | env `develop` / `production` | `deploy.yml` | Clave del agente de infraestructura |
| `GHCR_USER` | Secret | organización | Solo `update_service.yml`, sin uso | Usuario del login a GHCR del esquema anterior. `deploy.yml` usa `github.actor` |
| `GITHUB_TOKEN` | Automático | cada run | Microservicios | Push de la imagen a GHCR y paquetes de PrintScript |
| `VITE_AUTH0_*`, `VITE_BACKEND_URL` | Secret | repo UI | UI | Build-args del bundle |
| `DOMAIN_NAME` | **Variable** | env `develop` / `production` | `deploy.yml` | Dominio de nginx y ruta del certificado. Obligatoria. |
| `NEW_RELIC_APP_NAME_*` | **Variable** | env `develop` / `production` | `deploy.yml` | Nombre de cada servicio en New Relic (por defecto `*_dev`) |

`SSH_HOST` y `SSH_DIRECTORY` a nivel repositorio son de una configuración vieja: los workflows actuales no los usan.

Cómo llega una variable hasta el contenedor:
```
vars.NEW_RELIC_APP_NAME_APP (environment de GitHub)
  → env: del job en deploy.yml
  → docker stack deploy reemplaza ${NEW_RELIC_APP_NAME_APP:-AppIngsis_dev} en docker-stack.yml (en el runner)
  → el servicio arranca con NEW_RELIC_APP_NAME=<valor>
  → el agente de New Relic de la imagen lo usa como nombre de la app
```

---

## 8. Qué pasa en la VM: Swarm

La VM es un nodo de Docker Swarm (manager). El stack `snippetsearcher` define servicios con réplicas
(App, Runner, AccessManager y UI con 2), y Swarm se encarga de mantenerlas.

| Mecanismo | Configuración (`docker-stack.yml`) | Efecto |
| :--- | :--- | :--- |
| Healthcheck | `bash -c '</dev/tcp/127.0.0.1/8080'`, `start_period: 900s` | Swarm solo manda tráfico a réplicas que abrieron el 8080. Los 15 minutos de gracia cubren el arranque al prender la VM: 6 JVM sobre 2 CPUs (load average ~28). Con 7 minutos, el App no llegaba, Swarm lo mataba como `unhealthy` (exit 137) y el ciclo no terminaba. |
| Opciones de la JVM | `JAVA_TOOL_OPTIONS: -XX:TieredStopAtLevel=1` | Solo el compilador JIT rápido: arranque más corto y mucho menos CPU al inicio, a cambio de algo menos de rendimiento sostenido. |
| Rolling update | `parallelism: 1`, `order: start-first` | Levanta la réplica nueva antes de bajar la vieja: actualizar no corta el servicio. |
| Rollback | `failure_action: rollback`, `monitor: 60s` | Si la versión nueva no pasa el healthcheck, vuelve sola a la anterior. |
| Reinicio | `restart_policy: condition: any` | Si un contenedor muere, Swarm lo vuelve a levantar. También al reiniciar la VM. |
| Red interna | DNS de Swarm (`snippetsearcher-app`, `redis`, ...) | Los servicios se encuentran por nombre; el balanceo entre réplicas es automático. |
| nginx | Único servicio con 80/443 | Entrada pública: `/` → UI y `/api/` → App. Runner y AccessManager no están publicados (ver [SEGURIDAD.md](SEGURIDAD.md)). Resuelve cada servicio **en cada request** (`resolver 127.0.0.11` + `proxy_pass $variable`): arranca aunque el App todavía no exista y esa ruta responde 502 hasta que esté listo. Antes, con el nombre fijo, nginx no levantaba (`host not found in upstream`) mientras el App arrancaba. |

---

## 9. Qué pasa cuando algo falla

| Falla | Qué se ve | Qué hacer |
| :--- | :--- | :--- |
| Lint, detekt, tests o cobertura | El job `ci-cd` del microservicio en rojo | Arreglar y pushear. No se publicó imagen. |
| VM apagada durante un push | `deploy.yml` en rojo (`i/o timeout` o error al conectar por SSH) | Prender la VM y correr *Actions → Deploy Stack → Run workflow* (rama `develop` o `main`). |
| La IP de la VM cambió | `i/o timeout` aunque la VM esté prendida | Actualizar `SSH_HOST` en el environment y DuckDNS; poner la IP como estática en Azure. |
| La VM no puede bajar la imagen | Tareas `Rejected` con `No such image: ...@sha256:...`, `rollback completed`, y la versión vieja sigue corriendo | `No such image` solo dice que el pull falló. La causa real: `sudo journalctl -u docker \| grep 'pulling image failed'`. Si dice `failed to Lchown ... no such file or directory` o `lease does not exist`, un `docker image prune` borró las capas mientras se bajaban (ver abajo). Si dice `denied` / `unauthorized`, es el token de GHCR. Los workflows fallan en rojo en este caso (antes terminaban en verde). |
| La versión nueva no arranca | La verificación de `deploy.yml` sigue en `Esperando:` y termina en rollback | La VM sigue con la versión anterior y el workflow falla. Ver logs: `docker service logs snippetsearcher_<servicio>`. |
| El redeploy forzado falla | `Force redeploy of the microservices` en rojo | Ese servicio volvió a la tarea anterior y los que seguían no se reiniciaron. Ver logs: `docker service logs snippetsearcher_<servicio>`. |
| Un commit humano no reinició los servicios | `Force redeploy of the microservices` queda `skipped` | Leer `Forzar reinicio de los microservicios: true/false` en el paso anterior. No fuerza si el push tocó solo `.md`, si fue *Run workflow* o si otro push reemplazó ese run en espera. |
| Falla `Update image version` en un microservicio | `update-infra` en rojo; la imagen se publicó, pero no aparece el commit en Infra | El paso ya reintenta 6 veces, así que no es un choque común. Leer el error y usar **Re-run failed jobs**. Revisar el `PAT` si dice `denied` o `403`. |
| Falla la verificación por tiempo | `Timeout esperando: <servicios>` a los 40 minutos | Ver el estado con `docker service ps snippetsearcher_<servicio> --no-trunc`. El deploy pudo haber quedado a medias. |
| Al prender la VM, las JVM no terminan de arrancar | App, Runner y AccessManager en `0/2` durante mucho tiempo, `load average` muy alto (~30 en 2 CPUs), tareas `Failed ... exit (137): unhealthy container` cada pocos minutos | Las 6 JVM compiten por la CPU y ninguna abre el 8080 antes de que el healthcheck la mate, así que vuelven a arrancar en un ciclo. Para cortarlo una vez: `docker service scale <app>=1 <runner>=1 <accessmanager>=1`, esperar `1/1` y volver a `=2`. Prevención: `start_period: 900s` y `-XX:TieredStopAtLevel=1` (§8). |
| Un servicio no encuentra su base (`UnknownHostException: appdb`) | El servicio se cae con `exit (1)`; en el log, `Unable to determine Dialect without JDBC metadata` y más abajo `Caused by: java.net.UnknownHostException: appdb`. La base está `1/1` y dice `ready to accept connections`. | Swarm perdió el registro DNS de ese servicio (pasa a veces después de un reinicio): tiene su IP virtual pero el nombre no resuelve. Diagnóstico desde otro contenedor: `docker exec <runner> getent hosts appdb` no devuelve nada. Arreglo: `docker service update --force snippetsearcher_appdb` (recrea la tarea y la vuelve a registrar; los datos están en el volumen y no se tocan). |
| Falta `DOMAIN_NAME` | `deploy.yml` falla con *"DOMAIN_NAME es obligatorio"* | Cargar la variable en el environment. No se tocó nada. |
| Cambio de config de nginx con error | nginx no levanta tras el deploy (rollback del servicio) | Corregir `app.conf`; probar antes con `nginx -t`. |

---

## 10. Problemas conocidos

- **Cypress no corre en CI** (la UI no tiene script `test`): los e2e solo corren a mano.
- **`update_service.yml` sigue en el repo** aunque nadie lo dispara, y `GHCR_USER` solo lo usa ese workflow.
- **Contraseñas en texto plano** en `docker-stack.yml`, y el repo es público. Ver la parte opcional de VM_LIMPIA.

---

## 11. Preguntas para repasar

1. **¿Por qué los microservicios no despliegan directamente en la VM?** Para que solo Infra conozca la VM: cada
   microservicio publica su imagen y anota la versión en `docker-stack.yml`.
2. **¿Por qué `PAT` y no `GITHUB_TOKEN` para escribir en Infra?** El `GITHUB_TOKEN` solo tiene permisos sobre su
   propio repo, y sus pushes no disparan workflows.
3. **¿Por qué el stack usa el tag fijo?** Para que la versión de cada ambiente quede registrada en Git y se pueda
   volver atrás con un `git revert`. El digest se usa para verificar que cada réplica corra esa imagen exacta.
4. **¿Qué pasa si pusheo con la VM apagada?** El deploy falla y nadie lo reintenta. Al prenderla, *Run
   workflow* de *Deploy Stack* trae lo último de todos los servicios.
5. **¿Por qué un push de docs a Infra no reinicia nada?** `docker stack deploy` solo actualiza servicios cuya
   especificación cambió (digest de imagen o nombre de config), y un commit solo de `.md` no fuerza el reinicio.
6. **¿Por qué el tag de prod es `:production` si la rama de prod de Infra es `main`?** El tag sale de la rama del
   microservicio, y ahí la rama de prod es `production`. Por eso `update-infra` traduce `production` a `main`.
7. **¿Cómo se evita cortar el servicio al actualizar?** `order: start-first` + healthcheck: la réplica nueva
   tiene que estar sana antes de bajar la vieja; si nunca lo está, rollback.
8. **¿Qué archivos del proyecto hay en la VM?** Ninguno: el stack, la config de nginx y los SQL viajan desde
   Actions por la API de Docker (contexto `swarm-vm` por SSH). Solo quedan `~/.ssh` y `/etc/letsencrypt`.
9. **¿Por qué no se mergea `develop` en `main` en Infra?** Sus `docker-stack.yml` tienen versiones distintas a
   propósito: un merge podría poner imágenes de desarrollo en producción.
10. **¿Por qué el commit automático no reinicia todo?** Porque cada push a un microservicio llega a Infra como
    un commit: si forzara, un cambio en Runner reiniciaría App, AccessManager y UI.
