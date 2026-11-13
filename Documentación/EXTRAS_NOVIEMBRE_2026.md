# Extras agregados en noviembre de 2026

Este archivo junta **solo lo que se sumó o cambió en esta tanda de trabajo**. Para el detalle de cada tema, seguí el
link de la última columna.

## Índice
- [1. Cambios de arquitectura y comportamiento](#1-cambios-de-arquitectura-y-comportamiento)
- [2. Seguridad](#2-seguridad)
- [3. CI/CD y deploy](#3-cicd-y-deploy)
- [4. Observabilidad (New Relic)](#4-observabilidad-new-relic)
- [5. Tests de carga](#5-tests-de-carga)
- [6. Documentación nueva o actualizada](#6-documentación-nueva-o-actualizada)
- [7. Decisiones tomadas](#7-decisiones-tomadas)
- [8. Qué queda por hacer](#8-qué-queda-por-hacer)
- [9. Orden de deploy](#9-orden-de-deploy)
- [10. Sin JSONB en las bases (9/11)](#10-sin-jsonb-en-las-bases-911)
- [11. Limpieza de código muerto (13/11)](#11-limpieza-de-código-muerto-1311)

---

## 1. Cambios de arquitectura y comportamiento

Para el usuario, la app hace lo mismo. Cambia el camino por dentro y se cierran agujeros de seguridad.

Antes, **la UI ya hablaba casi todo con App**. Solo en tres casos iba directo al Runner por `/runner/`: crear un
snippet con código, guardar el código editado y, como plan B, leer el contenido. AccessManager nunca lo llamaba
directo. El problema real era que nginx dejaba **`/runner/` y `/access/` abiertos a internet sin token**: cualquiera
podía leer, editar o borrar snippets ajenos. Para cerrarlos, primero hubo que pasar esos tres casos a App.

```
ANTES                                             AHORA
UI ──/api/────▶ App   (casi todo)                 UI ──/api/──▶ App ──▶ Runner
UI ──/runner/─▶ Runner (crear con código,                         └──▶ AccessManager
                        editar código, plan B)    Runner ──/internal/──▶ App   (red interna)
/runner/ y /access/ abiertos sin token            /runner/ y /access/ cerrados
```

| Cambio | Antes | Ahora | Detalle |
| :--- | :--- | :--- | :--- |
| Rutas públicas de nginx | `/`, `/api/`, `/runner/`, `/access/` | Solo `/` y `/api/` | [SEGURIDAD.md](SEGURIDAD.md) |
| Crear un snippet con código | La UI llamaba al Runner directo | `PUT /api/v1/snippets/{id}` con `content`. App lo pasa al Runner, y el Runner lo registra en App por `/internal/snippets/{id}` | [CASOS_DE_USO_RECORRIDO.md](CASOS_DE_USO_RECORRIDO.md) |
| Editar el código | La UI llamaba al Runner directo | `PATCH /api/v1/snippets/{id}` con `content`. Solo el dueño | [RUTAS_REST.md](RUTAS_REST.md) |
| Leer el contenido | App, y si no venía, la UI se lo pedía al Runner | Solo App. Si no hay contenido, se abre vacío | [RUTAS_REST.md](RUTAS_REST.md) |
| Abrir un snippet ajeno no compartido | Funcionaba | `403` | [SEGURIDAD.md](SEGURIDAD.md) |
| Dueño de un snippet | Venía en el body (`userId`) | Sale del token (`sub`). El `userId` del body se ignora | [SEGURIDAD.md](SEGURIDAD.md) |
| `GET /api/v1/snippets/{id}` | Sin control de permiso | Requiere token y ser dueño o compartido (si no, `403`) | [SEGURIDAD.md](SEGURIDAD.md) |
| Rutas no declaradas de App | Sin regla explícita | `403` (`denyAll`). Solo se permiten `/api/**` con token, `/internal/**` y el health | [SEGURIDAD.md](SEGURIDAD.md) |
| Health check | No había | `/api/actuator/health`: App, su base, Redis, Runner y AccessManager. Responde solo `UP` o `DOWN` | [NEW_RELIC.md](NEW_RELIC.md) |
| Timeout de `/api/` en nginx | 300 s | 600 s (guardar un snippet corre sus tests) | [HTTPS_NGINX_CORS_NEW.md](HTTPS_NGINX_CORS_NEW.md) |

Los cambios de código están en App (`SecurityConfig`, `SnippetController`, `InternalSnippetController` nuevo,
`RunnerClient`), Runner (`AppClient` usa `/internal`), y la UI (`api.ts` y `queries.tsx` van todo por App).

## 2. Seguridad

- App valida también el **`aud`** del token (`https://api.snippets.com`), además de firma, `iss` y `exp`.
- Se sacó el **`clientSecret` de Auth0** de `application.yml` (App no lo usaba).
- La **license key de New Relic** salió de `newrelic.yml`: llega por la variable `NEW_RELIC_LICENSE_KEY`, desde el
  secret de los environments de GitHub de Infra.
- Documento nuevo: [SEGURIDAD.md](SEGURIDAD.md), que cubre autenticación, autorización, superficie expuesta, secretos y cómo probarlo.

## 3. CI/CD y deploy

| Extra | Qué resuelve | Detalle |
| :--- | :--- | :--- |
| Redeploy forzado solo con commit humano en Infra | **Nuevo.** Un commit de una persona en Infra reinicia los 4 microservicios; los commits automáticos de los servicios, no | [PIPELINE_CI_CD.md](PIPELINE_CI_CD.md) |
| `concurrency` y reintentos en `update-infra` | **Mejorado.** `update-infra` ya existía (desde el 2/11) y escribe la versión de la imagen en el stack de Infra. Ahora, si llegan varios pushes juntos, no se pisan: los intermedios quedan `cancelled` y el último aplica el stack completo | [PIPELINE_CI_CD.md](PIPELINE_CI_CD.md) |
| Verificación antes del `prune` | **Recuperado.** Existía desde el 18/10 y se había perdido. No se borran imágenes viejas hasta comprobar que los servicios nuevos levantaron | [PIPELINE_CI_CD.md](PIPELINE_CI_CD.md) |
| Contenedor `newrelic-infra` | Métricas de la VM y de los contenedores sin instalar nada en la VM | [NEW_RELIC.md](NEW_RELIC.md) |
| Espera a la base en el stack (`entrypoint: *wait-for-db`) | **Nuevo (10/11).** App, Runner y AccessManager no lanzan la JVM hasta que su Postgres acepta conexiones. Antes, si el servicio arrancaba primero, se caía y Swarm hacía rollback. Reemplaza al script de systemd de la VM, que no se instalaba solo | [PIPELINE_CI_CD.md](PIPELINE_CI_CD.md), sección 8 |
| Servicio `nginx-logs` en el stack | Logs de nginx en New Relic, sin instalar nada en la VM. nginx loguea en JSON, le pasa el `X-Request-Id` a App y su log rota a los 10 MB | [NEW_RELIC.md](NEW_RELIC.md), sección 6 |
| `develop` y `main` de Infra iguales | Solo difieren en las 4 líneas `image:` | [PIPELINE_CI_CD.md](PIPELINE_CI_CD.md) |

## 4. Observabilidad (New Relic)

| Pilar | Qué se agregó |
| :--- | :--- |
| **Trazas** | Agente Java en App, Runner y AccessManager, con trazas distribuidas entre ellos |
| **Métricas** | Eventos propios `SnippetsListed` (cuántos snippets ve cada usuario) y `RedisStreamStatus` (trabajos encolados y pendientes, cada 60 s). Métricas de VM y contenedores por `newrelic-infra` |
| **Synthetics** | Monitores *ping* de la página y del health check, en dev y prod |
| **Logs** | Logs de App, Runner y AccessManager en New Relic, con `requestId` (MDC) para seguir un request entre servicios. Logs de cambios de estado (alta, edición, borrado, compartir). **Logs de nginx** con el servicio `nginx-logs` (Fluent Bit): muestran los `413`, `502` y `504` que no llegan a App, y llevan el mismo `request_id` |
| **Dashboards** | Dashboards separados de dev y prod, con APM, infraestructura, contenedores y eventos de negocio |
| **Alertas** | Políticas limpias, sin duplicados, y alertas nuevas para servicio caído y VM sin datos. El 8/11: `Redis - trabajos sin procesar` (saturación), `Listas vacías en aumento` (dominio) y `Latencia p95 alta` (percentil) |
| **SLI/SLO** | Service levels `AppIngsis - requests sin error` y `AppIngsis_dev - requests sin error`: 99 % en 28 días |

Todo está explicado en [NEW_RELIC.md](NEW_RELIC.md).

## 5. Tests de carga

- `load-tests/locustfile.py`, con dos tipos de usuario: `HealthUser` (sin token) y `ApiUser` (lectura con token).
- Guía nueva: [LOCUST.md](LOCUST.md), que explica qué hace, cómo correrlo, qué mirar y qué alerta se dispara.

## 6. Documentación nueva o actualizada

| Archivo | Estado |
| :--- | :--- |
| [SEGURIDAD.md](SEGURIDAD.md) | Nuevo |
| [NEW_RELIC.md](NEW_RELIC.md) | Nuevo y ampliado (limitaciones, SLO, comparación con la clase) |
| [LOCUST.md](LOCUST.md) | Nuevo |
| [BASE_DE_DATOS.md](BASE_DE_DATOS.md) | Nuevo: tablas, columnas y cómo interactúan |
| Este archivo | Nuevo |
| `RUTAS_REST.md`, `CASOS_DE_USO_RECORRIDO.md`, `USO_DE_BUCKETS.md`, `HTTPS_NGINX_CORS_NEW.md`, `ARQUITECTURA_NEW.md`, `FLUJO_Y_COMPARATIVA_ARQUITECTURA_NEW.md`, `PIPELINE_CI_CD.md`, `AUTH0.md`, `TROUBLESHOOTING2_NEW.md` y `README.md` (estos dos en la raíz) | Actualizados a lo que hace el sistema hoy |

## 7. Decisiones tomadas

| Decisión | Por qué |
| :--- | :--- |
| **No rotar** el `clientSecret` de Auth0 ni la license key de New Relic | Es un TP con cuentas de prueba. Siguen en el historial de Git: riesgo aceptado |
| No prender ni apagar la VM automáticamente desde las Actions | Más contras que ventajas: credenciales de la nube en GitHub, demoras y riesgo de dejarla prendida |
| `Excessive response time` en 0,3 s | Para que se dispare rápido en la demo. Después conviene subirlo a unos 2 s |
| Logs solo de nginx, no de bases, Redis, UI ni asset-service | nginx es lo único cuyas fallas no se ven en los logs de App y Runner. Sumar el resto es agregar su nombre en `fluent-bit.conf` |
| Sin scopes en el token | Lo que importa es el permiso por snippet, que un scope no expresa |
| Token en `localStorage` | Con `memory`, la sesión se pierde al recargar en navegadores que bloquean cookies de terceros |
| No separar los workflows de CI y CD | Dividirlos sumaba más complejidad que beneficio |

## 8. Qué queda por hacer

- Deployar en el orden de la [sección 9](#9-orden-de-deploy) y probar en dev.
- Las alertas de Redis y de listas vacías no tienen datos hasta que esté deployada la nueva versión de App.
- Synthetic del flujo de negocio (crear, leer y borrar un snippet).
- Alerta de *burn rate* del SLO.
- Comprobar en dev que llegan los logs de nginx (paso 7 de la prueba mínima).
- Contraseñas de las bases fuera del stack.

## 9. Orden de deploy

Los cambios dependen unos de otros, así que el orden importa:

| Paso | Qué | Por qué en este orden |
| :--- | :--- | :--- |
| 1 | Infra, commit "license key de New Relic por variable de entorno" | Los servicios nuevos ya no traen la key en `newrelic.yml`. Sin esta variable, el agente no manda datos |
| 2 | App y Runner, **juntos** | App nuevo no acepta el registro del Runner viejo, y el Runner nuevo llama a `/internal`, que solo existe en App nuevo. Entre uno y otro, crear un snippet puede fallar unos minutos |
| 2 | AccessManager (puede ir con el paso 2) | Solo cambian logs y `newrelic.yml`. Necesita el paso 1 |
| 3 | UI | Usa `PATCH` con `content`, que solo existe en App nuevo. Mientras tanto, la UI vieja sigue andando por `/runner/` |
| 4 | Probar en dev | Ver la [prueba mínima](#prueba-mínima-en-dev) |
| 5 | Infra, el resto de los commits (nginx, logs de nginx y docs) | Cierra `/runner/` y `/access/` y suma `nginx-logs`. Si se hace antes del paso 3, la UI vieja no puede crear con código ni editar |

Cada push humano a Infra reinicia los 4 microservicios (pasos 1 y 5). En producción se repite igual: Infra `main`
en vez de `develop`, y PR `develop` → `production` en los servicios.

### Prueba mínima en dev
1. Loguearse. Si todo da `401`, el token no trae `aud = https://api.snippets.com`.
2. Crear un snippet con código, editarlo, compartirlo con otro usuario y abrirlo desde esa cuenta.
3. Con un tercer usuario, abrir la URL del snippet: tiene que dar `403`.
4. Borrarlo.
5. Después del paso 5: `https://<dominio>/runner/api/v1/snippets/x` devuelve la página de la UI, no la API.
6. En New Relic, a los pocos minutos: `SELECT count(*) FROM RedisStreamStatus, SnippetsListed FACET appName SINCE 30 minutes ago`.
7. Logs de nginx: `docker service ps snippetsearcher_nginx-logs` tiene que estar `Running`, y en New Relic
   `SELECT count(*) FROM Log WHERE service = 'nginx' FACET status, domain SINCE 30 minutes ago` tiene que traer filas.
   Si no trae nada, `docker service logs snippetsearcher_nginx-logs` muestra por qué (por ejemplo, un `403` de la
   Log API si la license key es de otra región).

---

## 10. Sin JSONB en las bases (9/11)

Las dos columnas JSONB pasaron a tablas con una fila por valor. Para la UI y la API no cambia nada.

| Antes | Ahora | Repo |
| :--- | :--- | :--- |
| `formatting_rules.config_rules` y `linting_rules.config_rules` (JSONB) en runner-db | `formatting_rule_values` y `linting_rule_values`: una fila por regla, con `rule_value` y `value_type` (`boolean`, `number`, `string`) | Runner: `FormattingRule`, `LintingRule`, `RuleValue` |
| `test.config_rules` (JSONB) en appdb | `test_environment`: una fila por variable de entorno | App: `Test` |

Las dos tablas nuevas tienen clave foránea con `ON DELETE CASCADE`. Los inputs y outputs de los tests siguen como
`text[]`. Detalle de tablas y columnas en [BASE_DE_DATOS.md](BASE_DE_DATOS.md).

**Para deployarlo** (en cada ambiente: primero dev, después prod), hay que migrar los datos que ya existen:

| Paso | Qué |
| :--- | :--- |
| 1 | En la VM: correr `002-app-test-environment.sql` en appdb y `003-runner-reglas.sql` en runner-db. Crean las tablas nuevas y copian los datos. El código viejo las ignora |
| 2 | Pushear (o mergear a `production`) App y Runner, como cualquier cambio |
| 3 | Cuando terminen sus deploys, correr de nuevo `002` y `003`: copian lo que se haya cambiado entre el paso 1 y el deploy |
| 4 | Probar: la pantalla de reglas muestra las reglas del usuario, y un test con variables de entorno las conserva y pasa |
| 5 | Recién ahí, `004-app-borrar-config-rules.sql` en appdb y `005-runner-borrar-config-rules.sql` en runner-db: borran las columnas JSONB |

Los comandos exactos están en [BASE_DE_DATOS.md](BASE_DE_DATOS.md), sección 8. Si se saltea el paso 1, el código
nuevo arranca con las tablas vacías: los usuarios ven sus reglas vacías hasta que se corra `003`.

---

## 11. Limpieza de código muerto (13/11)

Se revisaron los 5 repos buscando clases, funciones, archivos y configuración que nadie usa. Todo lo borrado se
confirmó sin referencias, y después de borrar pasan lint, detekt, tests y la cobertura mínima (80 %) en cada servicio.
No cambia el comportamiento visible.

| Repo | Qué se borró | Por qué estaba muerto |
| :--- | :--- | :--- |
| App | 8 DTOs (`SnippetDownload`, `TaskRequest`, `ValidationRequest`, `ValidationResponse`, etc.) y el DTO `ExecutionEvent` (queda solo el enum `ExecutionEventType`) | Nadie los usaba |
| App | `TestRepository.findTestIdsBySnippetId` | Consulta que nadie llamaba |
| Runner | `SnippetCacheService` y su uso en `ExecutionService` | Guardaba cada salida de ejecución en Redis (`snippet:{id}:{version}`), sin TTL, y nadie la leía |
| Runner | `MapJsonConverter` | Convertía los JSONB de las reglas; sin JSONB ya no se usa |
| Runner | `TestPlugin` | Plugin de prueba que solo imprimía un cartel en consola |
| Runner | `AppClient.sendLine`, `defaultHeaders` y su `logger`, y el DTO `ExecutionEvent` | `sendLine` estaba vacía (su código, comentado); el resto solo lo usaba ese código |
| Runner | `ExecutionInputProvider.hasPendingInputs` | Nadie la llamaba |
| UI | `runnerService.ts`, `FakeRunnerService` y `RUNNER_URL` | La UI ya no habla con el Runner: todo pasa por App |
| UI | `authService.ts` y `authContext.tsx` | Login viejo con grant `password`; hoy se usa Auth0 |
| UI | Hooks `useSendInput`, `useGetExecutionStatus`, `useRemoveTestCase`, y `sendInput` / `removeTestCase` de la API | Nadie los llamaba |
| UI | `App.test.tsx`, `GetSnippetResponse`, `ExecutionRequest`, `ExecutionResponse`, `InputRequest`, `paginationParams`, `PaginatedUsers` | Archivo vacío y tipos sin uso |
| UI, Infra | `VITE_RUNNER_URL` (Dockerfile, Cypress, `docker-stack.yml`, `docker-compose.yml`) y `APP_HOST` / `RUNNER_*` de la UI en `docker-compose.yml` | Ningún código las lee |
| Infra | `.github/workflows/update_service.yml` | Workflow del esquema "dispatch": nadie lo dispara desde noviembre |

Los tests que solo probaban código borrado se borraron con él.

**No se borró, a propósito:**
- El modo de prueba de la UI (`USE_MOCK_SERVICES` y `FakeSnippetOperations`): es una herramienta de desarrollo.
- Los documentos viejos (los que tienen versión `_NEW`) y la carpeta `Deprecated`: son historia de la documentación.
- `vm/snippetsearcher-lifecycle.*`: quedó como opcional (ver `VM_LIMPIA.md`).
