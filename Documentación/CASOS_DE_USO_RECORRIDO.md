# Recorrido de cada caso de uso por la arquitectura

## Piezas (leyenda)

| Pieza | Qué guarda / hace |
| :--- | :--- |
| **Auth0** | Login. Entrega el JWT que viaja en cada request. |
| **Nginx** | Entrada única. `/` → UI · `/api/` → App. Runner y AccessManager no están publicados. |
| **UI** (`printscript-ui`) | SPA React. Habla solo con el App. |
| **App** | BFF / negocio. Valida el JWT y los permisos, orquesta. |
| **appdb** (Postgres del App) | Metadatos del snippet (nombre, lenguaje, versión, `compliant`), tests y usuarios. |
| **AccessManager** + **accessmanager-db** | Permisos `owner` / `shared` de cada snippet. |
| **Runner** | Valida, ejecuta, lintea, formatea y testea con los plugins de PrintScript. |
| **runner-db** (Postgres del Runner) | Reglas de linteo y formateo de cada usuario por lenguaje. |
| **asset-service → Azurite** (bucket) | Código fuente: `snippets/{id}` (actual) y `snippets/{id}_original`. Solo el Runner accede. |
| **Redis** | Streams `snippet-jobs` (App → Runner) y `snippet-job-results` (Runner → App), hash `snippet:lint-status` (`pending`/`failed`) y output en vivo de las ejecuciones. |

**Paso común a todos:** el usuario se loguea en Auth0 → la UI recibe el JWT → en cada login hace
`PUT /api/v1/users` → el App guarda el usuario en **appdb** y le pide al Runner que lo cree con sus reglas por
defecto en **runner-db**. Toda request pasa por **Nginx**. Cuando dice "el App chequea permisos", es una
consulta HTTP al **AccessManager**, que lee **accessmanager-db**.

---

## US #1: Crear un snippet mediante archivo
1. La UI lee el archivo y manda `PUT /api/v1/snippets/{id}` (Nginx → **App**) con nombre, lenguaje y código. El App toma al dueño del token y le pasa todo al **Runner** por la red interna.
2. El **Runner** valida el código con el parser. Si es inválido, responde `400` con la regla, la línea y la columna, y no sigue.
3. El Runner guarda el código en el **bucket** (`{id}` y `{id}_original`). Si el bucket falla, responde `502` y no registra nada.
4. El Runner llama al **App** por la ruta interna (`PUT /internal/snippets/{id}`). El App guarda los metadatos en **appdb**, le da el permiso `owner` al creador en el **AccessManager** y encola el primer linteo en **Redis** (marca `pending` y hace `XADD` en `snippet-jobs`).
5. Respuesta `201` a la UI. En segundo plano el linteo sigue el recorrido de la US #15, paso 3.

