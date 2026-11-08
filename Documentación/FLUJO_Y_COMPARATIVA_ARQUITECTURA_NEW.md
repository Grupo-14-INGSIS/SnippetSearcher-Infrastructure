# COMPARATIVA DE ARQUITECTURAS: FLUJO DE UN SNIPPET

Este documento explica de forma clara, técnica y gráfica cómo operaba el flujo de un snippet en la **arquitectura anterior (vieja)**, cómo funciona en la **arquitectura optimizada (nueva)** incorporando **Nginx como Reverse Proxy** y utilizando **Redis EXCLUSIVAMENTE como Cola de Mensajería (Streams / Message Queue)**, y **por qué la nueva arquitectura es sustancialmente superior**.

---

## 1. El Flujo de un Snippet con la Arquitectura Vieja

En la arquitectura anterior, el frontend (React) actuaba indebidamente como **orquestador de infraestructura** y los microservicios sufrían de **acoplamiento bidireccional y dependencias circulares**.

### Diagrama PlantUML (Arquitectura Vieja)

```plantuml
@startuml Arquitectura_Vieja
skinparam roundcorner 10
skinparam defaultTextAlignment center
skinparam shadowing false
skinparam monochrome true

cloud "Auth0" as auth0
rectangle "Browser / UI\n(Sin Proxy Central)" as ui

rectangle "Runner\n:19082" as runner
rectangle "App\n:19081" as app

database "rules\n(jsonb)" as rules
database "appdb\n(PostgreSQL)" as appdb

rectangle "asset-service" as asset
queue "redis\n(Streams)" as redis
rectangle "AccessManager" as access
database "permissions" as perms

' Conexiones de la UI (expuesta a dos puertos diferentes)
ui -up-> auth0 : Autenticación
ui --> app : 1. Manage user data\n2. Enqueue jobs\n4. Execute snippet\n5. CRUD tests
ui --> runner : 3. CRUD snippet (Puerto :19082)

' Conexiones internas acopladas y circulares
runner <-right-> app : Ciclo bidireccional:\nUpdate job status / Execute
runner -left-> rules : Execute job
app -right-> appdb : Metadata y tests

runner --> asset : CRUD snippet
app --> redis : Enqueue jobs
redis --> runner : Consume jobs

app --> access : HTTP síncrono en cada request
access --> perms : Persiste permisos

@enduml
```

### ¿Qué ocurría paso a paso en la Arquitectura Vieja?

1. **La UI como orquestador (Falta de Reverse Proxy y BFF)**:
   - El cliente web debía conocer y conectarse a **dos puertos distintos directamente** (`:19081` para `App` y `:19082` para `Runner`), exponiendo la topología interna a internet.
   - Para abrir un snippet, la UI disparaba **dos llamadas HTTP desarticuladas en paralelo**:
     - Llamada 1 a `App` para obtener metadata.
     - Llamada 2 a `Runner` para obtener el contenido.
2. **Dependencia Circular entre microservicios**:
   - `App` llamaba a `Runner` para ejecutar snippets y correr tests, pero al crear un snippet, `Runner` llamaba de regreso a `App` (`appClient.registerSnippet`). Esto generaba un ciclo de dependencia peligroso.
3. **Chatty HTTP en Autorización**:
   - En cada petición del usuario, `App` realizaba una llamada HTTP síncrona a `AccessManager`, sumando latencia y creando un punto único de fallo.
4. **El "Teléfono Descompuesto" en Baterías de Tests**:
   - Al ejecutar una batería de tests sobre un snippet, `Runner` no conservaba el asset y volvía a descargarlo desde `AssetService` por HTTP para cada caso de prueba, multiplicando el tráfico innecesariamente.
5. **Trazabilidad Fragmentada en New Relic**:
   - Al dividirse la comunicación desde el browser a distintos puertos, las trazas de New Relic aparecían en árboles desconectados.

---

## 2. El Flujo de un Snippet con la Arquitectura Nueva

La arquitectura del sistema puede analizarse desde dos perspectivas complementarias:
1. **Vista de Despliegue con Nginx (Producción / Swarm)**: Con Nginx como Edge Gateway perimetral, terminación SSL y balanceo a 2 réplicas.
2. **Vista Lógica de Microservicios (Sin Nginx)**: Muestra la interacción directa y contratos entre los componentes de negocio.

---

### A. Vista de Producción (Con Nginx Reverse Proxy / Edge Gateway)

![Arquitectura con Nginx](diagramas/arquitectura_con_nginx.png)

