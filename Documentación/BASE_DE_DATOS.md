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

### `test_environment`: variables de entorno de un test
| Columna | Tipo | Qué guarda |
| :--- | :--- | :--- |
| `id_test` | `VARCHAR(255)` PK compuesta, FK a `test` con `ON DELETE CASCADE` | Test al que pertenece |
| `env_name` | `VARCHAR(255)` PK compuesta | Nombre de la variable (por ejemplo `NOMBRE`) |
| `env_value` | `TEXT` | Valor (por ejemplo `valor`) |

Una fila por variable. Al borrar un test, Postgres borra sus variables. Antes era la columna JSONB
`test.config_rules`; se migra con `db/migrations/002-app-test-environment.sql` (ver sección 8).

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

Formateo y linteo tienen la misma forma: una tabla con una fila por usuario y lenguaje, y otra con una fila por regla.

### `formatting_rules` y `linting_rules`: de quién son las reglas
| Columna | Tipo | Qué guarda |
| :--- | :--- | :--- |
| `user_id` | `VARCHAR(255)` PK compuesta | `sub` del usuario |
| `set_language` | `VARCHAR(255)` PK compuesta | Lenguaje (`printscript`). Se llama así porque `language` es palabra reservada |

### `formatting_rule_values` y `linting_rule_values`: cada regla
| Columna | Tipo | Qué guarda |
| :--- | :--- | :--- |
| `user_id`, `set_language` | `VARCHAR(255)` PK compuesta, FK a la tabla anterior con `ON DELETE CASCADE` | De quién es la regla |
| `rule_name` | `VARCHAR(255)` PK compuesta | Nombre de la regla (`indent-inside-if`) |
| `rule_value` | `TEXT` | Valor como texto (`true`, `2`, `camel case`) |
| `value_type` | `VARCHAR(16)` | `boolean`, `number` o `string`: el Runner lo usa para devolver el valor con su tipo |

Ejemplo de filas de `linting_rule_values` para un usuario:

| `user_id` | `set_language` | `rule_name` | `rule_value` | `value_type` |
| :--- | :--- | :--- | :--- | :--- |
| `auth0\|65f...` | `printscript` | `identifier_format` | `true` | `boolean` |
| `auth0\|65f...` | `printscript` | `mandatory-variable-or-literal-in-println` | `true` | `boolean` |

La lista completa de reglas por defecto está en `PrintScriptRulesProvider.kt` del Runner. En el código, las entidades
`FormattingRule` y `LintingRule` siguen exponiendo las reglas como un mapa (`configRules`): la clase `RuleValue` lo
convierte a filas y de vuelta.

Antes, las reglas eran una columna JSONB `config_rules` en `formatting_rules` y `linting_rules`. Se migran con
`db/migrations/003-runner-reglas.sql` (ver sección 8).

### Por qué se sacó el JSONB: pros y contras

| | Con JSONB (antes) | Con tablas (ahora) |
| :--- | :--- | :--- |
| **Validación** | Postgres acepta cualquier JSON: una regla mal escrita o con un tipo equivocado se guarda igual | Cada regla es una fila con su tipo; nombre y valor no pueden faltar (`NOT NULL`) |
| **Integridad** | Sin claves foráneas: al borrar, la limpieza depende del código | `ON DELETE CASCADE`: al borrar un test o las reglas de un usuario, Postgres borra sus filas |
| **Consultas** | Hay que usar operadores de JSON (`->>`, `jsonb_each`) | SQL común: "qué usuarios tienen activada tal regla" es un `WHERE` y un `GROUP BY` |
| **Cambiar una sola regla** | Se reescribe el JSON entero | Se actualiza una fila |
| **Agregar una regla o un lenguaje** | No toca la base | Tampoco: las reglas son filas, no columnas |
| **Código** | Una columna, sin conversiones | Una clase más (`RuleValue`) para convertir texto ↔ tipo, y una tabla más por entidad |
| **Leer todas las reglas** | Una fila | Un join con N filas. Para unas pocas reglas por usuario, la diferencia no se nota |
| **Migración** | — | Hay que copiar los datos existentes una vez (scripts `002` y `003`) |

**Qué no cambió:** `test.in_put` y `test.out_put` siguen como `TEXT[]`. Se leen y escriben siempre enteros y en orden,
así que pasarlos a tablas suma joins sin ganar nada concreto. Tampoco se agregó FK de `test` a `snippet`: el borrado
del snippet ya borra sus tests desde App.

