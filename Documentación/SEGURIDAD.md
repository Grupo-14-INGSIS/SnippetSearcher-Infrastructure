# Seguridad: autenticación, autorización y red

## Índice
- [1. Resumen](#1-resumen)
- [2. Autenticación (¿quién sos?)](#2-autenticación-quién-sos)
- [3. Autorización (¿qué podés hacer?)](#3-autorización-qué-podés-hacer)
- [4. Qué está expuesto a internet](#4-qué-está-expuesto-a-internet)
- [5. Secretos](#5-secretos)
- [6. Cómo comprobarlo](#6-cómo-comprobarlo)
- [7. Qué plantea la clase y cómo se cumple](#7-qué-plantea-la-clase-y-cómo-se-cumple)
- [8. Pendientes](#8-pendientes)

---

## 1. Resumen

```
Navegador ──login──▶ Auth0 (Authorization Code + PKCE) ──▶ access token (JWT)
    │
    └─ Bearer token ──▶ nginx ──/api/──▶ App ── valida el token (firma, iss, exp, aud)
                                          ├─ ¿es dueño o se lo compartieron? ──▶ AccessManager
                                          └─ red interna ──▶ Runner, asset-service, bases, Redis
```

- **La autenticación está delegada en Auth0:** el proyecto nunca ve ni guarda contraseñas.
- **App es la única puerta de entrada a la API.** Runner y AccessManager solo se alcanzan desde la red interna.
- **Cada request a `/api/` necesita un token válido**, y cada acción sobre un snippet chequea el permiso del usuario.

---

## 2. Autenticación (¿quién sos?)

| Parte | Cómo se hace | Dónde |
| :--- | :--- | :--- |
| Login | Auth0, con Authorization Code + PKCE (`@auth0/auth0-react`) | `printscript-ui/src/main.tsx` |
| Token | JWT firmado por el tenant de Auth0, con `aud = https://api.snippets.com` | Auth0 |
| Envío | `Authorization: Bearer <token>` en cada request | `printscript-ui/src/services/api.ts` |
| Validación | Spring Security como *resource server*: firma (claves públicas de Auth0), `iss`, `exp` y `aud` | `SnippetSearcher-App`: `application.yml` (`issuer-uri`, `audiences`) y `config/SecurityConfig.kt` |

**Sin token o con un token inválido, App responde `401`.** Un token emitido por el mismo tenant para otra API se
rechaza por `aud`.

---

## 3. Autorización (¿qué podés hacer?)

**Modelo: ACL por snippet**, guardada en AccessManager. Cada snippet tiene un dueño (`owner`) y una lista de
usuarios con quienes se compartió (`shared`). App lo consulta antes de cada acción y responde **`403`** si no alcanza.

| Acción | Quién puede | Endpoint |
| :--- | :--- | :--- |
| Ver la lista de sus snippets | Cualquier usuario logueado (ve solo los suyos y los compartidos) | `GET /api/v1/snippets` |
| Leer un snippet (metadatos y código) | Dueño o compartido | `GET /api/v1/snippets/{id}` |
| Crear un snippet | Cualquier usuario logueado. **El dueño es siempre el usuario del token**: el `userId` del body se ignora | `PUT /api/v1/snippets/{id}` |
| Editar el código, la descripción o la versión | Solo el dueño | `PATCH /api/v1/snippets/{id}` |
| Borrar | Solo el dueño | `DELETE /api/v1/snippets/{id}` |
| Compartir o quitar acceso | Solo el dueño | `POST` / `DELETE .../permissions` |
| Ejecutar, lintear, ver tests, descargar | Dueño o compartido | `.../executions`, `.../tasks/lint`, `.../tests`, `.../download` |
| Formatear (guarda el resultado) | Solo el dueño | `.../tasks/format` |

**Scopes:** no se usan. La API tiene un único cliente propio (la UI), y lo que importa es el permiso sobre cada
snippet, que un scope no puede expresar. Para sumarlos, ver la [sección 8](#8-pendientes).

---

## 4. Qué está expuesto a internet

Solo nginx tiene puertos públicos (80 y 443):

| Ruta pública | Destino | Requiere token |
| :--- | :--- | :--- |
| `/` | UI (archivos estáticos) | No |
| `/api/actuator/health` | Chequeo de salud de App (solo `UP` o `DOWN`) | No |
| `/api/...` | App | Sí |

**Runner y AccessManager no son accesibles desde internet.** Antes nginx los publicaba en `/runner/` y `/access/`,
sin autenticación: cualquiera podía leer, editar o borrar snippets ajenos o cambiar permisos. Ahora la UI hace todo
a través de App, que valida el token y el permiso, y App le pide a Runner lo que corresponda por la red interna.

**Llamadas entre servicios:** van por la red interna de Swarm, sin token. La única ruta de App para eso es
`PUT /internal/snippets/{id}`, con la que Runner registra un snippet después de guardar su código. nginx no la
publica (solo reenvía `/api/`). Todo lo que App no conoce responde `403`.

```
Crear un snippet:
UI ──PUT /api/v1/snippets/{id}──▶ App (dueño = token) ──PUT──▶ Runner (valida y guarda el código)
                                                                  └─PUT /internal/snippets/{id}──▶ App (metadatos y permiso owner)
Editar el código:
UI ──PATCH /api/v1/snippets/{id}──▶ App (solo dueño) ──PATCH──▶ Runner (valida, guarda, pide linteo y tests con el token del usuario)
```

---

## 5. Secretos

| Secreto | Dónde vive | Notas |
| :--- | :--- | :--- |
| Contraseñas de las bases | Variables de entorno en `docker-stack.yml` | Siguen en texto plano en el stack. Ver pendientes |
| License key de New Relic | Secret `NEW_RELIC_LICENSE_KEY` de los environments de GitHub | `deploy.yml` la pasa al stack y al agente de infraestructura. Ya no está en `newrelic.yml` |
| Credenciales de Auth0 de App | **No hay**: App solo valida tokens | El `clientSecret` que estaba en `application.yml` se borró |
| Credenciales de la UI (`VITE_AUTH0_*`) | Secrets del repo de la UI | Son públicas por naturaleza: van en el bundle del navegador |

**Las claves que estuvieron en el repo hay que rotarlas**, aunque ya no estén en el código: siguen en el historial
de Git. Ver la [sección 8](#8-pendientes).

**Logs:** no se loguean tokens ni contraseñas. Los logs de cambios de estado registran el id del usuario (`sub` de
Auth0), no su token.

---

## 6. Cómo comprobarlo

```bash
DOM=https://snippet26dev.duckdns.org

# Sin token: 401
curl -s -o /dev/null -w "%{http_code}\n" $DOM/api/v1/snippets

# Runner y AccessManager ya no están publicados: nginx los manda a la UI (200 con el HTML de la SPA)
curl -s $DOM/runner/api/v1/snippets/x | head -c 60
curl -s $DOM/access/permissions | head -c 60

# La ruta interna de App tampoco está publicada (solo /api/ llega a App)
curl -s -o /dev/null -w "%{http_code}\n" -X PUT $DOM/internal/snippets/x

# Health check público: {"status":"UP"}
curl -s $DOM/api/actuator/health
```

Con dos usuarios: el usuario B pide `GET /api/v1/snippets/{id}` de un snippet de A que no le compartieron y recibe
**`403`**. Después de compartirlo, recibe `200`.

Los tests de App fijan estas reglas: `SecurityConfigTest`, `SnippetControllerTest` (lectura sin permiso, alta con el
dueño del token, edición solo del dueño) e `InternalSnippetControllerTest`.

---

## 7. Qué plantea la clase y cómo se cumple

| Concepto | Estado | Cómo |
| :--- | :--- | :--- |
| Delegar la autenticación | ✅ | Auth0 |
| Authorization Code + PKCE en la SPA | ✅ | `@auth0/auth0-react` |
| Tokens *stateless* con `Authorization: Bearer` | ✅ | JWT de Auth0 |
| Validar firma, `iss`, `exp` y `aud` | ✅ | `issuer-uri` y `audiences` en App |
| Validar el token en cada servicio expuesto | ✅ | El único servicio expuesto es App. Runner y AccessManager son internos |
| `401` sin identidad, `403` sin permiso | ✅ | Spring Security y los chequeos de App |
| Autorización de dominio (dueño o compartido) | ✅ | ACL en AccessManager |
| Chequear scopes | ⚠️ | No se usan; justificado en la sección 3 |
| No guardar secretos en el código | ⚠️ | Se sacaron del código; falta rotarlos y sacar las contraseñas de las bases del stack |
| Token fuera de `localStorage` (XSS) | ⚠️ | La UI usa `cacheLocation="localstorage"` (ver pendientes) |

---

## 8. Pendientes

1. **Rotar el `clientSecret` de Auth0** de la aplicación cuyo `clientId` estaba en `application.yml` (Auth0 →
   Applications → la aplicación → Credentials → Rotate). App no lo usa, así que no hay que configurarlo en ningún lado.
2. **Rotar la license key de New Relic** (New Relic → API Keys) y actualizar el secret `NEW_RELIC_LICENSE_KEY` en
   los environments `develop` y `production` de Infra.
3. **Contraseñas de las bases fuera del stack:** pasarlas a secrets de GitHub o de Swarm (ver `VM_LIMPIA.md`).
4. **Token en memoria:** cambiar `cacheLocation` a `memory` reduce el riesgo ante XSS, pero obliga a renovar la
   sesión al recargar la página, y eso falla en navegadores que bloquean cookies de terceros. Se dejó
   `localstorage` con *refresh tokens* rotativos como compromiso.
5. **Scopes (opcional):** en Auth0, activar *RBAC* y *Add Permissions in the Access Token* en la API, crear permisos
   como `read:snippets` y `write:snippets`, pedirlos desde la UI y exigirlos en `SecurityConfig.kt` con
   `hasAuthority("SCOPE_read:snippets")`. Hay que hacerlo todo junto: si App los exige antes de que Auth0 los
   emita, todas las requests dan `403`.
