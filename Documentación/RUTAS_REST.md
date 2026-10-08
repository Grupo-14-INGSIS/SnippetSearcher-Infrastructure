# Catálogo y Especificación de Rutas REST (API Reference)

Este documento detalla todas las rutas del sistema adaptadas a las buenas prácticas de diseño **RESTful**, documentando su método HTTP, URI canónica, parámetros, cuerpo de petición/respuesta y autenticación.

---

## 1. Principios de Diseño REST Aplicados
1. **Sustantivos en Plural para Colecciones**: Los endpoints utilizan sustantivos (`/snippets`, `/users`, `/tests`, `/rules`) en lugar de verbos (`/run`, `/getSnippet`).
2. **Métodos HTTP Semánticos**:
   - `GET`: Obtención de recursos sin efectos colaterales (idempotente y seguro).
   - `POST`: Creación de nuevos recursos o submisiones de tareas.
   - `PUT`: Creación o reemplazo completo de un recurso identificado por ID.
   - `PATCH`: Modificación parcial de un recurso (ej: cambiar cumplimiento o versión).
   - `DELETE`: Eliminación de recursos.
3. **Sub-recursos Jerárquicos**: Los recursos anidados reflejan pertenencia directa (ej: `/snippets/{snippetId}/tests/{testId}/runs`, `/snippets/{snippetId}/permissions/{userId}`).
4. **Respuestas con Códigos de Estado Estándar**:
   - `200 OK`: Operación exitosa con cuerpo de retorno.
   - `204 No Content`: Operación exitosa sin cuerpo de retorno (ej: envío de input interactivo).
   - `401 Unauthorized`: Token ausente, inválido o permisos insuficientes.
   - `404 Not Found`: Recurso inexistente.
   - `409 Conflict`: Conflicto de estado (ej: usuario ya posee permisos sobre el snippet).

---

## 2. Snippets (`/api/v1/snippets`)

| Método | Endpoint | Descripción | Auth Requerida |
| :--- | :--- | :--- | :---: |
| `GET` | `/api/v1/snippets` | Lista todos los snippets del usuario autenticado (propios y compartidos con rol). | Sí (Bearer JWT) |
| `GET` | `/api/v1/snippets/{snippetId}` | Obtiene el snippet consolidado (metadatos de App + contenido de código de AssetService). | Sí (Bearer JWT) |
| `PUT` | `/api/v1/snippets/{snippetId}` | Registra o sobreescribe un snippet y asigna al creador como `owner`. | Sí (Bearer JWT) |
| `PATCH` | `/api/v1/snippets/{snippetId}` | Actualiza metadatos parciales del snippet (`description`, `version`). | Sí (Owner) |
| `DELETE` | `/api/v1/snippets/{snippetId}` | Elimina el snippet de la base de datos, sus tests asociados y su asset binario. | Sí (Owner) |
| `PATCH` | `/api/v1/snippets/{snippetId}/status` | Actualiza el estado de linteo/formateo y el cumplimiento (`compliant`/`not-compliant`). | Interno / Service |

---

## 3. Permisos y Compartición (`/api/v1/snippets/{snippetId}/permissions`)

| Método | Endpoint | Descripción | Auth Requerida |
| :--- | :--- | :--- | :---: |
| `GET` | `/api/v1/snippets/{snippetId}/permissions` | Lista los usuarios con permisos sobre el snippet dado. | Sí (Owner) |
| `POST` | `/api/v1/snippets/{snippetId}/permissions` | Comparte el snippet con otro usuario otorgándole rol `shared`. | Sí (Owner) |
| `DELETE` | `/api/v1/snippets/{snippetId}/permissions/{userId}` | Revoca el acceso compartido a un usuario específico. | Sí (Owner) |

---

## 4. Tests de Snippets (`/api/v1/snippets/{snippetId}/tests`)

