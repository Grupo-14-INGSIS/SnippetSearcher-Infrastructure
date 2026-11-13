# Autenticación con Auth0 en SnippetSearcher

## Índice
- [1. Para qué se usa Auth0](#1-para-qué-se-usa-auth0)
- [2. Conceptos básicos](#2-conceptos-básicos)
- [3. Qué hay creado en el tenant](#3-qué-hay-creado-en-el-tenant)
- [4. Flujo completo: de abrir la página a llamar a la API](#4-flujo-completo-de-abrir-la-página-a-llamar-a-la-api)
- [5. Frontend (printscript-ui)](#5-frontend-printscript-ui)
- [6. Backend (SnippetSearcher-App)](#6-backend-snippetsearcher-app)
- [7. Variables de configuración](#7-variables-de-configuración)
- [8. Cómo probarlo](#8-cómo-probarlo)
- [9. Problemas comunes](#9-problemas-comunes)
- [10. Pendientes / cosas a revisar](#10-pendientes--cosas-a-revisar)

---

## 1. Para qué se usa Auth0

Auth0 es un **proveedor de identidad** (IdP) externo. Nosotros no guardamos contraseñas ni
manejamos sesiones: Auth0 se encarga del login, y nos devuelve un **token JWT** firmado que dice
quién es el usuario.

- La **UI** redirige a la página de login de Auth0 (Universal Login) y recibe el token.
- La UI manda ese token en cada request: `Authorization: Bearer <token>`.
- La **App** (Spring) valida la firma y el emisor del token, y usa el `sub` como id del usuario.

---

## 2. Conceptos básicos

| Concepto | Qué es | En nuestro proyecto |
| :--- | :--- | :--- |
| **Tenant** | La "cuenta" de Auth0, con su dominio | `dev-65tlgyzfpbzeka8a.us.auth0.com` |
| **Application** | El cliente que pide tokens (la SPA) | Client ID `pDaLfxwVAerUnhjKfJNfxLfduUPJQi3x` (Single Page App) |
| **API** | El recurso protegido. Su *identifier* es el `audience` del token | `https://api.snippets.com` |
| **Connection** | De dónde salen los usuarios (base de datos, Google, etc.) | `User-Pass-Auth` (base de datos usuario/contraseña) |
| **Scopes** | Permisos que se piden en el token | `read:snippets write:snippets delete:snippets` |
| **Access token** | JWT que se manda a la API | `iss` = tenant, `aud` = API, `sub` = id del usuario |
| **ID token** | JWT con datos del usuario para la UI (nombre, email) | Lo usa `useAuth0().user` |

**OAuth2 / OIDC:** la UI usa el flujo *Authorization Code + PKCE*, que es el recomendado para
SPAs (no hay client secret en el navegador). El SDK `@auth0/auth0-react` lo hace solo.

> El repo `auth0-integration` de la cátedra usa el grant `password` (mandar usuario y contraseña
> directo a `/oauth/token`). Sirve para probar con `curl`, pero **no** es lo que usa la UI.

---

## 3. Qué hay creado en el tenant

Verificado contra Auth0 (`/authorize` con el client ID de la UI):

- **Callback URLs permitidas:** `http://localhost:5173`, `https://snippet26dev.duckdns.org`,
  `https://snippet26prod.duckdns.org`. Con cualquier otra URL, Auth0 responde `403`.
- **Connection `User-Pass-Auth`:** habilitada para la app → redirige a `/u/login` (pantalla de login).
- **Connection `Username-Password-Authentication`:** **no** está habilitada para la app → Auth0
  vuelve a la UI con `error=invalid_request&error_description=the connection is not enabled`.

Si se agrega un ambiente nuevo hay que sumar su URL en *Applications → (la SPA) → Settings* en
**Allowed Callback URLs**, **Allowed Logout URLs** y **Allowed Web Origins**.

---

## 4. Flujo completo: de abrir la página a llamar a la API

```
Usuario          UI (React)                      Auth0                         App (Spring)
  │  abre /          │                              │                               │
  │─────────────────>│ ProtectedRoute:              │                               │
  │                  │ ¿isAuthenticated? no         │                               │
  │                  │ → Navigate a /login          │                               │
  │                  │ LoginScreen:                 │                               │
  │                  │ loginWithRedirect() ────────>│ /authorize (code + PKCE)      │
  │                  │                              │ → /u/login (Universal Login)  │
  │  usuario/clave ─────────────────────────────────>│                               │
  │                  │<──── redirect a origin ?code=│                               │
  │                  │ SDK canjea code por tokens ─>│ /oauth/token                  │
  │                  │<──────── access + id token ──│                               │
  │                  │ isAuthenticated = true       │                               │
  │                  │ → HomeScreen (snippets)      │                               │
  │                  │ AuthWrapper: POST registro de usuario ─────────────────────────>│
  │                  │ fetch con Authorization: Bearer <access token> ────────────────>│
  │                  │                              │<── JWKS (claves públicas) ────│ valida firma + iss
  │                  │<──────────────────────────────────────────────── respuesta ────│ userId = jwt.sub
```

1. Toda ruta de la app (`/`, `/rules`, `/snippets/:id`) está envuelta en `ProtectedRoute`.
2. Sin sesión, `ProtectedRoute` manda a `/login`.
3. `/login` llama a `loginWithRedirect()` apenas se monta: el usuario ve la pantalla de Auth0.
4. Auth0 vuelve a `window.location.origin` (la raíz) con `?code=...`; el SDK lo canjea por tokens.
5. Con sesión, `/` muestra el listado de snippets.
6. `AuthWrapper` (en `main.tsx`) registra al usuario en el backend la primera vez (un `409` se ignora:
   ya existía).
7. Cada llamada a la API pide el token con `getAccessTokenSilently` (lo renueva solo con el
   refresh token) y lo manda como `Bearer`.

---

## 5. Frontend (printscript-ui)

| Archivo | Qué hace |
| :--- | :--- |
| `src/main.tsx` | `Auth0Provider` con `domain`, `clientId`, `audience`, `scope`, `connection`. `useRefreshTokens` y `cacheLocation="localstorage"` para que la sesión sobreviva a un F5. |
| `src/App.tsx` | Rutas. Todas protegidas salvo `/login`. |
| `src/components/common/ProtectedRoute.tsx` | Mientras el SDK carga muestra *Loading authentication...*; si no hay sesión, `Navigate` a `/login`. |
| `src/screens/Login.tsx` | Llama a `loginWithRedirect()` en un `useEffect`. |
| `src/contexts/serviceContext.tsx` | Le pasa `getAccessTokenSilently` a `ApiSnippetOperations`. |
| `src/services/api.ts` | Pide el token (con el `audience`) y agrega `Authorization: Bearer`. La UI solo habla con App. |
| `src/components/navbar/Navbar.tsx` | `logout({ logoutParams: { returnTo: window.location.origin } })`. |
| `cypress/support/auth-provider-commands/auth0.ts` | Login de los tests E2E escribiendo en el formulario de Auth0 (`cy.origin`). |

`src/services/authService.ts` y `src/contexts/authContext.tsx`, de una versión anterior (grant `password`) que nadie
usaba, se borraron el 13/11/2026.

**Importante:** las `VITE_*` las fija Vite **al compilar**. Cambiarlas en el `environment:` del
`docker-stack.yml` no tiene efecto; hay que volver a construir la imagen (en CI salen de los
*secrets* del repo de la UI y se pasan como `--build-arg`).

---

## 6. Backend (SnippetSearcher-App)

Es un **Resource Server** de OAuth2: no hace login, solo valida tokens.

`src/main/resources/application.yml`:

```yaml
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri: https://dev-65tlgyzfpbzeka8a.us.auth0.com/
```

Con `issuer-uri` Spring baja la configuración OIDC del tenant
(`/.well-known/openid-configuration`), obtiene las claves públicas (JWKS) y valida firma,
vencimiento e `iss` de cada token.

`config/SecurityConfig.kt`:

- `/api/v1/**` → `authenticated()` (salvo `GET` y `PUT` de `/api/v1/snippets/*`, que están abiertos).
- `.oauth2ResourceServer { oauth2.jwt {} }` activa la validación del Bearer.
- CORS solo para los orígenes conocidos (dev, prod y localhost:5173), sin credenciales: el token va
  en un header, no en cookies.

En los controllers el usuario sale del token:

```kotlin
@PreAuthorize("isAuthenticated()")
...
val jwt = authentication.principal as Jwt
val userId = jwt.subject   // ej: "auth0|65f1c..."
```

El Runner y el AccessManager no validan tokens: no son accesibles desde afuera (solo los llama la
App por la red interna; el Runner recibe tráfico de la UI a través del reverse-proxy).

---

## 7. Variables de configuración

### UI (build-time)

| Variable | Valor | Uso |
| :--- | :--- | :--- |
| `VITE_AUTH0_DOMAIN` | `dev-65tlgyzfpbzeka8a.us.auth0.com` | Dominio del tenant |
| `VITE_AUTH0_CLIENT_ID` | `pDaLfxwVAerUnhjKfJNfxLfduUPJQi3x` | Application (SPA) |
| `VITE_AUTH0_AUDIENCE` | `https://api.snippets.com` | Para que el access token sea un JWT de nuestra API |
| `VITE_AUTH0_REALM` | `User-Pass-Auth` | Se pasa como `connection`: fuerza esa base de usuarios |

Dónde se definen: `.env` local (ignorado por git), `ARG` del `Dockerfile`, `build.args` del
`docker-compose.yml` y los *secrets* de GitHub Actions (`ci.yaml`).

El client ID **no es secreto** (va en el JS que baja el navegador). Lo que nunca tiene que ir en la
UI es un *client secret*.

### App

| Propiedad | Uso |
| :--- | :--- |
| `spring.security.oauth2.resourceserver.jwt.issuer-uri` | Tenant que emite los tokens |
| `auth0.audience` | Identifier de la API (hoy no se usa para validar, ver [10](#10-pendientes--cosas-a-revisar)) |

---

## 8. Cómo probarlo

**En el navegador:**

1. Abrir `http://localhost:5173/` (o el dominio de dev) en una ventana de incógnito.
2. Debe pasar por `/login` y terminar en `https://dev-65tlgyzfpbzeka8a.us.auth0.com/u/login`.
3. Loguearse → vuelve a la raíz y aparece el listado de snippets.
4. En DevTools → Network, los requests a `/api/v1/...` llevan `Authorization: Bearer eyJ...`.
5. Pegar el token en <https://jwt.io> para ver `iss`, `aud`, `sub`, `scope`, `exp`.

**Sin navegador (que Auth0 acepte la config):**

```bash
curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" \
 "https://dev-65tlgyzfpbzeka8a.us.auth0.com/authorize?client_id=pDaLfxwVAerUnhjKfJNfxLfduUPJQi3x&response_type=code&scope=openid&audience=https%3A%2F%2Fapi.snippets.com&connection=User-Pass-Auth&redirect_uri=http%3A%2F%2Flocalhost%3A5173&state=x&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256"
```

- `302 .../u/login?...` → bien.
- `403` → la `redirect_uri` no está en *Allowed Callback URLs*.
- `302 .../authorize/resume` y después `?error=...` en la UI → leer `error_description`.

**La API sin token:** `curl -i https://snippet26dev.duckdns.org/api/v1/<endpoint protegido>` → `401`.

**E2E:** los tests de Cypress usan `loginViaAuth0Ui` con el usuario de `cypress.env.json`.

---

## 9. Problemas comunes

| Síntoma | Causa | Solución |
| :--- | :--- | :--- |
| Página de Auth0 *Callback URL mismatch* / `403` | El origen no está en Allowed Callback URLs | Agregarlo en la Application |
| Vuelve con `the connection is not enabled` | `VITE_AUTH0_REALM` apunta a una connection no habilitada para la app | Usar `User-Pass-Auth` o habilitar la connection en *Applications → Connections* |
| Loop *Redirecting to login...* | El SDK no termina de procesar `?code=` (p. ej. `Allowed Web Origins` faltante, o reloj del equipo muy corrido) | Revisar la consola y la configuración de la Application |
| La API responde `401` con token | Token sin `audience` (es opaco, no JWT) o de otro tenant | Revisar `VITE_AUTH0_AUDIENCE` y el `issuer-uri` |
| Cambié una `VITE_*` en el stack y no pasa nada | Son de build | Reconstruir la imagen de la UI |
| Después del logout queda en Auth0 | `returnTo` no está en Allowed Logout URLs | Agregarlo |

---

## 10. Pendientes / cosas a revisar

- **Connection inconsistente:** `docker-stack.yml` y el `environment:` de la UI en
  `docker-compose.yml` dicen `Username-Password-Authentication`, que **no** está habilitada. Hoy no
  rompe porque esas variables no se usan en runtime, pero conviene dejarlas en `User-Pass-Auth` (o
  borrarlas) y confirmar el valor del secret `VITE_AUTH0_REALM` en el repo de la UI.
- **Audience:** ✅ resuelto. App valida `aud = https://api.snippets.com` (`audiences` en `application.yml`).
- **Scopes no aplicados:** el backend solo exige `isAuthenticated()` más el permiso por snippet.
  Justificación y cómo sumarlos en [SEGURIDAD.md](SEGURIDAD.md).
- **Secret en el repo:** ✅ el `clientSecret` se sacó de `application.yml` (App no lo usaba). Queda en el
  historial de Git y no se rota, por decisión (ver [SEGURIDAD.md](SEGURIDAD.md), sección 5).
- **Código muerto:** ✅ `authService.ts` y `authContext.tsx` se borraron de la UI (13/11/2026).