```plantuml
@startuml Arquitectura_Con_Nginx
skinparam roundcorner 10
skinparam defaultTextAlignment center
skinparam shadowing false
skinparam monochrome true
skinparam packageStyle rectangle

actor "Usuario / Browser" as client
cloud "Auth0\n(Identidad / JWT)" as auth0

package "Perímetro / Edge Gateway" {
    rectangle "Nginx Reverse Proxy\n(Puertos :80 / :443 SSL)" as nginx
}

package "Docker Swarm Stack (snippetsearcher)" {
    rectangle "printscript-ui\n(Frontend SPA)\n[2 Réplicas]" as ui
    rectangle "snippetsearcher-app\n(Core / BFF)\n[2 Réplicas]" as app
    rectangle "snippetsearcher-runner\n(Execution Engine)\n[2 Réplicas]" as runner
    rectangle "snippetsearcher-accessmanager\n(Autorización y Roles)\n[2 Réplicas]" as access

    database "appdb\n(PostgreSQL 16)\n[1 Réplica]" as appdb
    database "runner-db\n(PostgreSQL 16)\n[1 Réplica]" as runnerdb
    database "accessmanager-db\n(PostgreSQL 16)\n[1 Réplica]" as accessdb

    queue "Redis\n(Streams / Message Queue)\n[1 Réplica]" as redis
    rectangle "asset-service\n(API Storage)\n[1 Réplica]" as asset
    database "Azurite\n(Azure Blob Emulator)\n[1 Réplica]" as azurite
    rectangle "certbot\n(Renovación SSL Webroot)\n[1 Réplica]" as certbot
}

client -right-> auth0 : 1. Autenticación (JWT)
client --> nginx : 2. HTTPS (Entrada única)

nginx --> ui : / (Archivos estáticos)
nginx --> app : /api/* (API Backend)
nginx ..> certbot : Desafío ACME (/.well-known/acme-challenge/ en :80)

app --> access : Consulta permisos (Tiempo real)
access --> accessdb : Persiste permisos y roles
app --> appdb : Metadata de snippets y tests (compliant boolean)

' Redis Streams bidireccional
app --> redis : 1. Encola en 'snippet-jobs' (lint, format)
redis --> runner : 2. Consumer Group 'runner_group'
runner --> redis : 3. Publica resultado en 'snippet-job-results'
redis --> app : 4. Consumer Group 'app_group'

runner --> runnerdb : Reglas de formateo y linteo
runner --> asset : Lectura y guardado de código fuente
asset --> azurite : Persistencia de blobs

@enduml
```

---

### B. Diagrama de Secuencia: Procesamiento Asíncrono con Redis Streams

```plantuml
@startuml Flujo_Secuencia_Nginx_y_Queue
autonumber
actor "Browser" as browser
participant "Nginx (Proxy)" as nginx
participant "App" as app
participant "AccessManager" as access
database "AppDB (Postgres)" as appdb
queue "Stream 'snippet-jobs'" as jobsQueue
participant "Runner (Consumer)" as runner
participant "AssetService" as asset
queue "Stream 'snippet-job-results'" as resultsQueue

== 1. Consulta de un Snippet (Síncrono vía BFF) ==
browser -> nginx : GET /api/v1/snippets/{id} (+ Bearer JWT)
nginx -> app : Proxy Pass a App :8080

app -> access : GET /permissions?userId={uid}&snippetId={id}
access --> app : Retorna rol ('OWNER' / 'SHARED') en tiempo real

app -> appdb : Consulta metadata (nombre, lenguaje, autor, compliant)
appdb --> app : Metadata

app -> runner : GET /api/v1/snippets/{id} (Solicita código)
runner -> asset : Descarga código desde AssetService
asset --> runner : Código fuente
runner --> app : Retorna código

app --> nginx : SnippetData consolidado { id, name, content, language, compliance }
nginx --> browser : HTTP 200 OK

== 2. Modificación de Reglas y Revalidación Asíncrona (Redis Streams) ==
browser -> nginx : PUT /api/v1/rules {task: linting, applyToSnippets: true}
nginx -> app : Proxy Pass a App

app -> app : Marca snippets propios como 'pending' en Redis Hash ('snippet:lint-status')
app -> jobsQueue : XADD snippet-jobs {task: lint, snippetId, userId, language, version}
app --> nginx : HTTP 202 Accepted (La UI NO se bloquea)
nginx --> browser : Confirmación inmediata

... Procesamiento Asíncrono en Background ...
runner -> jobsQueue : XREADGROUP group runner_group
activate runner
runner -> asset : Obtiene código fuente del snippet
runner -> runner : Ejecuta analizador con reglas del dueño y versión
runner -> resultsQueue : XADD snippet-job-results {task, snippetId, outcome: compliant|not-compliant, detail}
runner -> jobsQueue : XACK snippet-jobs (Confirma tarea terminada con éxito)
deactivate runner

... Actualización de Estado en App ...
app -> resultsQueue : XREADGROUP group app_group
activate app
app -> appdb : UPDATE snippet SET compliant = true/false
app -> app : Elimina 'pending' del hash en Redis ('snippet:lint-status')
app -> resultsQueue : XACK snippet-job-results
deactivate app

@enduml
```