| Método | Endpoint | Descripción | Auth Requerida |
| :--- | :--- | :--- | :---: |
| `GET` | `/api/v1/snippets/{snippetId}/tests` | Lista todos los casos de test configurados para un snippet. | Sí (Shared/Owner) |
| `POST` | `/api/v1/snippets/{snippetId}/tests` | Crea un nuevo test case con inputs, outputs esperados y variables de entorno. | Sí (Owner) |
| `DELETE` | `/api/v1/snippets/{snippetId}/tests/{testId}` | Elimina un test específico por su ID. | Sí (Owner) |
| `POST` | `/api/v1/snippets/{snippetId}/tests/{testId}/runs` | Ejecuta un test case contra el motor de ejecución y devuelve el resultado (`SUCCESS`/`FAIL`). | Sí (Shared/Owner) |

---

## 5. Ejecuciones y Lifecycle (`/api/v1/snippets/{snippetId}/executions`)

| Método | Endpoint | Descripción | Auth Requerida |
| :--- | :--- | :--- | :---: |
| `POST` | `/api/v1/snippets/{snippetId}/executions` | Inicia la ejecución interactiva o por lotes de un snippet. | Sí (Shared/Owner) |
| `GET` | `/api/v1/snippets/{snippetId}/executions/status` | Consulta el estado actual de la ejecución (`COMPLETED`, `WAITING_INPUT`, `ERROR`). | Sí (Shared/Owner) |
| `POST` | `/api/v1/snippets/{snippetId}/executions/input` | Envía una cadena de entrada por consola a una ejecución que espera input. | Sí (Shared/Owner) |
| `DELETE` | `/api/v1/snippets/{snippetId}/executions` | Cancela/aborta una ejecución en curso en el Runner. | Sí (Shared/Owner) |
| `PUT` | `/api/v1/snippets/{snippetId}/tasks/{task}` | Ejecuta una tarea sincrónica directa (ej: `format`) y devuelve el código procesado. | Sí (Owner) |

---

## 6. Reglas de Linteo y Formateo (`/api/v1/rules`)

| Método | Endpoint | Descripción | Auth Requerida |
| :--- | :--- | :--- | :---: |
| `GET` | `/api/v1/rules?task={task}&language={language}` | Obtiene las reglas configuradas por el usuario para una tarea y lenguaje específicos. | Sí (Bearer JWT) |
| `PUT` | `/api/v1/rules` | Actualiza la configuración de reglas del usuario. Si `applyToSnippets: true`, encola asíncronamente en **Redis Streams** la re-evaluación de los snippets. | Sí (Bearer JWT) |

---

## 7. Usuarios (`/api/v1/users`)

| Método | Endpoint | Descripción | Auth Requerida |
| :--- | :--- | :--- | :---: |
| `POST` / `PUT` | `/api/v1/users` | Registra o sincroniza el perfil del usuario autenticado contra la base de datos de App y Runner. | Sí (Bearer JWT) |
| `GET` | `/api/v1/users?name={filter}` | Lista usuarios registrados con filtro opcional de búsqueda (usado en el autocompletado para compartir). | Sí (Bearer JWT) |
| `DELETE` | `/api/v1/users` | Elimina la cuenta del usuario autenticado y todos sus snippets y tests asociados en cascada. | Sí (Bearer JWT) |

---

## 8. Ruteo a Nivel de Nginx Reverse Proxy (Edge)

Nginx expone el punto de entrada único por SSL/TLS (`https://dominio.duckdns.org`) y enruta internamente hacia la malla de Swarm:

```nginx
# UI Frontend
location / {
    proxy_pass http://snippetsearcher-ui:80;
}

# API Backend (App + BFF)
location /api/ {
    proxy_pass http://snippetsearcher-app:8080;
}

# Runner Engine
location /runner/ {
    proxy_pass http://snippetsearcher-runner:8080/;
}

# Access Manager
location /access/ {
    proxy_pass http://snippetsearcher-accessmanager:8080;
}
```
