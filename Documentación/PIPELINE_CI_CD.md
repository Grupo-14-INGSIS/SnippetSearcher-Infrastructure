# Pipeline CI/CD: del push al servicio corriendo en la VM

## Índice
- [1. Vista general](#1-vista-general)
- [2. Ramas, ambientes y tags](#2-ramas-ambientes-y-tags)
- [3. CI/CD de cada microservicio](#3-cicd-de-cada-microservicio)
- [4. Dispatch a Infra](#4-dispatch-a-infra)
- [5. update_service.yml: actualizar un servicio](#5-update_serviceyml-actualizar-un-servicio)
- [6. deploy.yml: desplegar el stack](#6-deployyml-desplegar-el-stack)
- [7. Secrets, variables y environments](#7-secrets-variables-y-environments)
- [8. Qué pasa en la VM: Swarm](#8-qué-pasa-en-la-vm-swarm)
- [9. Qué pasa cuando algo falla](#9-qué-pasa-cuando-algo-falla)
- [10. Problemas conocidos](#10-problemas-conocidos)
- [11. Preguntas para repasar](#11-preguntas-para-repasar)

---

## 1. Vista general

```
 push a un microservicio (App, Runner, AccessManager, UI)
   │
   ├─ job ci-cd ........ lint · detekt · tests · cobertura · build      (falla → no se publica nada)
   ├─ job build-and-push  docker build + push a GHCR:  :<rama>  y  :<rama>-<sha>
   └─ dispatch ......... POST /repos/.../SnippetSearcher-Infrastructure/dispatches
                         { event_type: new-image-ready, environment: <rama>, service: <servicio> }
                                   │
                                   ▼
 Infra: update_service.yml (repository_dispatch)
   ├─ solo ramas develop / production (las de features se saltean)
   ├─ resuelve el digest de ghcr.io/...:<rama>
   └─ DOCKER_HOST=ssh://vm  docker service update --image <imagen>@<digest>
                                   │
                                   ▼
 VM (Swarm manager): rolling update, healthcheck, rollback si la versión nueva no arranca

 push a Infra (develop o main)  ─┐
                                 ├─▶ deploy.yml: docker stack deploy (todo el stack)
 Run workflow (manual)          ─┘
```

Dos caminos llegan a la VM y los dos son **desde GitHub Actions**: la VM no corre ningún script ni guarda
archivos del proyecto (ver [VM_LIMPIA.md](VM_LIMPIA.md)).

| Camino | Disparador | Qué actualiza | Velocidad |
| :--- | :--- | :--- | :--- |
| `update_service.yml` | Push a un microservicio (`develop` / `production`) | **Ese** servicio | Al instante |
| `deploy.yml` | Push a Infra (`develop` / `main`), o *Run workflow* | **Todo** el stack (solo cambia lo que difiere) | Al instante |

No hay deploys automáticos sin un push: si la VM estaba apagada, al prenderla se corre *Deploy Stack* a mano.

---

## 2. Ramas, ambientes y tags

**Los nombres de las ramas de prod no coinciden entre repos.** Es la fuente de confusión más común:

| | Dev | Prod |
| :--- | :--- | :--- |
| Rama de los **microservicios** (App, Runner, AccessManager, UI) | `develop` | **`production`** (`main` / `master` quedaron sin uso) |
| Rama de **Infra** | `develop` | **`main`** |
| **Tag** de las imágenes en GHCR | `:develop` | `:production` |
| **Environment** de GitHub (en Infra) | `develop` | `production` |
| VM | `snippet26dev.duckdns.org` | `snippet26prod.duckdns.org` |

Cada imagen se publica con dos tags:
- `:<rama>` (por ejemplo `:develop`): se mueve con cada push. Es el que usa el stack.
- `:<rama>-<sha del commit>`: fijo. Sirve para volver a una versión exacta a mano.

Las imágenes viven en GHCR (`ghcr.io/grupo-14-ingsis/...`). La de la UI se llama `printscript-ui`, y el
servicio de Swarm, `snippetsearcher-ui`.

---

## 3. CI/CD de cada microservicio

Archivo: `.github/workflows/ci-cd.yml` (UI: `ci.yaml`). Se dispara con **cualquier push, a cualquier rama**.

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
| Dispatch | Avisa a Infra (sección 4) | No se despliega |

El job `build-and-push` solo corre si `ci-cd` pasó: **una imagen publicada siempre pasó lint y tests.**
El Runner necesita el token también para compilar (`GITHUB_TOKEN` como build-arg): baja el intérprete de
PrintScript desde GitHub Packages.

### UI (printscript-ui)
`npm ci` → `npm run lint` → `npm test --if-present` → `npm run build` → `docker build` + push → dispatch.
- `npm test --if-present` **no ejecuta nada**: no hay script `test`, así que Cypress no corre en CI.
- Las variables `VITE_AUTH0_*` se pasan como build-args (Vite las embebe en el bundle al compilar).
- En el navegador, la URL del backend sale de `window.location.origin` cuando no es `localhost`, así que la
  misma imagen funciona en cualquier dominio (`src/utils/constants.ts`).

---

## 4. Dispatch a Infra

El último paso de cada microservicio:
```bash
curl -X POST -H "Authorization: Bearer $PAT" \
  https://api.github.com/repos/Grupo-14-INGSIS/SnippetSearcher-Infrastructure/dispatches \
  -d '{"event_type":"new-image-ready","client_payload":{"environment":"<rama>","service":"snippetsearcher-app"}}'
```
- **`repository_dispatch`** es un evento de GitHub que dispara workflows *en otro repo*. Así cada
  microservicio no necesita saber nada de la VM: solo avisa "hay imagen nueva de X en la rama Y".
- Usa `PAT` (secret de la organización) porque el `GITHUB_TOKEN` de un repo no puede disparar workflows en otro.
- `environment` es la **rama del microservicio**, no un environment de GitHub (aunque Infra la usa para elegirlo).

### Cómo sabe Infra de qué servicio y de qué ambiente viene

Todo llega por el mismo workflow (`update_service.yml`), así que la única forma de distinguir es el
**`client_payload`** del dispatch. Infra no adivina nada: lee dos campos.

```json
{
  "event_type": "new-image-ready",
  "client_payload": {
    "service": "snippetsearcher-runner",   ← QUÉ servicio
    "environment": "production"            ← DE QUÉ ambiente
  }
}
```

| Campo | De dónde sale | Ejemplo |
| :--- | :--- | :--- |
| `service` | **Escrito a mano** en el `ci-cd.yml` de cada repo: cada uno manda siempre su propio nombre | Runner → `snippetsearcher-runner`, App → `snippetsearcher-app`, AccessManager → `snippetsearcher-accessmanager`, UI → `snippetsearcher-ui` |
| `environment` | `$GITHUB_REF_NAME`: la **rama** donde se pusheó | push a `develop` → `develop`; push a `production` → `production` |

Qué hace `update_service.yml` con cada uno:

| Dato | Se usa para | `runner` + `production` | `ui` + `develop` |
| :--- | :--- | :--- | :--- |
| `environment` | Elegir el **environment de GitHub** → sus `SSH_HOST` / `SSH_USER` / `SSH_PRIVATE_KEY` → **a qué VM** va | `production` → VM de prod | `develop` → VM de dev |
| `environment` | **Tag** de la imagen | `:production` | `:develop` |
| `service` | **Repo de la imagen** en GHCR | `snippetsearcher-runner` | `printscript-ui` (la UI se llama distinto) |
| `service` | **Servicio de Swarm** a actualizar | `snippetsearcher_snippetsearcher-runner` | `snippetsearcher_snippetsearcher-ui` |

```yaml
# update_service.yml
environment: ${{ github.event.client_payload.environment == 'production' && 'production' || 'develop' }}
if: contains(fromJSON('["develop", "production"]'), github.event.client_payload.environment)
env:
  SERVICE_NAME: ${{ github.event.client_payload.service }}       # qué servicio
  BRANCH: ${{ github.event.client_payload.environment }}         # de qué ambiente (y tag)
```

Resultado para `runner` + `production`:
```
DOCKER_HOST=ssh://<SSH_HOST de production>
docker service update --image ghcr.io/grupo-14-ingsis/snippetsearcher-runner:production@sha256:… \
  snippetsearcher_snippetsearcher-runner
```

La concurrencia también usa los dos campos (`deploy-<environment>-<service>`): un update a la vez por servicio
y ambiente, sin que el de un servicio cancele el de otro.

`deploy.yml` no necesita esto: no actualiza un servicio sino **todo el stack**, y el ambiente sale de la
**rama de Infra** que se pusheó (`develop` → VM de dev, `main` → VM de prod con imágenes `:production`).

---

## 5. `update_service.yml`: actualizar un servicio

Se dispara con `repository_dispatch` de tipo `new-image-ready`.

```yaml
environment: ${{ github.event.client_payload.environment == 'production' && 'production' || 'develop' }}
if: contains(fromJSON('["develop", "production"]'), github.event.client_payload.environment)
```

1. **Filtra ramas.** Solo `develop` y `production`. Las de features (`caso9`, `12y15`, ...) también publican
   imagen y hacen dispatch, pero se saltean. Antes no se filtraban: pisaban la VM de dev con la imagen de la
   feature, y GitHub creaba un environment por cada rama (por eso hay environments `caso9`, `12y15`, etc.).
2. **Valida el servicio** contra la lista conocida.
3. **Resuelve el digest** de `ghcr.io/...:<rama>` en el runner (`docker buildx imagetools inspect`).
4. **Actualiza el servicio pineando el digest**:
   `DOCKER_HOST=ssh://vm docker service update --with-registry-auth --image <imagen>:<rama>@<digest> snippetsearcher_<servicio>`.
   Con el digest, Swarm baja exactamente esa imagen. Con solo el tag podría reutilizar una imagen cacheada en el
   nodo y quedar con la versión vieja aunque el workflow termine en verde.

**Concurrencia**: un grupo por ambiente y servicio (`deploy-<rama>-<servicio>`). Si fuera uno solo por ambiente,
GitHub cancelaría ("superseded") los runs pendientes cuando llegan varios dispatches juntos (App, Runner y UI a la
vez) y algún servicio quedaría sin actualizar.

---

## 6. `deploy.yml`: desplegar el stack

Disparadores:
- `push` a `develop` o `main` (cualquier archivo de Infra).
- `workflow_dispatch` (botón *Run workflow*): para redeployar a mano, por ejemplo al prender la VM.

`environment` = `develop` para la rama `develop`, `production` para `main`. Sobre otra rama el job no corre.

| Paso | Qué hace |
| :--- | :--- |
| SSH | Escribe la clave (`SSH_PRIVATE_KEY`), agrega la VM a `known_hosts` y define `DOCKER_HOST=ssh://vm`. |
| Login GHCR | En el runner, con `PAT`. |
| Hash de configs | Calcula el hash de `app.conf` y de los SQL (los configs de Swarm son inmutables; ver VM_LIMPIA). |
| Deploy | `docker stack deploy --with-registry-auth --resolve-image always -c docker-stack.yml snippetsearcher` |
| Verificación | Espera (hasta 20 min) a que App, Runner, AccessManager y UI corran **exactamente el digest actual** de su tag. Si alguno hizo rollback (por ejemplo, la VM no pudo bajar la imagen), falla en rojo y muestra el error de las tareas. |
| Limpieza | Recién después de la verificación: borra configs viejos que nadie usa e imágenes sin uso. |

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

**Un push que no cambia el stack no reinicia nada.** `docker stack deploy` compara la especificación nueva con
la que corre. Con `--resolve-image always` traduce cada tag a su digest actual: si es el mismo y los configs
tienen el mismo nombre (mismo hash), no hay diferencia y no se toca ningún servicio. Por eso no hace falta
filtrar qué archivos dispararon el push: uno de docs termina sin cambios. Antes el script forzaba
`docker service update --force` de todos los servicios y cada push de Infra eran ~4 minutos de 502.

**VM apagada.** Si se pushea (a Infra o a un microservicio) con la VM apagada, el job falla con `i/o timeout`
y nadie lo reintenta. Al prenderla, Swarm levanta lo que tenía; para traer lo último: *Actions → Deploy Stack →
Run workflow* sobre `develop` (dev) o `main` (prod). Como `--resolve-image always` trae el digest actual de cada
tag, ese único run pone al día todos los servicios, también los que vinieron por dispatch.

**Concurrencia**: `stack-<rama>`, un deploy del stack a la vez por ambiente. No comparte grupo con
`update_service.yml`: si los dos corren a la vez, el `docker image prune` del final podría borrar capas que el
otro está bajando (es raro: los pushes a Infra son poco frecuentes).

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
| `PAT` | Secret | organización | Microservicios e Infra | Dispatch a Infra y login a GHCR desde Infra (las imágenes son privadas: Swarm las baja con esta credencial) |
| `GHCR_USER` | Secret | organización | Infra | Usuario del login a GHCR |
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
| Healthcheck | `bash -c '</dev/tcp/127.0.0.1/8080'`, `start_period: 420s` | Swarm solo manda tráfico a réplicas que abrieron el 8080. Los 7 minutos de gracia cubren el arranque lento de las JVM al prender la VM. |
| Rolling update | `parallelism: 1`, `order: start-first` | Levanta la réplica nueva antes de bajar la vieja: actualizar no corta el servicio. |
| Rollback | `failure_action: rollback`, `monitor: 60s` | Si la versión nueva no pasa el healthcheck, vuelve sola a la anterior. |
| Reinicio | `restart_policy: condition: any` | Si un contenedor muere, Swarm lo vuelve a levantar. También al reiniciar la VM. |
| Red interna | DNS de Swarm (`snippetsearcher-app`, `redis`, ...) | Los servicios se encuentran por nombre; el balanceo entre réplicas es automático. |
| nginx | Único servicio con 80/443 | Entrada pública: `/` → UI, `/api/` → App, `/runner/` → Runner, `/access/` → AccessManager. |

---

## 9. Qué pasa cuando algo falla

| Falla | Qué se ve | Qué hacer |
| :--- | :--- | :--- |
| Lint, detekt, tests o cobertura | El job `ci-cd` del microservicio en rojo | Arreglar y pushear. No se publicó imagen. |
| VM apagada durante un push | `update_service.yml` o `deploy.yml` en rojo (`i/o timeout` en el puerto 22) | Prender la VM y correr *Actions → Deploy Stack → Run workflow* (rama `develop` o `main`). |
| La IP de la VM cambió | `i/o timeout` aunque la VM esté prendida | Actualizar `SSH_HOST` en el environment y DuckDNS; poner la IP como estática en Azure. |
| La VM no puede bajar la imagen | Tareas `Rejected` con `No such image: ...@sha256:...`, `rollback completed`, y la versión vieja sigue corriendo | `No such image` solo dice que el pull falló. La causa real: `sudo journalctl -u docker \| grep 'pulling image failed'`. Si dice `failed to Lchown ... no such file or directory` o `lease does not exist`, un `docker image prune` borró las capas mientras se bajaban (ver abajo). Si dice `denied` / `unauthorized`, es el token de GHCR. Los workflows fallan en rojo en este caso (antes terminaban en verde). |
| La versión nueva no arranca | `docker service update` tarda y termina en rollback | La VM sigue con la versión anterior y el workflow falla. Ver logs: `docker service logs snippetsearcher_<servicio>`. |
| Falta `DOMAIN_NAME` | `deploy.yml` falla con *"DOMAIN_NAME es obligatorio"* | Cargar la variable en el environment. No se tocó nada. |
| Cambio de config de nginx con error | nginx no levanta tras el deploy (rollback del servicio) | Corregir `app.conf`; probar antes con `nginx -t`. |

---

## 10. Problemas conocidos

- **Cypress no corre en CI** (la UI no tiene script `test`): los e2e solo corren a mano.
- **AccessManager también corre en `pull_request`**: en un PR, `GITHUB_REF_NAME` es `<n>/merge` y ese tag de
  Docker es inválido, así que `build-and-push` falla en los PR.
- **Ramas con `/`** (por ejemplo `feature/x`) producen un tag inválido y el push de la imagen falla.
- **Imágenes por cada rama**: cada push de una feature publica una imagen en GHCR que nunca se despliega.
- **Contraseñas en texto plano** en `docker-stack.yml`, y el repo es público. Ver la parte opcional de VM_LIMPIA.
- **La UI de CI imprime un secret** en el paso *Debug Auth0 Domain* (GitHub lo enmascara, pero sobra).

---

## 11. Preguntas para repasar

1. **¿Por qué los microservicios no despliegan directamente en la VM?** Para que solo Infra conozca la VM:
   cada microservicio publica su imagen y avisa con un `repository_dispatch`.
2. **¿Por qué `PAT` y no `GITHUB_TOKEN` para el dispatch?** El `GITHUB_TOKEN` solo tiene permisos sobre su
   propio repo.
3. **¿Por qué se pinea el digest?** Para que Swarm baje exactamente la imagen recién publicada y no reutilice
   una cacheada con el mismo tag.
4. **¿Qué pasa si pusheo con la VM apagada?** El deploy falla y nadie lo reintenta. Al prenderla, *Run
   workflow* de *Deploy Stack* trae lo último de todos los servicios.
5. **¿Por qué un push de docs a Infra no reinicia nada?** `docker stack deploy` solo actualiza servicios cuya
   especificación cambió (digest de imagen o nombre de config).
6. **¿Por qué el tag de prod es `:production` si la rama de prod de Infra es `main`?** El tag es la rama del
   microservicio, y en los microservicios la rama de prod es `production`.
7. **¿Cómo se evita cortar el servicio al actualizar?** `order: start-first` + healthcheck: la réplica nueva
   tiene que estar sana antes de bajar la vieja; si nunca lo está, rollback.
8. **¿Qué archivos del proyecto hay en la VM?** Ninguno: el stack, la config de nginx y los SQL viajan desde
   Actions por la API de Docker (`DOCKER_HOST=ssh://`). Solo quedan `~/.ssh` y `/etc/letsencrypt`.
