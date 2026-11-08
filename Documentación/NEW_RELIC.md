# New Relic: qué se monitorea, cómo y dónde verlo

Cuenta: `7325136`. Todo lo de este documento se consulta en **one.newrelic.com**. Las consultas NRQL se corren en
**Query your data** (barra inferior), con **Chart type → Table** para leerlas mejor.

## Índice
- [1. Vista general y flujo](#1-vista-general-y-flujo)
- [2. Implementación en el código](#2-implementación-en-el-código)
- [3. Trazas](#3-trazas)
- [4. Métricas](#4-métricas)
- [5. Synthetics](#5-synthetics)
- [6. Logs](#6-logs)
- [7. Dashboards](#7-dashboards)
- [8. Seguir un request por su id](#8-seguir-un-request-por-su-id)
- [9. Alertas: qué hace cada una y cómo mostrarla](#9-alertas-qué-hace-cada-una-y-cómo-mostrarla)
- [10. Alertas desactivadas o borradas y qué las reemplaza](#10-alertas-desactivadas-o-borradas-y-qué-las-reemplaza)
- [11. Puntos de falla y cómo se detectan](#11-puntos-de-falla-y-cómo-se-detectan)
- [12. Tests de carga](#12-tests-de-carga)
- [13. Limitaciones y pendientes](#13-limitaciones-y-pendientes)
- [14. SLI, SLO y error budget](#14-sli-slo-y-error-budget)
- [15. Qué plantea la clase y cómo se cumple](#15-qué-plantea-la-clase-y-cómo-se-cumple)

---

## 1. Vista general y flujo

```
                         ┌──────────────── VM (dev o prod) ────────────────┐
 Usuario ─► nginx ─► UI   │                                                 │
              │           │  App ──► Runner ──► asset-service ──► Azurite   │
              └─► /api ──►│   │  └─► AccessManager                          │
                          │   └─► appdb, Redis                              │
                          │                                                 │
                          │  agente Java (APM) dentro de App, Runner y AM  ─┼──► trazas, métricas APM, logs
                          │  contenedor newrelic-infra                     ─┼──► métricas de VM y contenedores
                          └─────────────────────────────────────────────────┘
 Synthetics (desde afuera) ──► página y /api/actuator/health ───────────────────► chequeos
                                                                                   │
                     New Relic ◄───────────────────────────────────────────────────┘
                        ├─ Dashboards: muestran todo junto
                        └─ Alertas ─► Workflows ─► mail
```

| Fuente | Qué manda | Tipo de dato en NRQL |
| :--- | :--- | :--- |
| Agente Java (App, Runner, AccessManager) | Requests, tiempos, errores, trazas y logs | `Transaction`, `TransactionError`, `Span`, `Log`, `Metric` |
| Contenedor `newrelic-infra` | CPU, memoria y disco de la VM, y estado de cada contenedor | `SystemSample`, `ContainerSample` |
| Synthetics | Resultado de cada chequeo desde afuera | `SyntheticCheck` |
| Alertas | Apertura y cierre de incidentes | `NrAiIncident` |

**Cómo se separan los ambientes:**

| | Dev | Prod |
| :--- | :--- | :--- |
| Nombre de app en APM | `AppIngsis_dev`, `RunnerIngsis_dev`, `AccessManagerIngsis_dev` | `AppIngsis`, `runnerIngsis`, `AccessManagerIngsis` |
| Host (infra) | `environment = 'develop'` | `environment = 'production'` |
| Monitores | `Snippet Searcher - Develop`, `Snippet Searcher - Develop health` | `Snippet Searcher - Prod`, `Snippet Searcher - Production Health` |
| Dashboard | `Develop` | `Production` |

El Runner de producción reporta como `runnerIngsis`, con minúscula: así lo define la variable `NEW_RELIC_APP_NAME_RUNNER`
del environment `production`. Las consultas tienen que usar ese nombre exacto.

---

## 2. Implementación en el código

### Agente Java (APM, trazas y logs)
En **App, Runner y AccessManager**:

| Archivo | Qué hace |
| :--- | :--- |
| `Dockerfile` | Descarga `newrelic-agent-8.25.1.jar` y arranca la app con `java -javaagent:/usr/local/newrelic/newrelic.jar -jar ...` |
| `newrelic/newrelic.yml` | Configuración del agente: `distributed_tracing`, `span_events`, `transaction_tracer`, `error_collector` y `application_logging.forwarding` activados. `forwarding.context_data` manda el MDC (`requestId`) como atributo de cada log. **No tiene la license key** |
| `build.gradle` | `com.newrelic.agent.java:newrelic-api`, para usar `NewRelic.addCustomParameter` desde el código |
| `filter/RequestIdFilter.kt` | Toma el header `X-Request-Id` (o genera uno), lo guarda como atributo `request_id` de la transacción y lo devuelve en la respuesta (ver [sección 8](#8-seguir-un-request-por-su-id)) |

El nombre de cada app no sale de `newrelic.yml` sino de la variable `NEW_RELIC_APP_NAME`, que `docker-stack.yml` arma
con las variables del environment de GitHub. Detalle en [TROUBLESHOOTING2_NEW.md](../TROUBLESHOOTING2_NEW.md).

La license key tampoco está en el repo: el agente la toma de la variable `NEW_RELIC_LICENSE_KEY`, que
`docker-stack.yml` carga desde el secret del mismo nombre (lo pasa `deploy.yml`).

### Agente de infraestructura (VM y contenedores)
En `SnippetSearcher-Infrastructure/.github/workflows/deploy.yml`, paso **Ensure New Relic infrastructure agent**:
levanta el contenedor `newrelic-infra` (imagen `newrelic/infrastructure:2.0.1`) con `docker run`. No se instala nada en
la VM. La clave sale del secret `NEW_RELIC_LICENSE_KEY` y el host se identifica con `NRIA_DISPLAY_NAME`
(`snippet26dev` / `snippet26prod`) y `environment`. Detalle en [PIPELINE_CI_CD.md](PIPELINE_CI_CD.md).

### Chequeo de salud del backend
En **App**:

| Archivo | Qué hace |
| :--- | :--- |
| `build.gradle` | `spring-boot-starter-actuator` |
| `application.yml` | Publica solo `health` en `/api/actuator/health`, sin detalles |
| `health/DependencyHealthIndicators.kt` | Suma al chequeo el `/actuator/health` de Runner y de AccessManager, por la red interna |
| `config/RestTemplateConfig.kt` | `healthRestTemplate`, con timeouts de 2 s (conexión) y 3 s (respuesta) |

AccessManager tiene `spring-boot-starter-actuator` para que App pueda consultarlo. Runner ya lo tenía.
La respuesta es `{"status":"UP"}` (200) o `{"status":"DOWN"}` (503). Incluye la base de App, Redis, Runner y
AccessManager.

### Logs y eventos de negocio
En **App**:

| Archivo | Qué hace |
| :--- | :--- |
| `controller/SnippetController.kt` | Loguea cada cambio de estado con quién lo hizo: `snippet created`, `snippet deleted`, `snippet shared`, `snippet unshared`, `snippet content updated`, y `snippets listed` con la cantidad |
| `observability/BusinessEvents.kt` | Manda a New Relic los eventos `SnippetsListed` (cuántos snippets vio cada usuario) y `RedisStreamStatus` |
| `observability/StreamSaturationReporter.kt` | Cada minuto mide el largo de los streams de Redis y los mensajes sin confirmar de cada grupo (saturación) |

En los tres servicios, `logback-spring.xml` imprime el `requestId` del MDC en cada línea.

---

## 3. Trazas

Una traza es el recorrido de un request por los servicios, con cuánto tardó cada paso (*span*). Las genera solo el
agente: no hay que crear nada.

**Dónde verlas:** **Traces**. La pestaña **Trace groups** agrupa por endpoint. Abrir una traza muestra sus pasos.

| Qué ver | NRQL |
| :--- | :--- |
| Trazas por endpoint | `SELECT count(*), percentile(duration.ms, 95) FROM Span WHERE nr.entryPoint IS TRUE FACET name, entity.name SINCE 1 day ago LIMIT 30` |
| Pasos de una traza | `SELECT timestamp, entity.name, name, duration.ms FROM Span WHERE trace.id = 'TRACE_ID' ORDER BY timestamp ASC` |
| Trazas con error | `SELECT count(*) FROM Span WHERE error IS TRUE FACET entity.name, name SINCE 1 day ago` |

**Qué hay hoy** (semana del 30/10 al 6/11): unas 4100 trazas en 26 grupos. Casi todas son `GET /api/v1/permissions`
de AccessManager dev, un proceso automático. El resto son los endpoints de snippets, tests, ejecuciones y usuarios.

**Qué no se ve:** el tramo del navegador (no hay agente de Browser), el procesamiento de Redis Streams (formateo y
linteo automáticos) y el interior de `asset-service`, que solo aparece como llamada saliente de Runner.

---

## 4. Métricas

### APM (por aplicación)
**Dónde:** **APM & Services** → elegir la app. Muestra tiempo de respuesta, throughput y tasa de error.

| Qué ver | NRQL |
| :--- | :--- |
| Requests por minuto | `SELECT rate(count(*), 1 minute) FROM Transaction WHERE appName = 'AppIngsis' TIMESERIES` |
| Tiempos p50/p95/p99 | `SELECT percentile(duration, 50, 95, 99) FROM Transaction WHERE appName = 'AppIngsis' TIMESERIES` |
| Errores por clase | `SELECT count(*) FROM TransactionError FACET appName, error.class SINCE 1 week ago` |
| Endpoints más lentos | `SELECT average(duration) FROM Transaction WHERE appName = 'AppIngsis' FACET name SINCE 1 day ago` |

### VM
**Dónde:** **Infrastructure → Hosts**, o filtrar por `environment`.

| Qué ver | NRQL |
| :--- | :--- |
| Estado actual | `SELECT latest(cpuPercent), latest(memoryUsedPercent), latest(diskUsedPercent) FROM SystemSample FACET hostname, environment SINCE 10 minutes ago` |
| Evolución | `SELECT average(cpuPercent), average(memoryUsedPercent), max(diskUsedPercent) FROM SystemSample WHERE environment = 'production' TIMESERIES AUTO` |

### Servicios (contenedores)

| Qué ver | NRQL |
| :--- | :--- |
| Réplicas corriendo | `SELECT uniqueCount(containerId) FROM ContainerSample WHERE environment = 'production' AND state = 'running' FACET `label.com.docker.swarm.service.name` SINCE 2 minutes ago LIMIT 20` |
| CPU por servicio | `SELECT average(cpuPercent) FROM ContainerSample WHERE environment = 'production' AND state = 'running' FACET `label.com.docker.swarm.service.name` TIMESERIES AUTO` |
| Memoria por servicio (MB) | `SELECT average(memoryUsageBytes) / 1000000 FROM ContainerSample WHERE environment = 'production' AND state = 'running' FACET `label.com.docker.swarm.service.name` TIMESERIES AUTO` |

Valores esperados de réplicas: **2** en App, Runner, AccessManager y UI; **1** en los otros 8 servicios.

---

### Saturación: Redis Streams
La cuarta señal dorada. `RedisStreamStatus` llega cada minuto desde App:

| Stream | Grupo | `length` | `pending` |
| :--- | :--- | :--- | :--- |
| `snippet-jobs` | `runner_group` | Trabajos de formateo y linteo encolados | Trabajos que el Runner tomó y no terminó |
| `snippet-job-results` | `app_group` | Resultados encolados | Resultados que App no procesó |

| Qué ver | NRQL |
| :--- | :--- |
| Estado actual | `SELECT latest(length), latest(pending) FROM RedisStreamStatus FACET stream, entity.name SINCE 5 minutes ago` |
| Evolución del lag | `SELECT max(pending) FROM RedisStreamStatus FACET stream TIMESERIES AUTO` |

`pending` alto y creciendo significa que los consumidores no dan abasto o que una réplica murió con mensajes tomados.
`length` está acotado a unos 10000 mensajes (`MAXLEN`), así que es más útil mirar `pending`.

### Métrica de negocio: snippets listados
`SnippetsListed` registra cuántos snippets vio un usuario cada vez que pidió su lista. Sirve para el caso que
ninguna métrica técnica ve: la API responde `200`, pero con la lista vacía.

| Qué ver | NRQL |
| :--- | :--- |
| Usuarios que hoy ven 0 snippets pero ayer veían alguno | `SELECT latest(count) AS hoy, earliest(count) AS antes FROM SnippetsListed FACET userId SINCE 1 day ago LIMIT 50` |
| Proporción de listas vacías | `SELECT percentage(count(*), WHERE count = 0) FROM SnippetsListed TIMESERIES AUTO` |

## 5. Synthetics

**Dónde:** **Synthetic Monitoring → Monitors**. Los cuatro son de tipo Ping, cada 5 minutos, desde 2 ubicaciones.

| Monitor | URL | Qué confirma |
| :--- | :--- | :--- |
| `Snippet Searcher - Prod` | `https://snippet26prod.duckdns.org` | La página carga: VM, DNS, nginx y UI |
| `Snippet Searcher - Production Health` | `https://snippet26prod.duckdns.org/api/actuator/health` | El backend funciona: App, su base, Redis, Runner y AccessManager |
| `Snippet Searcher - Develop` | `https://snippet26dev.duckdns.org` | Lo mismo en dev |
| `Snippet Searcher - Develop health` | `https://snippet26dev.duckdns.org/api/actuator/health` | Lo mismo en dev |

Los de health validan que la respuesta contenga `"status":"UP"`.

| Qué ver | NRQL |
| :--- | :--- |
| Disponibilidad | `SELECT percentage(count(*), WHERE result = 'SUCCESS') FROM SyntheticCheck FACET monitorName SINCE 1 day ago` |
| Fallas recientes | `SELECT timestamp, monitorName, locationLabel, error FROM SyntheticCheck WHERE result = 'FAILED' SINCE 1 day ago` |
| Tiempo de respuesta | `SELECT average(duration) FROM SyntheticCheck FACET monitorName TIMESERIES AUTO` |

---

## 6. Logs

**Dónde:** **Logs**. Se filtra por `entity.name` (nombre de la app), `level` y los atributos del contexto.

Llegan los logs de **App, Runner y AccessManager**, en los dos ambientes, enviados por el agente Java
(`application_logging.forwarding`). No llegan los de nginx, UI, bases, Redis ni `asset-service`.

**Contexto aparte del mensaje (MDC):** el `requestId` se carga una vez al entrar el request y viaja como atributo de
cada log (`forwarding.context_data`). El agente le agrega `trace.id` y `span.id`. Así se filtra por campo, sin
buscar texto. El atributo debería llamarse `context.requestId`: confirmalo en el primer log, desplegándolo en **Logs**.

**Qué se loguea** (App): cada cambio de estado con quién lo hizo, en formato `clave=valor`:

| Evento | Ejemplo |
| :--- | :--- |
| Alta | `snippet created snippetId=... owner=auth0|... language=printscript` |
| Edición del código | `snippet content updated snippetId=... by=auth0|...` |
| Borrado | `snippet deleted snippetId=... by=auth0|...` |
| Compartir y quitar acceso | `snippet shared snippetId=... by=... with=...`, `snippet unshared ... from=...` |
| Resultado de listar | `snippets listed user=... count=0 owned=0 shared=0` |

Nunca se loguean tokens ni contraseñas: solo el id del usuario (`sub` de Auth0).

| Qué ver | NRQL |
| :--- | :--- |
| Volumen por servicio y nivel | `SELECT count(*) FROM Log FACET entity.name, level SINCE 1 day ago` |
| Errores recientes | `SELECT timestamp, entity.name, message FROM Log WHERE level = 'ERROR' SINCE 1 day ago` |
| Cambios de estado de hoy | `SELECT timestamp, message FROM Log WHERE message LIKE 'snippet %' SINCE 1 day ago` |
| Todo lo de un request | `SELECT timestamp, entity.name, message FROM Log WHERE context.requestId = 'ID' SINCE 1 day ago` |

Los logs **no** tienen el atributo `appName`: hay que usar `entity.name`.

---

## 7. Dashboards

**Dónde:** **Dashboards**: `Production` y `Develop`, uno por ambiente.

**Página principal** (creada en diciembre de 2025):

| Widget | Muestra |
| :--- | :--- |
| Requests Per Minute (App, AccesManager, Runner) | Tráfico de cada servicio |
| Response time 50-95-99 (App, AccesManager, Runner) | Percentiles de tiempo de respuesta |
| Overall Throughput, ErrorRate, WarnRate | Totales y proporción de errores y warnings |

**Página `Infraestructura`**: réplicas por servicio, CPU y memoria por servicio, estado y evolución de la VM,
disponibilidad y tiempo de respuesta de Synthetics, y alertas disparadas. Sus consultas son las de las secciones 4,
5 y 9 con el ambiente del dashboard (`environment = 'production'` o `'develop'`).

Para ver la consulta de cualquier widget: menú `...` del widget → **View query**.

---

## 8. Seguir un request por su id

### Cómo viaja el id
```
UI ─ X-Request-Id: <uuid> ─► App ─ X-Request-Id ─► Runner
                              └── X-Request-Id ─► AccessManager
```
1. La UI manda un `X-Request-Id` nuevo en cada request.
2. `RequestIdFilter` lo toma (o genera uno si no viene), lo guarda en el atributo `request_id` de la transacción de New
   Relic, escribe el log `Request <id> - <método> <uri>` y lo devuelve en el header de respuesta.
3. App lo reenvía a Runner y a AccessManager, que hacen lo mismo. Las tres transacciones quedan con el mismo
   `request_id`.

### Dónde obtener el id
En el navegador: **DevTools → Network**, elegir el request y buscar el header de respuesta **`X-Request-Id`**.

### Consultas
| Qué ver | NRQL |
| :--- | :--- |
| Transacciones de ese request, en todos los servicios | `SELECT * FROM Transaction WHERE request_id = 'ID' SINCE 1 day ago` |
| Logs de ese request | `SELECT timestamp, entity.name, level, message FROM Log WHERE message LIKE '%ID%' SINCE 1 day ago` |
| Traza de ese request | `SELECT traceId FROM Transaction WHERE request_id = 'ID' SINCE 1 day ago`, y con el resultado: `SELECT timestamp, entity.name, name, duration.ms FROM Span WHERE trace.id = 'TRACE_ID' ORDER BY timestamp ASC` |
| Logs dentro de esa traza | `SELECT timestamp, entity.name, message FROM Log WHERE trace.id = 'TRACE_ID'` |

La búsqueda de logs por `message` encuentra la línea `Request <id> ...` de cada servicio. La de `trace.id` trae todos
los logs escritos durante ese request: el agente le agrega `trace.id` a los logs que se escriben dentro de una
transacción.

**Corregido:** Runner y AccessManager usaban otra clave del MDC en `logback-spring.xml` (`request_id` en lugar de
`requestId`), y en sus logs ese campo salía vacío. Ahora los tres servicios usan `requestId`. Además, el MDC viaja
como atributo de los logs (ver [sección 6](#6-logs)).

---

## 9. Alertas: qué hace cada una y cómo mostrarla

**Dónde:** **Alerts → Alert Conditions**. Los incidentes abiertos están en **Alerts → Issues & Activity**, y los avisos
por mail los mandan los **Workflows**, uno por policy.

Para mostrar una alerta: provocar la falla **en dev**, esperar el tiempo de la condición más unos minutos, y verla en
**Issues & Activity** y en el mail. Después revertir y confirmar que el incidente se cierra solo. Los comandos de
`docker` se corren por SSH en la VM de dev.

### Synthetics (policy `Synthetics`)

| Alerta | NRQL | Dispara si | Cómo mostrarla en dev |
| :--- | :--- | :--- | :--- |
| `Production caída` / `Develop caída` | `SELECT filter(count(*), WHERE result = 'FAILED') FROM SyntheticCheck WHERE monitorName = 'Snippet Searcher - Prod'` | Fallan las 2 ubicaciones durante 5 min | `docker service scale snippetsearcher_reverse-proxy=0`; volver con `=1` |
| `Production backend caído` / `Develop backend caído` | Igual, con `monitorName = 'Snippet Searcher - Production Health'` (o el de dev) | El backend responde `DOWN` o no responde, 5 min | `docker service scale snippetsearcher_snippetsearcher-accessmanager=0`; volver con `=2` |

### Infraestructura (policy `Infraestructura`)

| Alerta | NRQL | Dispara si | Cómo mostrarla en dev |
| :--- | :--- | :--- | :--- |
| `VM - CPU alta` | `SELECT average(cpuPercent) FROM SystemSample FACET hostname` | > 85% durante 10 min | `timeout 720 sh -c 'yes > /dev/null & yes > /dev/null & wait'` (ocupa las 2 CPUs 12 min y termina solo) |
| `VM - Memoria Alta` | `SELECT average(memoryUsedPercent) FROM SystemSample FACET hostname` | > 90% durante 10 min | Bajar el umbral temporalmente al valor actual de la VM y restaurarlo |
| `VM - Disco lleno` | `SELECT max(diskUsedPercent) FROM SystemSample FACET hostname` | > 80% durante 5 min | Igual: bajar el umbral temporalmente. Llenar el disco puede romper la VM |
| `VM - Sin datos` | `SELECT count(*) FROM SystemSample FACET hostname` | Sin datos durante 5 min (*Lost signal*) | `docker stop newrelic-infra`; volver con `docker start newrelic-infra` |
| `Servicio sin contenedores (servicio caído)` | `SELECT uniqueCount(containerId) FROM ContainerSample WHERE state = 'running' AND `label.com.docker.swarm.service.name` != 'snippetsearcher_certbot' FACET hostname, `label.com.docker.swarm.service.name`` | Un servicio sin contenedores 5 min | `docker service scale snippetsearcher_asset-service=0`; volver con `=1` |
| `Servicio con réplica caída` | `SELECT uniqueCount(containerId) FROM ContainerSample WHERE state = 'running' AND `label.com.docker.swarm.service.name` IN (App, Runner, AccessManager, UI) FACET hostname, `label.com.docker.swarm.service.name`` | Menos de 2 réplicas durante 15 min | `docker service scale snippetsearcher_snippetsearcher-app=1`; volver con `=2` |

### Aplicación (policies `Error Rate` y `Golden Signals`)

| Alerta | NRQL | Dispara si | Cómo mostrarla en dev |
| :--- | :--- | :--- | :--- |
| `Error overflow` | `SELECT count(*) FROM Log WHERE level = 'ERROR' FACET entity.name` | 3 o más logs de error en 1 min | `docker service scale snippetsearcher_redis=0` durante unos minutos: App y Runner registran errores de conexión. Volver con `=1`. Corta las ejecuciones y el linteo mientras dura |
| `Excessive response time` | `SELECT average(duration) FROM Transaction WHERE appName IN ('AppIngsis', 'AppIngsis_dev') FACET appName` | Promedio > 0,3 s durante 5 min | Un test de carga ([sección 12](#12-tests-de-carga)). El umbral bajo es a propósito, para la demo |
| `High Application Error percentage` | `FROM Metric SELECT count(apm.service.error.count) / count(apm.service.transaction.duration) ... FACET entity.guid, appName` | Se aparta de lo habitual (baseline) | No es reproducible a pedido: depende de lo que New Relic aprendió del tráfico |
| `High Application Response Time` | `SELECT average(newrelic.goldenmetrics.apm.application.responseTimeMs) FROM Metric FACET entity.guid, appName` | Se aparta de lo habitual (baseline) | Igual que la anterior |

El disparador de `Error overflow` no está probado: depende de que la falta de Redis genere logs `ERROR`.

### Alertas recomendadas para crear
Cubren lo que la clase marca como faltante. Se crean en **Alerts → Alert Conditions → Add a condition → NRQL**:

| Nombre sugerido | NRQL | Critical | Policy |
| :--- | :--- | :--- | :--- |
| `Redis - trabajos sin procesar` | `SELECT max(pending) FROM RedisStreamStatus FACET stream` | `above 50` durante 10 min | `Infraestructura` |
| `Listas vacías en aumento` | `SELECT percentage(count(*), WHERE count = 0) FROM SnippetsListed` | `above 50` durante 15 min | `Error Rate` |
| `Latencia p95 alta` (reemplaza a `Excessive response time`, que usa promedio) | `SELECT percentile(duration, 95) FROM Transaction WHERE appName IN ('AppIngsis', 'AppIngsis_dev') FACET appName` | `above 0.3` durante 5 min (demo) o `above 2` | `Error Rate` |

Para la latencia, la clase recomienda percentiles: el promedio esconde a los pocos usuarios que esperan mucho.

### Ver las alertas disparadas
`SELECT count(*) FROM NrAiIncident WHERE event = 'open' FACET conditionName, entity.name SINCE 1 day ago`

---

## 10. Alertas desactivadas o borradas y qué las reemplaza

| Alerta | Estado | Qué intentaba | Por qué no servía | Lo cubre ahora |
| :--- | :--- | :--- | :--- | :--- |
| `AccessManagerIngsis` | Borrada (con su policy) | AccessManager caído | Buscaba `appName` en los logs, que no existe: nunca disparaba | `Servicio sin contenedores`, `Servicio con réplica caída`, `backend caído` |
| `ErrorPopsUp` | Borrada (con su policy) | App caída | Mismo problema | Las mismas |
| `Error, something's wrong` | Borrada (con su policy) | Runner caído | Nombre de app mal escrito en dev, y con poco tráfico daba falsas alarmas | Las mismas |
| `High CPU` | Borrada | CPU alta | Duplicaba `VM - CPU alta` y antes del agente no tenía datos | `VM - CPU alta` |
| `Low Application Throughput` | Desactivada | Caída o baja de tráfico | Con tan poco tráfico daba falsas alarmas | La caída: Synthetics y alertas de contenedores. La baja de tráfico no se cubre |
| Policy `Low Traffic` | Borrada (con su workflow) | — | No tenía condiciones | — |

---

## 11. Puntos de falla y cómo se detectan

| Punto de falla | Alertas que avisan | Dónde investigar |
| :--- | :--- | :--- |
| VM apagada o sin red | `caída`, `backend caído`, `VM - Sin datos` | Azure; **Infrastructure → Hosts** |
| VM saturada (CPU, memoria, disco) | `VM - CPU alta`, `VM - Memoria Alta`, `VM - Disco lleno` | Dashboard `Infraestructura` |
| nginx caído | `caída`, `backend caído`, `Servicio sin contenedores` | `ContainerSample` del servicio `reverse-proxy` |
| Certificado vencido | `caída` y `backend caído`, **solo si** los monitores tienen activado **Verify SSL** (no está verificado) | `SyntheticCheck` → `error` |
| UI caída | `Servicio sin contenedores` | Monitor `Snippet Searcher - Prod` |
| App caída o colgada | `backend caído`, `Servicio sin contenedores`, `Servicio con réplica caída` | APM de App, trazas |
| Base de App caída | `backend caído`, `Servicio sin contenedores` | Logs de App |
| Redis caído | `backend caído`, `Servicio sin contenedores`, `Error overflow` | Logs de App y Runner |
| Runner o AccessManager caídos o colgados | `backend caído`, `Servicio sin contenedores`, `Servicio con réplica caída` | APM y logs del servicio |
| Bases de Runner o AccessManager | `Servicio sin contenedores` (caída). Si responden mal, `backend caído`, porque el health de cada servicio revisa su base | Logs del servicio |
| `asset-service` o Azurite caídos | `Servicio sin contenedores` | Trazas de Runner: llamadas salientes con error |
| Una réplica de un servicio caída | `Servicio con réplica caída` | `ContainerSample` |
| Lentitud | `Excessive response time`, `High Application Response Time` | Trazas: qué paso tarda |
| Errores en la aplicación | `Error overflow`, `High Application Error percentage` | **Triage Inbox**, `TransactionError`, logs |
| Redis Streams saturados (consumidor caído o lento) | `Redis - trabajos sin procesar` (a crear) | `RedisStreamStatus` |
| La API responde `200`, pero un usuario ve 0 snippets | `Listas vacías en aumento` (a crear) | `SnippetsListed` y logs `snippets listed` |
| Request rechazado por nginx (por ejemplo, un snippet demasiado grande: `413`) | **Ninguna** | No llega a New Relic (ver sección 13) |

---

## 12. Tests de carga

Están en `load-tests/locustfile.py` del repo de Infra, escritos para [Locust](https://locust.io). Qué hace, cómo
correrlo, qué mirar y qué alertas puede activar: [LOCUST.md](LOCUST.md).

| Usuario | Qué hace | Necesita login |
| :--- | :--- | :--- |
| `HealthUser` | Pide `/api/actuator/health` (pasa por nginx, App, Runner y AccessManager) | No |
| `ApiUser` | Lista los snippets del usuario y, si se indica, lee uno. Solo lectura | Sí: un token propio |

Cada request lleva un `X-Request-Id` que empieza con `locust-`:
`SELECT count(*), average(duration) FROM Transaction WHERE request_id LIKE 'locust-%' FACET appName SINCE 1 hour ago`

Qué mirar mientras corren: **APM & Services** de App (tiempo de respuesta y throughput), **Traces**, la página
`Infraestructura` del dashboard (CPU y memoria), y si se dispara `Excessive response time`.

**Correrlos solo contra dev.** La VM tiene 2 CPUs y la carga afecta a todos los servicios.

---

## 13. Limitaciones y pendientes

- **Logs de nginx, UI, bases, Redis y `asset-service`:** no llegan. El contenedor `newrelic-infra` no reenvía logs;
  haría falta un recolector como Fluent Bit. Sin los de nginx no se ven los `413` ni los `502`.
- **Synthetic del flujo de negocio:** la clase sugiere uno que cree, lea y borre un snippet. Necesita un token:
  una aplicación *Machine to Machine* en Auth0 con acceso a `https://api.snippets.com`, sus credenciales como
  *Secure credentials* de New Relic, y un monitor *Scripted API* que pida el token y haga las tres llamadas. No está
  hecho. Hoy lo más cercano es el monitor `health`, que prueba App, su base, Redis, Runner y AccessManager.
- **Alertas recomendadas:** las de la [sección 9](#9-alertas-qué-hace-cada-una-y-cómo-mostrarla) (saturación, listas
  vacías, latencia por percentil) hay que crearlas en New Relic.
- **SLO:** hay que crearlo en New Relic (ver [sección 14](#14-sli-slo-y-error-budget)).
- **Baja de tráfico sin caída:** no se detecta.
- **Muting rules:** no hay. Cuando se apaga una VM, se disparan varias alertas a la vez.
- **`Excessive response time` en 0,3 s:** a propósito para la demo; después conviene subirlo a unos 2 s.
- **License key:** ya no está en el código, pero quedó en el historial de Git. **Decisión: no se rota**, porque es
  un TP y la cuenta es de prueba. Es un riesgo aceptado (ver [SEGURIDAD.md](SEGURIDAD.md), sección 5).
- **`VM - Sin datos`:** falta comprobar que dispara con *Lost signal* (ver sección 9).

---

## 14. SLI, SLO y error budget

| Término | Para el Snippet Searcher |
| :--- | :--- |
| **SLI** (qué se mide) | Porcentaje de requests a App que responden sin error |
| **SLO** (objetivo) | 99 % en los últimos 28 días |
| **Error budget** (cuánto se puede fallar) | 1 % de los requests. En tiempo, equivale a unas 6 h 43 min en 28 días |

Se mide **por requests** y no por tiempo: un minuto con la VM apagada y sin usuarios no consume presupuesto, pero
un error mientras alguien usa la app sí.

**Cómo crearlo en New Relic** (uno por ambiente):

1. Andá a **APM & Services**, abrí `AppIngsis` y entrá a **Service levels → Add a service level**.
2. Elegí **Success** (requests sin error). Si pide las consultas a mano:
   - Valid events: `FROM Transaction WHERE appName = 'AppIngsis'`
   - Good events: `FROM Transaction WHERE appName = 'AppIngsis' AND error IS false`
3. Objetivo: `99` %, período: `28 days`.
4. Repetí con `AppIngsis_dev`.

Para un SLI de latencia, en el paso 2 elegí **Latency** con un umbral (por ejemplo, 1 s): cuenta como bueno el request
que respondió bien y a tiempo.

**Para qué sirve:** si queda presupuesto, se puede deployar y experimentar. Si se gastó, se frenan los cambios y se
prioriza la estabilidad. Una alerta útil es la de *burn rate*: avisa cuando el presupuesto se está gastando más rápido
de lo normal. New Relic la ofrece al crear el service level.

---

## 15. Qué plantea la clase y cómo se cumple

| Concepto | Estado | Cómo |
| :--- | :--- | :--- |
| Logs centralizados | ✅ | New Relic, para App, Runner y AccessManager |
| Contexto aparte del mensaje (MDC) y `requestId` entre servicios | ✅ | `RequestIdFilter`, `logback-spring.xml` y `context_data` |
| Loguear cambios de estado, quién los hizo y resultados | ✅ | Logs de alta, edición, borrado, compartir y `snippets listed` |
| Nunca loguear secretos | ✅ | Solo el `sub` del usuario |
| Logs de todos los componentes | ⚠️ | Faltan nginx, asset-service, bases y Redis |
| Métricas clásicas: tráfico, duración, CPU, memoria, uptime | ✅ | APM, agente de infraestructura y Synthetics |
| Cuatro señales: latencia, tráfico, errores | ✅ | APM y dashboards |
| Cuatro señales: saturación | ✅ | `RedisStreamStatus`. Falta crear su alerta |
| Percentiles para la latencia | ⚠️ | Dashboards con p50/p95/p99. La alerta de latencia usa promedio: hay que crear la de p95 |
| Trazas distribuidas | ✅ | Agente Java en los tres servicios |
| Synthetics | ⚠️ | Página y health del backend. Falta el del flujo de negocio |
| Métrica de dominio («mis snippets desaparecieron») | ✅ | `SnippetsListed`. Falta crear su alerta |
| SLI, SLO y error budget | ⚠️ | Definidos en la sección 14. Hay que crearlos en New Relic |
| Alertas accionables, sin ruido | ⚠️ | La de 0,3 s y las de VM apagada suenan seguido |
