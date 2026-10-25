# Testing E2E con Cypress — Estrategia y Ejecución

## Índice
- [Evolución de los Tests y Fidelidad al Modelo Original](#evolución-de-los-tests-y-fidelidad-al-modelo-original)
- [Chequeos de Backend y Verificación de Contratos](#chequeos-de-backend-y-verificación-de-contratos)
- [Cómo Funciona la Autodetección (Local / VM)](#cómo-funciona-la-autodetección-local--vm)
- [Estructura del Test Suite Actual](#estructura-del-test-suite-actual)
- [Comandos para Correr los Tests](#comandos-para-correr-los-tests)
- [Auth0, Tokens y Sesión](#auth0-tokens-y-sesión)

---

## Evolución de los Tests y Fidelidad al Modelo Original

| Etapa | Enfoque | Estado y Limitaciones |
|-------|---------|-----------------------|
| **v1 - Placeholders (Diciembre 2025)** | Datos mockeados en memoria con `FakeSnippetStore`. | No se comunicaba con la red ni con Auth0. No probaba el frontend real. |
| **v2 - Mocks HTTP (Octubre 2026)** | Mocks con `cy.intercept()` falseando respuestas. | Si el backend o la base de datos se caían, los tests daban verde igual. No testeaba la integración real. |
| **v3 - E2E Posta Fiel a los Originales (Actual)** | **Contra Backend Real + Verificación de Contratos HTTP.** | **Restaura los tests originales de la cátedra**, pero cumpliendo el `// TODO` original: *wait for the real data*. |

### ¿Por qué esta versión es la más fiel y completa?
1. **Restaura el template original de la cátedra:**
   El template provisto por la cátedra en `snippetDetail.cy.ts` contenía el comentario:
   ```typescript
   // TODO comment this line and uncomment 19 to wait for the real data
   ```
   Las suites anteriores con mocks o stores falsos eran un paso intermedio. La versión actual finalmente conecta las acciones originales (`Can share a snippet`, `Can run snippets`, `Can format snippets`, `Can save snippets`, `Can delete snippets`) contra la infraestructura real.

2. **Login y Selectores Reales:**
   - En el template original, `// cy.loginToAuth0(...)` estaba comentado porque los entornos no estaban listos. Ahora realiza el login real con credenciales válidas y cacheo de sesión con `cy.session()`.
   - Se adaptaron los componentes (ej. `#demo-simple-select` para elegir lenguaje) para que coincidan con lo que los tests originales requerían.

---

## Chequeos de Backend y Verificación de Contratos

A diferencia de los mocks que falseaban los datos, **los tests actuales dejan pasar las requests HTTP reales al backend (`req.continue`)** y validan activamente las respuestas de los microservicios:

* **Creación de Snippets (`PUT /api/v1/snippets/*` al Runner):**
  - Verifica que el Runner devuelva HTTP **201 Created**.
  - Valida el contrato del DTO: presencia de `id`, `name`, `content`, `language` y que el lenguaje sea `"printscript"`.
* **Listado y Búsqueda (`GET /api/v1/snippets` a App):**
  - Verifica que devuelva HTTP **200 OK** con la paginación correcta (máximo 10 filas por página).
  - Valida el filtro por query param `?name=...` contra la base de datos PostgreSQL.
* **Ejecución y Formateo en Kotlin (`POST /api/v1/snippets/{id}/run` y `/format` al Runner):**
  - Valida que el motor de Kotlin compile, devuelva HTTP **200 OK** y emita la salida esperada en consola (`OUTPUT`).
* **Permisos y Compartir (AccessManager):**
  - Valida la creación de relaciones de ownership y compartir con otros usuarios.
* **Nuevo comando auxiliar `cy.getAccessToken()`:**
  - Permite interactuar directamente contra la API de backend utilizando el token JWT real de la sesión activa de Auth0.

---

## Cómo Funciona la Autodetección (Local / VM)

El archivo `cypress.config.ts` conmuta automáticamente entre Docker local y las VMs de Azure según el valor de `CYPRESS_BASE_URL`:

```typescript
const baseUrl = process.env.CYPRESS_BASE_URL || defaultHost;
const isLocal = baseUrl.includes("localhost") || baseUrl.includes("127.0.0.1");

const backendUrl = isLocal
    ? "http://localhost:19081"          // ← Docker local
    : (isProdBranch
        ? "https://snippet26prod.duckdns.org"
        : "https://snippet26dev.duckdns.org");

const runnerUrl = isLocal
    ? "http://localhost:19082"          // ← Docker local
    : (isProdBranch
        ? "https://snippet26prod.duckdns.org/runner"
        : "https://snippet26dev.duckdns.org/runner");
```

### Tabla de Entornos

| Variable | Local (`localhost`) | VM develop | VM production |
|----------|-------------------|------------|---------------|
| `baseUrl` (frontend) | `http://localhost:5173` | `https://snippet26dev.duckdns.org` | `https://snippet26prod.duckdns.org` |
| `backendUrl` | `http://localhost:19081` | `https://snippet26dev.duckdns.org` | `https://snippet26prod.duckdns.org` |
| `runnerUrl` | `http://localhost:19082` | `https://snippet26dev.duckdns.org/runner` | `https://snippet26prod.duckdns.org/runner` |

---

## Estructura del Test Suite Actual

El suite mantiene exactamente la nomenclatura y casos de uso diseñados para la entrega:

### 1. `cypress/e2e/addSnippet.cy.ts`
- `Can add snippets manually`: Abre el modal, selecciona lenguaje, tipea código PrintScript 1.1, guarda y valida respuesta 201 del Runner y persistencia en la tabla.
- `Can add snippets via file`: Carga archivo `.ps` (`example_ps.ps`), guarda y verifica respuesta 201 del Runner con el contenido parseado.

### 2. `cypress/e2e/snippetDetail.cy.ts`
- `Can share a snippet`: Abre el modal de compartir, interactúa con el selector de usuarios y valida la asignación de permisos.
- `Can run snippets`: Ejecuta el snippet con `[data-testid="PlayArrowIcon"]` y verifica la salida en consola del Runner de Kotlin.
- `Can format snippets`: Aplica formato según reglas de PrintScript (`[data-testid="ReadMoreIcon"]`).
- `Can save snippets`: Modifica el contenido en el editor, persiste los cambios (`SaveIcon`) y valida la actualización.
- `Can delete snippets`: Elimina el snippet (`DeleteIcon`) y confirma su remoción de la base de datos.

### 3. `cypress/e2e/home.cy.ts`
- `Renders home`: Valida branding del header, barra de búsqueda y opciones del menú "Add Snippet".
- `Renders the first snippets`: Verifica la carga de la primera página de snippets contra la base de datos real.
- `Can creat snippet find snippets by name`: Crea un snippet por API con `cy.getAccessToken()` y valida que el filtro de búsqueda por nombre lo encuentre.

### 4. `cypress/e2e/protectedRoutes.cy.ts`
- `should redirect to login when accessing a protected route unauthenticated`: Verifica la redirección a Auth0 Universal Login mediante `cy.origin()`.
- `should display login content`: Verifica acceso a la ruta de autenticación.
- `should not redirect to login when the user is already authenticated`: Valida la persistencia de sesión sin redirección forzada.

---

## Comandos para Correr los Tests

### Requisitos previos
1. **Docker corriendo:** Contenedores de `SnippetSearcher-Infrastructure` levantados (`docker compose up -d`).
2. **Dependencias:** `npm install` en la raíz de `printscript-ui`.

---

### Correr en Local (contra Docker Local)

#### Modo Interactivo (interfaz gráfica de Cypress):
* **En PowerShell:**
  ```powershell
  $env:CYPRESS_BASE_URL="http://localhost:5173"; npm run cypress
  ```
* **En CMD o Git Bash:**
  ```bash
  npm run cypress -- --config baseUrl=http://localhost:5173
  ```

#### Modo Consola / Headless (todos los tests de corrido):
* **En PowerShell:**
  ```powershell
  $env:CYPRESS_BASE_URL="http://localhost:5173"; npm run cypress:run
  ```
* **En CMD o Git Bash:**
  ```bash
  npm run cypress:run -- --config baseUrl=http://localhost:5173
  ```

#### Correr un spec individual en consola:
```powershell
$env:CYPRESS_BASE_URL="http://localhost:5173"; npx cypress run --spec "cypress/e2e/snippetDetail.cy.ts"
```

---

### Correr contra la VM (sin variables de entorno locales)

Si no se pasa `CYPRESS_BASE_URL`, el sistema resuelve automáticamente DuckDNS según la rama Git activa:

```powershell
# Corre contra https://snippet26dev.duckdns.org o snippet26prod.duckdns.org según tu branch:
npm run cypress:run
```

Para forzar una VM específica:
```powershell
$env:CYPRESS_BASE_URL="https://snippet26dev.duckdns.org"; npm run cypress:run
$env:CYPRESS_BASE_URL="https://snippet26prod.duckdns.org"; npm run cypress:run
```

---

## Auth0, Tokens y Sesión

1. **Flujo Universal Login:** Emplea `cy.origin()` para interactuar directamente con el formulario de Auth0 de forma segura.
2. **Cacheo con `cy.session()`:** La sesión se autentica una sola vez y se reusa entre tests, optimizando drásticamente los tiempos de ejecución.
3. **Comando `cy.getAccessToken()`:** Permite recuperar el token JWT activo de `localStorage` para realizar llamadas directas a la API del backend desde Cypress sin pasar por la interfaz cuando se requiere inicializar datos de prueba.
