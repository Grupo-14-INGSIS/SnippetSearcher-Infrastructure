# Uso de Buckets (Asset Service + Azurite) en SnippetSearcher

## Índice
- [1. Qué es un bucket y por qué lo usamos](#1-qué-es-un-bucket-y-por-qué-lo-usamos)
- [2. Piezas de la infraestructura](#2-piezas-de-la-infraestructura)
- [3. Contrato del Asset Service](#3-contrato-del-asset-service)
- [4. Convención: dónde se guarda cada snippet](#4-convención-dónde-se-guarda-cada-snippet)
- [5. Quién accede al bucket (y quién no)](#5-quién-accede-al-bucket-y-quién-no)
- [6. Flujos que tocan el bucket](#6-flujos-que-tocan-el-bucket)
- [7. Consistencia entre bucket y base de datos](#7-consistencia-entre-bucket-y-base-de-datos)
- [8. Qué se corrigió](#8-qué-se-corrigió)
- [9. Preguntas para repasar](#9-preguntas-para-repasar)

---

## 1. Qué es un bucket y por qué lo usamos

Un **bucket** (o *blob storage*: Azure Blob Storage, AWS S3, Google Cloud Storage) guarda
**objetos**: un contenido opaco (bytes o texto) identificado por una ruta `container/key`.
No tiene esquema, ni consultas, ni joins. Solo sabe guardar, leer y borrar por clave.

En SnippetSearcher el **código fuente** de cada snippet vive en un bucket. Los **metadatos**
(nombre, lenguaje, versión, descripción, compliance) viven en Postgres (`appdb`, tabla `snippet`).

| Dato | Dónde | Por qué |
| :--- | :--- | :--- |
| Código del snippet | Bucket (`snippets/{snippetId}`) | Texto de tamaño variable que solo se lee o reemplaza entero. No se filtra ni se busca por contenido. Sacarlo de la base la deja liviana. |
| Nombre, lenguaje, versión, descripción | Postgres del App | Se listan, filtran y ordenan: es un dato relacional. |
| ¿Cumple las reglas? (`compliant`) | Postgres del App | Resultado de negocio que se muestra y filtra en la tabla. |
| Permisos (owner / shared) | Postgres del AccessManager | Lo maneja otro servicio. |

La separación "metadatos en la base, contenido en blob storage" es la misma que usa cualquier
plataforma que guarda archivos. La base guarda una referencia: la columna `bucket_id`.

---

## 2. Piezas de la infraestructura

```
 Runner ──HTTP──▶ asset-service ──Azure Blob API──▶ azurite ──▶ volumen azurite-data
                  (API REST de la cátedra)          (emulador de Azure Blob Storage)
```

| Servicio (`docker-stack.yml`) | Imagen | Para qué |
| :--- | :--- | :--- |
| `azurite` | `mcr.microsoft.com/azure-storage/azurite` | Emulador oficial de **Azure Blob Storage**. Sin cuenta de Azure: corre en un contenedor y persiste en el volumen `azurite-data`. Puertos 10000 (blob), 10001 (queue) y 10002 (table). |
| `asset-service` | `ghcr.io/austral-ingsis/snippet-asset-service` | Servicio provisto por la cátedra. Esconde el SDK de Azure detrás de una API REST simple. Se configura con `AZURE_HOST=http://azurite`. |

El Runner lo encuentra por DNS interno de Swarm: `BUCKET_SERVICE=asset-service`, `BUCKET_PORT=8080`
(`app.bucket.url` en `application.yml`).

**¿Por qué Azurite y no un Azure real?** El TP no necesita una cuenta en la nube: Azurite
implementa la misma API, así que si mañana se cambia `AZURE_HOST` por una cuenta real, ni el
asset service ni nuestro código cambian.

---

## 3. Contrato del Asset Service

| Método | Ruta | Respuesta |
| :--- | :--- | :--- |
| `GET` | `/v1/asset/{container}/{key}` | `200` con el contenido · `404` si no existe |
| `PUT` | `/v1/asset/{container}/{key}` | `201` si lo creó · `200` si lo reemplazó (es un **upsert**) |
| `DELETE` | `/v1/asset/{container}/{key}` | `200`/`204` · `404` si no existía |

En el Runner, `client/AssetServiceClient.kt` es el cliente HTTP genérico de esta API.

---

## 4. Convención: dónde se guarda cada snippet

- **Container:** siempre `snippets` (constante `SnippetStorage.CONTAINER`).
- **Key:** el `snippetId` (UUID generado por la UI al crear). Es el **contenido actual**: el que se
  muestra en el editor, se ejecuta, se testea y se lintea.
- **Key `{snippetId}_original`:** copia del código **tal como lo escribió el usuario** (US #13). Se
  actualiza al crear y al editar, pero **no** cuando se formatea. Así se puede descargar el original
  aunque el formateo (por reglas o con el botón) haya reemplazado el contenido actual.
- **`snippet.bucket_id`** en Postgres: guarda el mismo `snippetId`, o sea la key en el bucket.

| Operación | Escribe `{id}` | Escribe `{id}_original` |
| :--- | :---: | :---: |
| Crear (`PUT`) / editar (`PATCH`) | ✔ | ✔ |
| Formatear (cambio de reglas o botón) | ✔ | — |
| Borrar | borra | borra |

Los snippets creados antes de este cambio no tienen copia: para ellos el original es el contenido actual.

El único lugar del código que conoce esta convención es
`SnippetSearcher-Runner/.../storage/SnippetStorage.kt`:

```kotlin
storage.get(snippetId)                // String? : null si no existe; errores de red/5xx se propagan
storage.getOriginal(snippetId)        // copia original, o el contenido actual si no hay copia
storage.exists(snippetId)
storage.save(snippetId, code)         // solo el contenido actual (lo usa el formateo)
storage.saveUserCode(snippetId, code) // contenido actual + original (crear y editar)
storage.delete(snippetId)             // borra los dos; true borrado / false no existía / excepción si falló
```

### Descarga (US #13)
`GET /api/v1/snippets/{id}/download?variant=original|formatted` en el App (alcanza con tenerlo compartido).
- `original`: la copia `{id}_original`.
- `formatted`: el contenido actual **formateado en el momento** con las reglas de formateo del dueño, sin
  guardar nada. Siempre refleja las reglas vigentes. Si el dueño no tiene reglas, es el contenido actual.

En la UI, el botón de descarga abre un menú con *Original version* y *Formatted version*.

---

## 5. Quién accede al bucket (y quién no)

**Solo el Runner** habla con el asset service. Lo hace desde `SnippetStorage`, que usan:

| Componente del Runner | Uso |
| :--- | :--- |
| `controller/SnippetController` | Crear (`PUT`), leer (`GET`), editar (`PATCH`) y borrar (`DELETE`) contenido, y los botones de formatear y lintear del editor. |
| `service/ExecutionService` y `SnippetExecution` | Leer el código para ejecutarlo. |
| `controller/TestingJobController` | Leer el código para correr los tests. |
| `jobs/SnippetJobConsumer` | Leer el código para lintear y formatear en segundo plano, y guardar el resultado del formateo. |

El **App nunca toca el bucket.** Cuando necesita el contenido (`GET /api/v1/snippets/{id}`, patrón BFF)
se lo pide al Runner por HTTP, y cuando se borra un snippet le pide al Runner que borre el contenido.

---

## 6. Flujos que tocan el bucket

### Crear un snippet
```
UI ──PUT /runner/api/v1/snippets/{id}──▶ Runner
   1. valida la sintaxis (ValidationPlugin)        → 400 si es inválido
   2. storage.exists(id)                           → 400 si ya existe
   3. storage.save(id, código)                     → 502 si el bucket no lo guardó (y NO sigue)
   4. App: PUT /api/v1/snippets/{id}               → guarda metadatos + permiso owner
                                                     + encola el primer linteo (Redis)
   5. 201 Created con {id, name, content, language, version}
```

### Editar el contenido
```
UI ──PATCH /runner/api/v1/snippets/{id}──▶ Runner
   1. valida la sintaxis
   2. storage.save(id, código nuevo)               → 502 si falla (upsert: sirve aunque no existiera)
   3. App: POST /api/v1/snippets/{id}/lint-jobs (con el JWT del usuario) → "pending" + trabajo en Redis
   4. App: corre los tests del snippet y devuelve el resumen
```

### Leer / ejecutar / testear
`storage.get(id)` y listo. Si devuelve `null`, el snippet no tiene contenido y la respuesta es `404`.

### Formateo en segundo plano (cambio de reglas de formateo)
El consumidor del Runner lee el código, lo formatea y hace `storage.save`. Si el bucket falla,
**no confirma el mensaje**: queda pendiente en Redis y se reintenta (ver `USO_DE_REDIS.md`).

### Borrar
`App DELETE /api/v1/snippets/{id}` → `Runner DELETE /api/v1/snippets/{id}` → `storage.delete`.
Si el contenido no existía (`404`), el App igual borra el snippet de su base.

---

## 7. Consistencia entre bucket y base de datos

No hay una transacción que abarque el bucket y Postgres: son dos sistemas distintos. Por eso
se eligió **el orden** de las operaciones para que una falla a la mitad deje un estado aceptable:

| Operación | Orden | Si falla a la mitad |
| :--- | :--- | :--- |
| Crear | 1° bucket, 2° App | Si falla el bucket no se registra nada: no quedan snippets "fantasma" sin código. Si falla el App queda un blob huérfano, que no se ve en ningún lado (inofensivo). |
| Editar | bucket (upsert) | Si el snippet había quedado registrado sin contenido, el PATCH lo repara. |
| Borrar | 1° permisos, 2° bucket, 3° base | Si el bucket falla, el snippet igual desaparece para el usuario (puede quedar un blob huérfano). |

---

## 8. Qué se corrigió

| Antes | Problema | Ahora |
| :--- | :--- | :--- |
| Cada llamador elegía el container: `"snippets"`, o `"snippet"` como fallback. | Dos containers para lo mismo. Leer probaba los dos. | Un solo container (`snippets`) definido en un solo lugar (`SnippetStorage`). |
| El formateo guardaba el resultado en **los dos** containers "por robustez". | Doble escritura. Si una fallaba, los containers quedaban distintos. | Una sola escritura. |
| `postAsset` atrapaba cualquier error y devolvía `500`, y **crear no miraba ese valor**. | Si el bucket fallaba, el snippet se registraba igual en el App **sin código**: aparecía en la lista y daba error al abrirlo. | `save` lanza una excepción. Crear y editar responden `502` y crear **no** registra el snippet en el App. |
| El consumidor de Redis ignoraba si el formateo se había guardado. | Se informaba "formateado" aunque el bucket no lo hubiera guardado. | Si `save` falla, el mensaje no se confirma y se reintenta. |
| Endpoints `/{container}/{snippetId}` en el Runner. | Cualquier cliente podía leer o escribir en cualquier container. | Eliminados: el container no es parte de la API pública. |
| `RunnerClient.deleteSnippet(container, id)` en el App, con un `container` que ignoraba. | Parámetro engañoso. | `deleteSnippet(id)`. |

> Si en Azurite quedaron blobs en el container viejo `snippet`, el código ya no los lee. Son restos
> de la doble escritura y se pueden ignorar.

---

## 9. Preguntas para repasar

1. **¿Por qué el código no va en Postgres?** No se consulta por contenido, se lee y reemplaza entero
   y puede ser grande. El blob storage es el lugar natural; la base guarda la referencia (`bucket_id`).
2. **¿Qué es Azurite?** El emulador oficial de Azure Blob Storage. Expone la misma API que la nube.
3. **¿Para qué está el asset service si existe Azurite?** Para no meter el SDK de Azure en nuestros
   servicios: es una API REST mínima (`GET`/`PUT`/`DELETE` por `container/key`).
4. **¿Qué servicio accede al bucket?** Solo el Runner. El App pide el contenido al Runner.
5. **¿Qué pasa si el bucket está caído cuando creo un snippet?** `502` y el snippet no se registra.
6. **¿Y si está caído mientras se formatea en segundo plano?** El mensaje queda pendiente en Redis
   y se reintenta hasta 3 veces. Si no se puede, el resultado es `failed`.