---

## 3. ¿Por Qué Redis EXCLUSIVAMENTE como Cola y NO como Caché?

1. **Principio de Responsabilidad Única (SRP) en la Infraestructura**:
   - Redis tiene un propósito nítido y sin ambigüedades: **transporte y buffer asíncrono de eventos (Event-Driven Architecture)**.
2. **Consistencia Inmediata y Cero Datos Obsoletos (Zero Stale Data)**:
   - El caching de permisos introduce el clásico problema de *Cache Invalidation*.
   - Sin caché en Redis, **`AccessManager` es siempre la única fuente de verdad en tiempo real**. Un permiso revocado tiene efecto en el milisegundo cero.
3. **`AssetService` como Única Fuente de Verdad para Código**:
   - El código fuente no se duplica en memoria intermedia; reside de forma fidedigna y versionada en el almacenamiento de blobs (`AssetService` + Azurite).
4. **Tolerancia a Fallos Robusta (User Stories #12 y #15) — ¿Qué pasa si falla a la mitad?**:
   - **Fallo de un snippet individual:** El fallo se aísla; se emite `failed` en `snippet-job-results`, se envía `XACK` y el lote continúa.
   - **Caída abrupta del contenedor / nodo:** El acuse de recibo (`XACK`) solo se envía tras procesar con éxito el mensaje. Si una réplica se cae, el mensaje queda en la **PEL (Pending Entries List)**. Al transcurrir el timeout (60s), otra réplica lo recupera con `XCLAIM` (*At-Least-Once Delivery*).

---

## 4. El Rol Crítico de Nginx como Reverse Proxy

1. **Seguridad y Ocultamiento de Red (Network DMZ)**:
   - Los microservicios (`App`, `Runner`, `AccessManager`, Postgres, Redis, AssetService) corren en una red interna privada.
   - Ningún microservicio backend expone puertos directamente al exterior; todo el tráfico pasa por Nginx en `80` y `443`.
2. **Terminación SSL / TLS**:
   - Nginx maneja el cifrado HTTPS (puerto 443) y certificados Let's Encrypt de forma centralizada con renovación webroot en `/var/www/certbot`.
3. **Enrutamiento por Prefijo de Ruta (Path-Based Routing)**:
   - `/` $\rightarrow$ Sirve la SPA de React (`printscript-ui`).
   - `/api/*` $\rightarrow$ Redirige internamente a `App` (`http://snippetsearcher-app:8080`).
   - Runner y AccessManager no tienen ruta pública: solo App los llama, por la red interna.
4. **Trazabilidad (`X-Request-Id`)**:
   - Inyección y preservación del encabezado de correlación de punta a punta en los logs y New Relic.

---

## 5. Tabla Comparativa Definitiva

| Componente / Dimensión | Arquitectura Vieja | Arquitectura Nueva (Actual) | Justificación Técnica |
| :--- | :--- | :--- | :--- |
| **Punto de Entrada Exterior** | Sin proxy. Browser expuesto a puertos `:19081` y `:19082`. | **Nginx (Reverse Proxy)** en puertos `:80` / `:443`. | **Seguridad & DMZ**: Oculta puertos internos, enruta tráfico y maneja SSL. |
| **Punto de Entrada API** | Fragmentado: llamadas directas a `App` y a `Runner` en internet. | Entrada única `/api/` (App). Runner y AccessManager solo en la red interna. | **Aislamiento**: Puertos internos cerrados al exterior. |
| **Rol de Redis** | Sin rol claro o mezclado. | **EXCLUSIVAMENTE Message Queue (Streams)**. | **Event-Driven puro**: Procesa tareas con Consumer Groups y ACKs manuales. |
| **Políticas de Autorización** | Chatty HTTP con posible desincronización. | Consulta directa a `AccessManager` (Sin caché). | **Consistencia Inmediata**: Cero bugs de *stale permissions*; única fuente de verdad. |
| **Gestión de Código Fuente** | Llamadas cruzadas desordenadas. | `AssetService` como repositorio central estricto. | **Integridad de Assets**: Código versionado y desacoplado de la base relacional. |
| **Extensibilidad de Lenguajes** | PrintScript hardcodeado en Runner. | **Engine Central + Plugins** (`LanguageRunner`). | **Open/Closed Principle**: Nuevos lenguajes se integran con Strategy Pattern. |
| **Modelo de Base de Datos** | Antipatrón `jsonb` y `text[]` no tipados. | Tablas normalizadas (`compliant BOOLEAN` en Postgres). | **Integridad Referencial y Type Safety**. |
| **Monitoreo & Observabilidad** | Trazas fragmentadas e inconexas. | Traza unificada `X-Request-Id` desde Nginx hasta AssetService. | **New Relic Full Tracing**: Un solo árbol de transacción para toda la petición. |
