# Catálogo y Especificación de Rutas REST (API Reference)

Este documento lista todas las rutas del sistema: método HTTP, URI, qué hace y qué autorización
requiere. También explica la convención que se sigue y qué se cambió para cumplirla.

## Índice
- [1. Convención](#1-convención)
- [2. App: Snippets](#2-app-snippets-apiv1snippets)
- [3. App: Permisos](#3-app-permisos-apiv1snippetssnippetidpermissions)
- [4. App: Tests](#4-app-tests-apiv1snippetssnippetidtests)
- [5. App: Ejecuciones y tareas](#5-app-ejecuciones-y-tareas)
- [6. App: Reglas](#6-app-reglas-apiv1rules)
- [7. App: Usuarios](#7-app-usuarios-apiv1users)
- [8. Runner](#8-runner-runnerapiv1)
- [9. Ruteo en Nginx](#9-ruteo-en-nginx)
- [10. Qué se cambió y por qué](#10-qué-se-cambió-y-por-qué)
- [11. Qué no se cambió (todavía) y por qué](#11-qué-no-se-cambió-todavía-y-por-qué)
- [12. Preguntas para repasar](#12-preguntas-para-repasar)

---

## 1. Convención

1. **Recursos con sustantivos en plural:** `/snippets`, `/users`, `/tests`, `/rules`, `/permissions`,
   `/executions`. Las acciones se modelan como recursos que se crean: correr un test es crear una
   *corrida* (`POST .../tests/{id}/runs`) y pedir un linteo es crear un *trabajo de linteo*
   (`POST .../lint-jobs`).
2. **Una sola ruta por operación.** No hay alias (`/permission` y `/permissions`, `/run` y `/executions`):
   dos formas de hacer lo mismo duplican la superficie de la API y confunden a quien la consume.
3. **Verbos HTTP con su semántica:**

   | Verbo | Uso | ¿Idempotente? |
   | :--- | :--- | :---: |
   | `GET` | Leer, sin efectos | Sí |
   | `POST` | Crear un recurso nuevo o disparar una acción con resultado | No |
   | `PUT` | Crear o **reemplazar** un recurso con id conocido | Sí |
   | `PATCH` | Modificar una parte de un recurso | No necesariamente |
   | `DELETE` | Borrar. **Sin body**: los datos van en la ruta o en un query param | Sí |

4. **Sub-recursos para la pertenencia:** `/snippets/{snippetId}/tests/{testId}`,
   `/snippets/{snippetId}/permissions/{userId}`.
5. **Versión en la ruta:** `/api/v1/...`.
6. **El usuario sale del JWT, no del body:** el App obtiene el `userId` de `jwt.subject`. Nunca usa un
   `userId` que mande el cliente, porque podría ser el de otra persona.
7. **Códigos de estado:**

   | Código | Cuándo |
   | :--- | :--- |
   | `200 OK` | Éxito con cuerpo |
   | `201 Created` | Se creó un recurso (`Location` apunta a él) |
   | `202 Accepted` | Se aceptó un trabajo **asíncrono** que todavía no terminó |
   | `204 No Content` | Éxito sin cuerpo |
   | `400 Bad Request` | La request es inválida (por ejemplo, código con error de sintaxis) |
   | `401 Unauthorized` | **No hay token** o el token es inválido: no sabemos quién sos |
   | `403 Forbidden` | **Sabemos quién sos pero no tenés permiso** sobre ese snippet |
   | `404 Not Found` | El recurso no existe |
   | `409 Conflict` | Choca con el estado actual (snippet ya existente, ya compartido) |
   | `502 Bad Gateway` | Falló un servicio del que dependemos (por ejemplo, el bucket) |

---

## 2. App: Snippets (`/api/v1/snippets`)

| Método | Endpoint | Descripción | Auth |
| :--- | :--- | :--- | :---: |
| `GET` | `/api/v1/snippets` | Snippets del usuario (propios y compartidos). `compliance`: `pending` / `failed` / `compliant` / `not-compliant` (ver `USO_DE_REDIS.md`). | JWT |
| `GET` | `/api/v1/snippets/{snippetId}` | Snippet consolidado: metadatos del App + contenido del bucket vía Runner (BFF). | Público* |
| `PUT` | `/api/v1/snippets/{snippetId}` | Registra los metadatos, da `owner` al creador y encola el primer linteo. `409` si ya existe. Lo llama el Runner al crear. | Público* |
| `PATCH` | `/api/v1/snippets/{snippetId}` | Modifica descripción o versión. | Owner |
| `DELETE` | `/api/v1/snippets/{snippetId}` | Borra el snippet, sus tests, sus permisos y su contenido en el bucket. | Owner |
| `POST` | `/api/v1/snippets/{snippetId}/lint-jobs` | Crea un trabajo de linteo asíncrono con las reglas del dueño. `202 Accepted`. | Shared/Owner |

\* Ver §11: estas dos rutas quedaron abiertas porque el Runner las llama sin JWT.

## 3. App: Permisos (`/api/v1/snippets/{snippetId}/permissions`)

| Método | Endpoint | Descripción | Auth |
| :--- | :--- | :--- | :---: |
| `GET` | `/api/v1/snippets/{snippetId}/permissions` | Usuarios con quienes está compartido. | Owner |
| `POST` | `/api/v1/snippets/{snippetId}/permissions` | Comparte con otro usuario (rol `shared`). `404` si el usuario no existe, `409` si ya lo tenía. | Owner |
| `DELETE` | `/api/v1/snippets/{snippetId}/permissions/{userId}` | Revoca el acceso de un usuario. | Owner |

## 4. App: Tests (`/api/v1/snippets/{snippetId}/tests`)

| Método | Endpoint | Descripción | Auth |
| :--- | :--- | :--- | :---: |
| `GET` | `/api/v1/snippets/{snippetId}/tests` | Tests del snippet. | Shared/Owner |
| `POST` | `/api/v1/snippets/{snippetId}/tests` | Crea un test (inputs, outputs esperados, versión, entorno). | Owner |
| `DELETE` | `/api/v1/snippets/{snippetId}/tests/{testId}` | Borra un test. | Owner |
| `POST` | `/api/v1/snippets/{snippetId}/tests/{testId}/runs` | **Corre** el test y devuelve `SUCCESS` / `FAILED` / `ERROR`. | Shared/Owner |

## 5. App: Ejecuciones y tareas

| Método | Endpoint | Descripción | Auth |
| :--- | :--- | :--- | :---: |
| `POST` | `/api/v1/snippets/{snippetId}/executions` | Ejecuta con los inputs dados. Devuelve `WAITING` si el snippet pide otro input. | Shared/Owner |
| `POST` | `/api/v1/snippets/{snippetId}/executions/input` | Envía un input a la ejecución. `204`. | Shared/Owner |
| `GET` | `/api/v1/snippets/{snippetId}/executions/status?kind=run\|test` | Estado y output impreso **hasta ahora** de la ejecución (`run`, por defecto) o de la corrida de un test (`test`). La UI lo consulta mientras corre para mostrar el output en vivo (US #9 y #10). | Shared/Owner |
| `GET` | `/api/v1/snippets/{snippetId}/download?variant=original\|formatted` | US #13: descarga `.ps` (adjunto). `original` = como lo escribió el usuario; `formatted` = formateado en el momento con las reglas del dueño. | Shared/Owner |
| `DELETE` | `/api/v1/snippets/{snippetId}/executions` | Cancela la ejecución del usuario. Sin body. `200`. | Shared/Owner |
| `POST` | `/api/v1/snippets/{snippetId}/tasks/{task}` | Aplica `format` o `lint` de forma **síncrona** con las reglas del owner y devuelve el resultado. `lint` acepta un body opcional `{content}` con el código del editor (lo usa el botón Lint de la UI) y no guarda nada. `format` guarda el código nuevo y vuelve a encolar el linteo. `400` si no hay reglas o el código no parsea. | `lint`: Shared · `format`: Owner |

## 6. App: Reglas (`/api/v1/rules`)

| Método | Endpoint | Descripción | Auth |
| :--- | :--- | :--- | :---: |
| `GET` | `/api/v1/rules?task={linting\|formatting}&language={lang}` | Reglas del usuario. | JWT |
| `PUT` | `/api/v1/rules` | Reemplaza la configuración. Con `applyToSnippets: true` encola la revalidación en Redis de los snippets propios de ese lenguaje y responde `202`; si no, `200`. | JWT |

## 7. App: Usuarios (`/api/v1/users`)

| Método | Endpoint | Descripción | Auth |
| :--- | :--- | :--- | :---: |
| `PUT` | `/api/v1/users` | Crea o actualiza al usuario autenticado. Es idempotente: la UI lo llama en cada login. | JWT |
| `GET` | `/api/v1/users?name={filtro}` | Lista usuarios (autocompletado de "compartir"). | JWT |
| `DELETE` | `/api/v1/users` | Borra la cuenta del usuario autenticado y sus snippets en cascada. | JWT |

---

## 8. Runner (`/runner/api/v1/...`)

La UI llama al Runner directamente para el **contenido** de los snippets, y el App lo llama para
todo lo demás (ejecutar, reglas, tareas).

| Método | Endpoint | Descripción | Quién lo llama |
| :--- | :--- | :--- | :--- |
| `GET` | `/api/v1/snippets/{snippetId}` | Contenido del snippet. | App, UI |
| `PUT` | `/api/v1/snippets/{snippetId}` | Valida, guarda en el bucket y registra en App. `201`, `400` (código inválido o ya existe), `502` (bucket). | UI |
| `PATCH` | `/api/v1/snippets/{snippetId}` | Actualiza el contenido, crea un `lint-job` en App y corre los tests. | UI |
| `DELETE` | `/api/v1/snippets/{snippetId}` | Borra el contenido del bucket. `204` / `404` / `502`. | App |
| `POST` | `/api/v1/snippets/{snippetId}/tasks/{task}?userId=&language=&version=` | Formatear o lintear síncrono con las reglas de `userId`. En `lint`, un body de texto opcional reemplaza al código guardado. Antes llamaba al plugin sin reglas y siempre daba `500`. | App |
| `POST` | `/api/v1/snippets/{snippetId}/executions` | Ejecuta (body con `userId`, `version`, `environment`, `inputs`). | App |
| `POST` | `/api/v1/snippets/{snippetId}/executions/input` | Envía un input. | App |
| `GET` | `/api/v1/snippets/{snippetId}/executions/status?userId=&kind=run\|test` | Estado y output hasta ahora (se lee de Redis: responde cualquier réplica). | App |
| `GET` | `/api/v1/snippets/{snippetId}/download?variant=&userId=&language=&version=` | Original o formateado con las reglas de `userId`, sin guardar. | App |
| `DELETE` | `/api/v1/snippets/{snippetId}/executions?userId=` | Cancela. Idempotente: `204` aunque no hubiera ejecución. | App |
| `POST` | `/api/v1/testing` | Corre un test. | App |
| `GET` / `PATCH` | `/api/v1/users/{userId}/{linting\|formatting}/rules/{language}` | Leer o modificar reglas. | App |
| `PUT` / `DELETE` | `/api/v1/users/{userId}` | Alta o baja del usuario con sus reglas por defecto. | App |

---

## 9. Ruteo en Nginx

Nginx es el único punto de entrada (`https://<dominio>`) y reparte el tráfico dentro de la red de Swarm:

| Prefijo | Destino |
| :--- | :--- |
| `/` | `snippetsearcher-ui:80` |
| `/api/` | `snippetsearcher-app:8080` |
| `/runner/` | `snippetsearcher-runner:8080/` (le quita el `/runner`) |
| `/access/` | `snippetsearcher-accessmanager:8080/` |

---

## 10. Qué se cambió y por qué

| Antes | Problema | Ahora |
| :--- | :--- | :--- |
| `401` cuando el usuario **sí** estaba logueado pero no tenía permiso (15 casos en el App) | `401` significa "no sé quién sos". El cliente podría intentar volver a loguearse sin sentido. | `403 Forbidden`. `401` queda solo para requests sin token o con token inválido (lo hace Spring Security). |
| Correr un test con `PUT /snippets/{id}/tests/{testId}` (además de `POST .../run` y `POST .../runs`) | `PUT` sobre un test debería **reemplazarlo**, no ejecutarlo. Tres rutas para lo mismo. | Solo `POST /snippets/{id}/tests/{testId}/runs`. El Runner (`AppClient.testAll`) también usa esta ruta. |
| Alias `/permission` y `/permissions`, `POST` y `PUT` para compartir | Rutas duplicadas. Compartir crea un permiso: es `POST`. | Solo `/permissions`, y `POST` para compartir. |
| Alias `/execution`, `/executions` y `/run`; también `/execution/status` y `/run/status` | Rutas duplicadas. | Solo `/executions`, `/executions/input` y `/executions/status`. |
| `PUT /snippets/{id}/tasks/{task}` y su alias `/task/{task}` | No reemplaza ningún recurso: es una acción que devuelve un resultado. | `POST /snippets/{id}/tasks/{task}`, sin alias. En App y en Runner. |
| `POST /snippets/{id}/lint` | Verbo en la URL. | `POST /snippets/{id}/lint-jobs`: crea un trabajo de linteo y devuelve `202`. |
| `DELETE .../executions` con body `{userId}` (App y Runner) | Muchos proxies y clientes descartan el body de un DELETE. Además en el App el usuario ya viene en el JWT. | App: sin body, usa el JWT. Runner: `?userId=` como query param (igual que `/status`). Se borraron los DTOs `CancelExecutionRequest` y `SnippetExecutionRunerCancel`. |
| `POST` y `PUT /users` | Dos verbos para lo mismo. | Solo `PUT`: es idempotente y se llama en cada login. |
| Registrar un snippet existente: `400`, o peor, lo **pisaba** | `save()` de JPA sobre un id existente hace *merge* y sobreescribía nombre y metadatos. | Se chequea antes: `409 Conflict` sin tocar nada. |
| `PATCH /snippets/{id}/status` público y `POST /testing` público | Cualquiera podía marcar un snippet como compliant o meter mensajes en el stream. | Eliminados (ver `USO_DE_REDIS.md`). |
| Rutas `/{container}/{snippetId}` en el Runner | Exponían el container del bucket. | Eliminadas (ver `USO_DE_BUCKETS.md`). |

**Impacto en la UI:** ninguno. `printscript-ui` (rama `develop`) ya usaba solo las rutas canónicas. El DELETE de
ejecuciones todavía manda un body, que ahora se ignora. Los tests de Cypress de `develop`, que corren contra el
backend real, también usan solo las rutas canónicas (`/permissions`, `/executions`, `/tests/{id}/runs`).

Tests nuevos en el App que fijan estas reglas:
- `PUT /tests/{id}` ya no corre el test;
- los alias viejos no llegan a ningún handler;
- registrar un snippet duplicado da `409` sin modificarlo;
- falta de permiso da `403`, y sin token da `401`.

---

## 11. Qué no se cambió (todavía) y por qué

| Tema | Por qué se dejó | Cómo sería lo correcto |
| :--- | :--- | :--- |
| `GET /snippets` devuelve un **objeto** `{ id: {...} }` en lugar de una lista, y la paginación la hace la UI | La UI depende de esa forma. Cambiarla obliga a cambiar UI y Cypress juntos. | Una lista `[{id, name, ...}]` con `?page=&pageSize=` y filtros resueltos en el servidor. |
| `PUT` y `GET /api/v1/snippets/{id}` del App son públicos | El Runner los llama sin JWT al crear y al leer. | Autenticación entre servicios (un secreto compartido o *client credentials* de Auth0) y cerrar estas rutas. |
| **El Runner no tiene autenticación y es accesible desde internet por `/runner/`**. Sus rutas aceptan `userId` en el body o en query params. | Es así desde el diseño original, y la UI lo usa para crear y editar el contenido. | Que el Runner valide el JWT (como el App) y saque el usuario de ahí, o que la UI pase siempre por el App y el Runner quede solo en la red interna. |
| `/access/` (AccessManager) también está expuesto por Nginx | Nadie de afuera lo necesita. | Sacar esa `location` de Nginx: solo lo usa el App, por la red interna. |
| `GET /rules?task=&language=` | Funciona y es claro. | Algo como `/users/me/rules/{task}/{language}` sería más consistente con el Runner. Es cosmético. |

---

## 12. Preguntas para repasar

1. **¿401 o 403?** `401`: no hay token o es inválido. `403`: el usuario está identificado pero no puede hacer eso.
2. **¿Por qué correr un test es `POST .../runs` y no `PUT .../tests/{id}`?** `PUT` reemplaza el recurso que está en
   esa ruta. Correr un test no reemplaza el test: crea una corrida nueva con su resultado.
3. **¿Por qué `202` en `lint-jobs` y en `PUT /rules`?** Porque el trabajo se aceptó pero todavía no terminó: se
   procesa en segundo plano y el resultado llega después (`pending` → `compliant` / `not-compliant`).
4. **¿Por qué un `DELETE` no lleva body?** La especificación HTTP no le da semántica y muchos proxies y clientes lo
   descartan. Lo que haga falta va en la ruta o en un query param.
5. **¿Qué tienen de malo los alias?** Duplican la superficie de la API (más rutas que documentar, testear y proteger)
   y dejan que cada cliente use una distinta.
6. **¿Por qué el `userId` no sale del body?** Porque cualquiera podría mandar el de otro. El único dato confiable es
   el JWT firmado por Auth0.