Las filas se crean con los valores por defecto cuando el usuario se loguea por primera vez (en el login, App le pide al
Runner `PUT /api/v1/users/{userId}`; si el usuario ya existe, el Runner responde `409` y App lo ignora) y se modifican desde la pantalla de reglas.

En Infra esta base no tiene script de inicialización: Hibernate crea las tablas al arrancar el Runner.

---

## 5. Lo que no está en Postgres: bucket y Redis

| Dónde | Qué guarda | Detalle |
| :--- | :--- | :--- |
| **Azurite** (vía `asset-service`) | El **código** de cada snippet: `{id}` (actual) y `{id}_original` (lo último que escribió el usuario, antes de formatear) | Solo el Runner accede. Ver `USO_DE_BUCKETS.md` |
| **Redis** | Streams `snippet-jobs` y `snippet-job-results` (trabajos de formateo y linteo), hash `snippet:lint-status` (`pending` / `failed`), output en vivo de ejecuciones (`execution:*`, 10 min de vida) | Ver `USO_DE_REDIS.md` |

---

## 6. Cómo se relacionan los datos

No hay *foreign keys* entre bases. Dentro de una misma base sí hay dos: `test_environment` → `test` en appdb, y
`*_rule_values` → `*_rules` en runner-db, las dos con `ON DELETE CASCADE`. Entre bases, los mismos ids aparecen en
varios lugares:

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
| **Cambiar reglas** | — | — | Actualiza las filas de `*_rule_values` | Si se aplican a los snippets: un trabajo por snippet en Redis |
| **Borrar snippet** | `snippet` y sus `test`: borra | `ownerships` y `shares`: borra | — | Bucket: borra el código. Redis: borra el estado |

---

## 8. Cómo se crean y migran las tablas

- **appdb y accessmanager-db:** al crear el volumen por primera vez, Postgres corre los scripts de
  `db/app-init/` y `db/accessmanager-init/`. En Swarm viajan como *configs* (`app_init_<hash>`,
  `accessmanager_init_<hash>`).
- **Todas las bases:** los servicios arrancan con `ddl-auto: update`. Hibernate **agrega** las columnas que falten,
  pero no cambia tipos ni borra columnas.
- **Migraciones manuales:** `db/migrations/`. Se corren a mano en la VM, sobre la base que indica cada archivo.

| Archivo | Base | Qué hace | Cuándo |
| :--- | :--- | :--- | :--- |
| `001-compliant-boolean.sql` | appdb | Pasa la columna de texto `compliance` al booleano `compliant` | Ya aplicada |
| `002-app-test-environment.sql` | appdb | Crea `test_environment` y copia ahí las variables del JSONB `test.config_rules` | Antes de deployar el App sin JSONB, y otra vez justo después |
| `003-runner-reglas.sql` | runner-db | Crea `formatting_rule_values` y `linting_rule_values` y copia ahí las reglas del JSONB `config_rules`, con su tipo | Antes de deployar el Runner sin JSONB, y otra vez justo después |
| `004-app-borrar-config-rules.sql` | appdb | Borra la columna JSONB `test.config_rules` | Cuando el App nuevo ya anda |
| `005-runner-borrar-config-rules.sql` | runner-db | Borra las columnas JSONB `config_rules` de las reglas | Cuando el Runner nuevo ya anda |

Todas son idempotentes: correrlas dos veces no duplica ni rompe nada. Por qué hay que correr dos veces la copia:
entre la primera corrida y el deploy, el código viejo puede seguir escribiendo en el JSONB, y la segunda copia lo que
falte sin pisar lo que el código nuevo ya guardó.

```bash
docker exec -i <contenedor-appdb>     psql -U app -d appdb      < db/migrations/002-app-test-environment.sql
docker exec -i <contenedor-runner-db> psql -U app -d snippet-db < db/migrations/003-runner-reglas.sql
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

-- appdb: variables de entorno de un test
SELECT env_name, env_value FROM test_environment WHERE id_test = '<id>';

-- runner-db: reglas de linteo de un usuario
SELECT set_language, rule_name, rule_value, value_type FROM linting_rule_values WHERE user_id = '<sub>' ORDER BY rule_name;

-- runner-db: cuántos usuarios tienen activada cada regla de formateo
SELECT rule_name, count(*) FROM formatting_rule_values WHERE rule_value = 'true' GROUP BY rule_name;
```

Para ver cuántos snippets veía un usuario en el tiempo, sin entrar a la VM, está el evento `SnippetsListed` de New
Relic (ver `NEW_RELIC.md`, sección 4).
