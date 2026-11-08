# Bases de datos: tablas, columnas y cómo se usan

## Índice
- [1. Vista general](#1-vista-general)
- [2. appdb (App)](#2-appdb-app)
- [3. accessmanager-db (AccessManager)](#3-accessmanager-db-accessmanager)
- [4. runner-db (Runner)](#4-runner-db-runner)
- [5. Lo que no está en Postgres: bucket y Redis](#5-lo-que-no-está-en-postgres-bucket-y-redis)
- [6. Cómo se relacionan los datos](#6-cómo-se-relacionan-los-datos)
- [7. Recorrido de los datos en cada operación](#7-recorrido-de-los-datos-en-cada-operación)
- [8. Cómo se crean y migran las tablas](#8-cómo-se-crean-y-migran-las-tablas)
- [9. Consultas útiles](#9-consultas-útiles)

---

## 1. Vista general

Cada servicio tiene **su propia base PostgreSQL 16**. Ningún servicio lee la base de otro: si necesita un dato, se lo
pide al servicio dueño por HTTP. Por eso no hay *foreign keys* entre bases; las relaciones son por id.

| Base | Servicio | Qué guarda | Servicio de Swarm |
| :--- | :--- | :--- | :--- |
| `appdb` | App | Metadatos de los snippets, sus tests y los usuarios | `appdb` |
| `accessmanager-db` | AccessManager | Quién es dueño de cada snippet y con quién se compartió | `accessmanager-db` |
| `runner-db` | Runner | Reglas de formateo y linteo de cada usuario, por lenguaje | `runner-db` |

Los datos sobreviven a reinicios y deploys: cada base usa un volumen con nombre (`app-pgdata`,
`accessmanager-pgdata`, `runner-pgdata`).

```
App ──────────────────────────▶ appdb             (snippet, test, userdata)
 │
 ├─HTTP─▶ AccessManager ──────▶ accessmanager-db  (ownerships, shares)
 │
 └─HTTP─▶ Runner ─────────────▶ runner-db         (formatting_rules, linting_rules)
            │
            └─HTTP─▶ asset-service ─▶ Azurite     (código de los snippets)

App y Runner comparten Redis (colas de formateo/linteo y estados).
```

---

## 2. appdb (App)

### `snippet`: un snippet y sus metadatos
| Columna | Tipo | Nulo | Default | Qué guarda |
| :--- | :--- | :--- | :--- | :--- |
| `id_snippet` | `VARCHAR(255)` | PK | — | Id del snippet (lo genera la UI). Es el mismo id en todas las bases y en el bucket |
| `name` | `VARCHAR(255)` | No | — | Nombre visible |
| `language` | `VARCHAR(255)` | No | — | Lenguaje (`printscript`) |
| `bucket_id` | `VARCHAR(255)` | No | — | Nombre del archivo en el bucket. Hoy es igual a `id_snippet` |
| `formatter_applied` | `BOOLEAN` | Sí | `true` | Marca heredada del diseño original |
| `compliant` | `BOOLEAN` | Sí | `NULL` | Resultado del último linteo: `true` cumple, `false` no cumple, `NULL` todavía sin resultado |
| `description` | `TEXT` | Sí | `''` | Descripción |
| `version` | `TEXT` | Sí | `'1.1'` | Versión de PrintScript con la que se interpreta |

`pending` (linteo en curso) y `failed` (el linteo no se pudo hacer) **no se guardan acá**: son estados del trabajo y
viven en Redis. La UI combina las dos fuentes (ver `USO_DE_REDIS.md`).

### `test`: casos de prueba de un snippet
| Columna | Tipo | Qué guarda |
| :--- | :--- | :--- |
| `id_test` | `VARCHAR(255)` PK | UUID generado por App |
| `id_snippet` | `VARCHAR(255)` | Snippet al que pertenece (relación lógica con `snippet.id_snippet`, sin FK) |
| `in_put` | `TEXT[]` | Inputs que se le pasan al snippet, en orden |
| `out_put` | `TEXT[]` | Salida esperada, línea por línea |
| `version` | `TEXT` | Versión de PrintScript para correrlo |
| `config_rules` | `JSONB` | Variables de entorno del test (`{"NOMBRE": "valor"}`) |

### `userdata`: usuarios conocidos
| Columna | Tipo | Qué guarda |
| :--- | :--- | :--- |
| `id_user` | `VARCHAR(255)` PK | `sub` del token de Auth0 (por ejemplo `auth0|65f...`) |
| `name_user` | `VARCHAR(255)` | Email o nombre, para buscar a quién compartirle |

Se crea o actualiza en cada login (`PUT /api/v1/users`). Es lo que permite compartir un snippet escribiendo el email.

---

## 3. accessmanager-db (AccessManager)

Es la **ACL** del sistema: define quién puede hacer qué sobre cada snippet.

### `ownerships`: el dueño de cada snippet
| Columna | Tipo | Qué guarda |
| :--- | :--- | :--- |
| `snippet_id` | `VARCHAR` PK | Id del snippet |
| `owner_id` | `VARCHAR` NOT NULL | `sub` del dueño |

Un snippet tiene exactamente un dueño. Puede editarlo, borrarlo, formatearlo y compartirlo.

### `shares`: con quién se compartió
| Columna | Tipo | Qué guarda |
| :--- | :--- | :--- |
| `snippet_id` | `VARCHAR` PK compuesta | Id del snippet |
| `user_id` | `VARCHAR` PK compuesta | `sub` del usuario con acceso de lectura |

Un usuario compartido puede leer, ejecutar, lintear, correr tests y descargar.

App consulta estas tablas en cada request a través de AccessManager (`GET /permissions?userId=&snippetId=`), que
responde `owner`, `shared` o nada. Detalle de los permisos en `SEGURIDAD.md`.

---

## 4. runner-db (Runner)

Las dos tablas tienen la misma forma: una fila por usuario y lenguaje.

### `formatting_rules` y `linting_rules`
| Columna | Tipo | Qué guarda |
| :--- | :--- | :--- |
| `user_id` | `VARCHAR` PK compuesta | `sub` del usuario |
| `set_language` | `VARCHAR` PK compuesta | Lenguaje (`printscript`) |
| `config_rules` | `JSONB` | Las reglas, como `{"nombre-de-regla": valor}` |

Ejemplos de valores por defecto (lista completa en `PrintScriptRulesProvider.kt` del Runner):

```json
// formatting_rules.config_rules
{ "enforce-spacing-around-equals": true, "enforce-spacing-after-colon-in-declaration": true,
  "line-breaks-after-println": true, "indent-inside-if": true, "mandatory-line-break-after-statement": true }

// linting_rules.config_rules
{ "identifier_format": true, "mandatory-variable-or-literal-in-println": true,
  "mandatory-variable-or-literal-in-readInput": true }
```

Las filas se crean con los valores por defecto cuando el usuario se loguea por primera vez (en el login, App le pide al
Runner `PUT /api/v1/users/{userId}`; si el usuario ya existe, el Runner responde `409` y App lo ignora) y se modifican desde la pantalla de reglas.

Esta base no tiene script de inicialización: Hibernate crea las tablas al arrancar el Runner.

---

## 5. Lo que no está en Postgres: bucket y Redis

| Dónde | Qué guarda | Detalle |
| :--- | :--- | :--- |
| **Azurite** (vía `asset-service`) | El **código** de cada snippet: `{id}` (actual) y `{id}_original` (lo último que escribió el usuario, antes de formatear) | Solo el Runner accede. Ver `USO_DE_BUCKETS.md` |
| **Redis** | Streams `snippet-jobs` y `snippet-job-results` (trabajos de formateo y linteo), hash `snippet:lint-status` (`pending` / `failed`), output en vivo de ejecuciones (`execution:*`, 10 min de vida) | Ver `USO_DE_REDIS.md` |

---

## 6. Cómo se relacionan los datos

No hay *foreign keys* entre bases. Los mismos ids aparecen en varios lugares:

```
snippet.id_snippet ═══ ownerships.snippet_id ═══ shares.snippet_id ═══ test.id_snippet ═══ blob {id} en Azurite

userdata.id_user ═══ ownerships.owner_id ═══ shares.user_id ═══ formatting_rules.user_id ═══ linting_rules.user_id
     (todos son el sub del token de Auth0)
```

Como no hay FK, **la consistencia la mantiene App**: al borrar un snippet borra todo lo relacionado, servicio por
servicio (sección 7).

---

## 7. Recorrido de los datos en cada operación

| Operación | appdb | accessmanager-db | runner-db | Bucket / Redis |
| :--- | :--- | :--- | :--- | :--- |
| **Login** | `userdata`: inserta o actualiza | — | Si es nuevo: inserta reglas por defecto | — |
| **Crear snippet** | `snippet`: inserta (`compliant = NULL`) | `ownerships`: inserta al dueño | — | Bucket: guarda `{id}` y `{id}_original`. Redis: `pending` y trabajo de linteo |
| **Listar snippets** | `snippet`: lee nombre, lenguaje y `compliant` | `ownerships` y `shares`: ids del usuario | — | Redis: estados `pending` / `failed` |
| **Leer un snippet** | `snippet`: metadatos | Chequea permiso | — | Bucket: código |
| **Editar el código** | — | Chequea que sea dueño | — | Bucket: reemplaza `{id}` y `{id}_original`. Redis: nuevo linteo |
| **Resultado del linteo** | `snippet.compliant = true/false` | — | Lee las reglas del dueño | Redis: borra `pending` |
| **Compartir** | `userdata`: busca al usuario por email | `shares`: inserta | — | — |
| **Crear test** | `test`: inserta | Chequea que sea dueño | — | — |
| **Cambiar reglas** | — | — | Actualiza `config_rules` | Si se aplican a los snippets: un trabajo por snippet en Redis |
| **Borrar snippet** | `snippet` y sus `test`: borra | `ownerships` y `shares`: borra | — | Bucket: borra el código. Redis: borra el estado |

---

## 8. Cómo se crean y migran las tablas

- **appdb y accessmanager-db:** al crear el volumen por primera vez, Postgres corre los scripts de
  `db/app-init/` y `db/accessmanager-init/`. En Swarm viajan como *configs* (`app_init_<hash>`,
  `accessmanager_init_<hash>`).
- **Todas las bases:** los servicios arrancan con `ddl-auto: update`. Hibernate **agrega** las columnas que falten,
  pero no cambia tipos ni borra columnas.
- **Migraciones manuales:** `db/migrations/`. Por ejemplo, `001-compliant-boolean.sql` pasó de una columna de texto
  `compliance` al booleano `compliant`. Es idempotente:
  ```bash
  docker exec -i <contenedor-appdb> psql -U app -d appdb < db/migrations/001-compliant-boolean.sql
  ```

---

## 9. Consultas útiles

Desde la VM, con `docker exec -it <contenedor> psql -U <usuario> -d <base>`:

```sql
-- appdb: snippets y su resultado de linteo
SELECT id_snippet, name, language, compliant, version FROM snippet ORDER BY name;

-- appdb: tests de un snippet
SELECT id_test, in_put, out_put FROM test WHERE id_snippet = '<id>';

-- accessmanager-db: snippets de un usuario (propios y compartidos)
SELECT snippet_id, 'owner' AS rol FROM ownerships WHERE owner_id = '<sub>'
UNION ALL
SELECT snippet_id, 'shared' FROM shares WHERE user_id = '<sub>';

-- runner-db: reglas de un usuario
SELECT set_language, config_rules FROM linting_rules WHERE user_id = '<sub>';
```

Para ver cuántos snippets veía un usuario en el tiempo, sin entrar a la VM, está el evento `SnippetsListed` de New
Relic (ver `NEW_RELIC.md`, sección 4).