## US #2: Actualizar un snippet mediante archivo
1. La UI manda el contenido nuevo con `PATCH /api/v1/snippets/{id}` (→ **App**). El App chequea que sea el dueño y se lo pasa al **Runner** con el token del usuario.
2. El **Runner** valida con el parser (`400` con regla, línea y columna si es inválido) y guarda en el **bucket** (`{id}` y `{id}_original`).
3. El Runner le pide al **App** un `POST .../lint-jobs` con el JWT del usuario. El App chequea permisos, busca al dueño en el **AccessManager** y encola el linteo en **Redis**.
4. El Runner también dispara los tests del snippet (ver US #16).
5. Para el resto de los datos (descripción, versión), la UI llama a `PATCH /api/v1/snippets/{id}` en el **App**: chequea que sea `owner` y actualiza **appdb**.

## US #3: Crear un snippet en el editor
Mismo recorrido que la **US #1**. La única diferencia está en la UI: el código sale del editor embebido en lugar de un archivo.

## US #4: Actualizar un snippet en el editor
Mismo recorrido que la **US #2**: `PATCH` al Runner → parser → bucket → lint-job en el App → Redis → tests.
Antes de guardar, el botón **Lint** del editor llama a `POST /api/v1/snippets/{id}/tasks/lint` (App → Runner, con las reglas del dueño en **runner-db**) para probar el código sin guardar nada.

## US #5: Ver todos los snippets
1. La UI llama a `GET /api/v1/snippets` (→ **App**).
2. El App le pide al **AccessManager** los snippets del usuario, separados en `owned` y `shared`.
3. El App lee de **Redis** (`snippet:lint-status`) el estado de linteo de todos esos snippets en una sola consulta.
4. El App busca los metadatos de cada uno en **appdb** y calcula el `compliance`: lo que diga Redis (`pending`/`failed`) o, si no hay nada, la columna `compliant`.
5. Devuelve la lista. La **UI** filtra y ordena por nombre, lenguaje y validez del lado del cliente.

## US #6: Ver un snippet
1. La UI llama a `GET /api/v1/snippets/{id}` (→ **App**).
2. El App lee los metadatos en **appdb**, le pide el contenido al **Runner** (que lo lee del **bucket**) y el estado de linteo a **Redis** (patrón BFF).
3. Responde todo junto. Si no vino el contenido, la UI se lo pide directo al Runner como respaldo.
4. Para mostrar los tests: `GET /api/v1/snippets/{id}/tests` → el App chequea `shared` u `owner` en el **AccessManager** y lee los tests de **appdb**. Para ejecutarlos, ver US #9.

## US #7: Compartir un snippet
1. Mientras se escribe, la UI llama a `GET /api/v1/users?name=...` → el **App** filtra los usuarios guardados en **appdb**.
2. Al elegir uno: `POST /api/v1/snippets/{id}/permissions` → el App chequea en el **AccessManager** que quien comparte sea `owner`.
3. El App busca al usuario destino en **appdb** (`404` si no existe).
4. El App crea el permiso `shared` en el **AccessManager**, que lo guarda en **accessmanager-db** (`409` si ya lo tenía).
5. Desde ese momento el usuario puede leer el snippet y sus tests.

## US #8: Crear tests para un snippet
1. La UI manda `POST /api/v1/snippets/{id}/tests` (→ **App**) con inputs, outputs esperados, versión y entorno.
2. El App chequea en el **AccessManager** que el usuario sea `owner`.
3. El App guarda el test en **appdb** (tablas normalizadas de test, inputs y outputs).
4. No interviene el Runner: crear un test no lo ejecuta, así que se puede guardar un test "inválido".

## US #9: Correr un test de un snippet
1. La UI manda `POST /api/v1/snippets/{id}/tests/{testId}/runs` (→ **App**).
2. El App chequea `shared` u `owner` en el **AccessManager** y lee el test (inputs, outputs, versión, entorno) en **appdb**.
3. El App llama al **Runner** (`POST /api/v1/testing`). El Runner lee el código del **bucket**, lo ejecuta con los inputs en orden y hace `RPUSH` en **Redis** de cada línea impresa.
4. Mientras corre, la UI consulta cada 300 ms `GET .../executions/status?kind=test` (App → Runner → **Redis**) para mostrar el output en vivo.
5. Al terminar, el Runner compara con los outputs esperados y el App devuelve `SUCCESS` / `FAILED` / `ERROR`.

## US #10: Ejecución interactiva de un snippet
1. La UI manda `POST /api/v1/snippets/{id}/executions` (→ **App**) con versión, entorno y la lista de `inputs` ingresados hasta ahora (al principio vacía). El App chequea `shared` u `owner` en el **AccessManager** (`403`) y que el snippet exista en **appdb** (`404`).
2. El App llama al **Runner**. El Runner lee el código del **bucket** y lo ejecuta con esos inputs. Cada `println` va a **Redis** (lista `execution:run:{userId}:{snippetId}:output`, con estado `RUNNING`/`WAITING`/`COMPLETED`/`ERROR`/`CANCELLED`, TTL 10 min). El `POST` queda bloqueado hasta que el snippet termina, pide un input o pasan 120 s (timeout → `ERROR`).
3. Si el snippet pide un input que no tiene, el Runner responde `WAITING` con el output hasta ahí y **descarta** la ejecución. El usuario escribe el input y la UI vuelve a mandar el `POST` del paso 1 con la lista ampliada (`[...inputs, nuevo]`). Como el snippet es determinístico, el output se reproduce y la ejecución llega al próximo input o al final. Así el Runner no guarda estado entre requests y funciona con N réplicas.
4. Mientras el `POST` está en curso, la UI consulta `GET .../executions/status?kind=run` (App → Runner → **Redis**) para ir mostrando el output en vivo, aunque el `GET` caiga en otra réplica.
5. `DELETE .../executions` cancela la ejecución (App → Runner, usuario tomado del JWT).

## US #11: Habilitar reglas de formateo
1. La UI carga las reglas actuales con `GET /api/v1/rules?task=formatting&language=...` (App → **Runner** → **runner-db**).
2. El usuario prende o apaga reglas y la UI manda `PUT /api/v1/rules` (→ **App**).
3. El App le pide al **Runner** que las guarde (`PATCH /users/{userId}/formatting/rules/{language}`), y el Runner las persiste en **runner-db**.
4. Con `applyToSnippets: false` termina acá (`200`). Con `true` sigue la US #12.

## US #12: Formateo automático de snippets
1. Igual que la US #11 hasta guardar las reglas en **runner-db**.
2. El App le pide al **AccessManager** los snippets propios del usuario y en **appdb** se queda con los de ese lenguaje.
3. Por cada uno, marca `pending` en **Redis** y publica `{format, snippetId, userId, language, version}` en `snippet-jobs`. Responde **`202 Accepted`**: el administrador no espera.
4. Una réplica del **Runner** lee el mensaje (`XREADGROUP`, grupo `runner_group`), lee el código del **bucket**, lo formatea con las reglas del dueño (**runner-db**), guarda el resultado en el **bucket** (solo `{id}`, el original queda igual) y publica `formatted` en `snippet-job-results`. Recién ahí hace `XACK`.
5. El **App** consume el resultado (grupo `app_group`) y encola un **linteo** del mismo snippet, porque el código cambió (sigue la US #15, paso 3).
6. Tolerancia a fallos: si una réplica muere, el mensaje queda sin ACK y otra lo toma (`XPENDING` + `XCLAIM`). A la tercera entrega se marca `failed` y se saltea.

## US #13: Descargar un snippet
1. La UI llama a `GET /api/v1/snippets/{id}/download?variant=original|formatted` (→ **App**).
2. El App chequea `shared` u `owner` en el **AccessManager**, lee los metadatos (nombre, lenguaje, versión) en **appdb** y averigua quién es el dueño.
3. El App llama al **Runner**:
   - `original` → lee `{id}_original` del **bucket**.
   - `formatted` → lee `{id}` del **bucket** y lo formatea en el momento con las reglas del dueño (**runner-db**), sin guardar.
4. El App devuelve el archivo `.ps` como adjunto.

## US #14: Habilitar reglas de linteo
Mismo recorrido que la **US #11**, con `task=linting`: UI → App → Runner → **runner-db**.
Con `applyToSnippets: true` sigue la US #15.

## US #15: Linteo automático de snippets
1. Igual que la US #14 hasta guardar las reglas en **runner-db**.
2. El App toma los snippets propios de ese lenguaje (**AccessManager** + **appdb**), marca `pending` en **Redis** y publica `lint` en `snippet-jobs` por cada uno. Responde `202`.
3. Una réplica del **Runner** lee el mensaje, lee el código del **bucket**, lo lintea con las reglas del dueño (**runner-db**) y la versión del snippet, y publica `compliant` / `not-compliant` / `failed` en `snippet-job-results`. Después hace `XACK`.
4. El **App** consume el resultado: guarda `compliant = true/false` en **appdb** y borra el `pending` de **Redis** (o lo marca `failed`).
5. La UI ve el estado nuevo la próxima vez que pide la lista (US #5).
6. Misma tolerancia a fallos que la US #12. Además, un reconciliador del App encola cada 5 minutos los snippets que nunca tuvieron resultado.

## US #16: Testing automático de snippets
1. Se dispara solo al guardar un cambio de contenido (US #2 / #4): la UI → `PATCH` al **Runner** → **bucket**.
2. Después de guardar y encolar el linteo, el Runner llama al **App** (`AppClient.testAll`, con el JWT del usuario).
3. Por cada test del snippet en **appdb**, se hace `POST .../tests/{testId}/runs`: el App vuelve a llamar al **Runner**, que corre el test contra el código nuevo del **bucket** (igual que la US #9).
4. El Runner junta los resultados y se los devuelve a la UI en la respuesta del PATCH (cuáles pasaron y cuáles fallaron).
5. El resultado de los tests no cambia el update: el código ya quedó guardado en el paso 1.
