# Extras agregados en noviembre de 2026

Este archivo junta **solo lo que se sumó o cambió en esta tanda de trabajo**. Para el detalle de cada tema, seguí el
link de la última columna.

## Índice
- [1. Cambios de arquitectura y comportamiento](#1-cambios-de-arquitectura-y-comportamiento)
- [2. Seguridad](#2-seguridad)
- [3. CI/CD y deploy](#3-cicd-y-deploy)
- [4. Observabilidad (New Relic)](#4-observabilidad-new-relic)
- [5. Tests de carga](#5-tests-de-carga)
- [6. Documentación nueva o actualizada](#6-documentación-nueva-o-actualizada)
- [7. Decisiones tomadas](#7-decisiones-tomadas)
- [8. Qué queda por hacer](#8-qué-queda-por-hacer)

---

## 1. Cambios de arquitectura y comportamiento

**Sí, cambiaron.** Lo más importante: **la UI ahora habla solo con App.**

```
ANTES                                         AHORA
UI ──/api/────▶ App                           UI ──/api/──▶ App ──▶ Runner
UI ──/runner/─▶ Runner      (sin token)                         └──▶ AccessManager
UI ──/access/─▶ AccessManager (sin token)     Runner ──/internal/──▶ App   (red interna)
```

| Cambio | Antes | Ahora | Detalle |
| :--- | :--- | :--- | :--- |
| Rutas públicas de nginx | `/`, `/api/`, `/runner/`, `/access/` | Solo `/` y `/api/` | [SEGURIDAD.md](SEGURIDAD.md) |
| Crear un snippet | La UI llamaba al Runner directo | `PUT /api/v1/snippets/{id}` con `content`. App lo pasa al Runner, y el Runner lo registra en App por `/internal/snippets/{id}` | [CASOS_DE_USO_RECORRIDO.md](CASOS_DE_USO_RECORRIDO.md) |
| Editar el código | La UI llamaba al Runner directo | `PATCH /api/v1/snippets/{id}` con `content`. Solo el dueño | [RUTAS_REST.md](RUTAS_REST.md) |
| Dueño de un snippet | Venía en el body (`userId`) | Sale del token (`sub`). El `userId` del body se ignora | [SEGURIDAD.md](SEGURIDAD.md) |
| `GET /api/v1/snippets/{id}` | Sin control de permiso | Requiere token y ser dueño o compartido (si no, `403`) | [SEGURIDAD.md](SEGURIDAD.md) |
| Rutas no declaradas de App | Sin regla explícita | `403` (`denyAll`). Solo se permiten `/api/**` con token, `/internal/**` y el health | [SEGURIDAD.md](SEGURIDAD.md) |
| Health check | No había | `/api/actuator/health`: App, su base, Redis, Runner y AccessManager. Responde solo `UP` o `DOWN` | [NEW_RELIC.md](NEW_RELIC.md) |
| Timeout de `/api/` en nginx | 300 s | 600 s (guardar un snippet corre sus tests) | [HTTPS_NGINX_CORS_NEW.md](HTTPS_NGINX_CORS_NEW.md) |

Los cambios de código están en App (`SecurityConfig`, `SnippetController`, `InternalSnippetController` nuevo,
`RunnerClient`), Runner (`AppClient` usa `/internal`), y la UI (`api.ts` y `queries.tsx` van todo por App).

## 2. Seguridad

- App valida también el **`aud`** del token (`https://api.snippets.com`), además de firma, `iss` y `exp`.
- Se sacó el **`clientSecret` de Auth0** de `application.yml` (App no lo usaba).
- La **license key de New Relic** salió de `newrelic.yml`: llega por la variable `NEW_RELIC_LICENSE_KEY`, desde el
  secret de los environments de GitHub de Infra.
- Documento nuevo: [SEGURIDAD.md](SEGURIDAD.md), que cubre autenticación, autorización, superficie expuesta, secretos y cómo probarlo.

## 3. CI/CD y deploy

| Extra | Qué resuelve | Detalle |
| :--- | :--- | :--- |
| `update-infra` en cada servicio | Cada push a `develop` o `production` escribe la versión de la imagen en el stack de Infra (`develop` o `main`) | [PIPELINE_CI_CD.md](PIPELINE_CI_CD.md) |
| Redeploy forzado solo con commit humano en Infra | Un commit de una persona en Infra reinicia los 4 microservicios; los commits automáticos de los servicios, no | [PIPELINE_CI_CD.md](PIPELINE_CI_CD.md) |
| `concurrency` y reintentos | Si llegan varios pushes juntos, no se pisan: los intermedios quedan `cancelled` y el último aplica el stack completo | [PIPELINE_CI_CD.md](PIPELINE_CI_CD.md) |
| Verificación antes del `prune` | No se borran imágenes viejas hasta comprobar que los servicios nuevos levantaron | [PIPELINE_CI_CD.md](PIPELINE_CI_CD.md) |
| Contenedor `newrelic-infra` | Métricas de la VM y de los contenedores sin instalar nada en la VM | [NEW_RELIC.md](NEW_RELIC.md) |
| `develop` y `main` de Infra iguales | Solo difieren en las 4 líneas `image:` | [PIPELINE_CI_CD.md](PIPELINE_CI_CD.md) |

## 4. Observabilidad (New Relic)

| Pilar | Qué se agregó |
| :--- | :--- |
| **Trazas** | Agente Java en App, Runner y AccessManager, con trazas distribuidas entre ellos |
| **Métricas** | Eventos propios `SnippetsListed` (cuántos snippets ve cada usuario) y `RedisStreamStatus` (trabajos encolados y pendientes, cada 60 s). Métricas de VM y contenedores por `newrelic-infra` |
| **Synthetics** | Monitores *ping* de la página y del health check, en dev y prod |
| **Logs** | Logs de App, Runner y AccessManager en New Relic, con `requestId` (MDC) para seguir un request entre servicios. Logs de cambios de estado (alta, edición, borrado, compartir) |
| **Dashboards** | Dashboards separados de dev y prod, con APM, infraestructura, contenedores y eventos de negocio |
| **Alertas** | Políticas limpias, sin duplicados, y monitores nuevos para servicio caído y VM sin datos |
| **SLI/SLO** | Definidos: 99 % de requests sin error en 28 días |

Todo está explicado en [NEW_RELIC.md](NEW_RELIC.md).

## 5. Tests de carga

- `load-tests/locustfile.py`, con dos tipos de usuario: `HealthUser` (sin token) y `ApiUser` (lectura con token).
- Guía nueva: [LOCUST.md](LOCUST.md), que explica qué hace, cómo correrlo, qué mirar y qué alerta se dispara.

## 6. Documentación nueva o actualizada

| Archivo | Estado |
| :--- | :--- |
| [SEGURIDAD.md](SEGURIDAD.md) | Nuevo |
| [NEW_RELIC.md](NEW_RELIC.md) | Nuevo y ampliado (limitaciones, SLO, comparación con la clase) |
| [LOCUST.md](LOCUST.md) | Nuevo |
| [BASE_DE_DATOS.md](BASE_DE_DATOS.md) | Nuevo: tablas, columnas y cómo interactúan |
| Este archivo | Nuevo |
| `RUTAS_REST.md`, `CASOS_DE_USO_RECORRIDO.md`, `USO_DE_BUCKETS.md`, `HTTPS_NGINX_CORS_NEW.md`, `ARQUITECTURA_NEW.md`, `FLUJO_Y_COMPARATIVA_ARQUITECTURA_NEW.md`, `PIPELINE_CI_CD.md`, `AUTH0.md`, `TROUBLESHOOTING2_NEW.md` y `README.md` (estos dos en la raíz) | Actualizados a lo que hace el sistema hoy |

## 7. Decisiones tomadas

| Decisión | Por qué |
| :--- | :--- |
| **No rotar** el `clientSecret` de Auth0 ni la license key de New Relic | Es un TP con cuentas de prueba. Siguen en el historial de Git: riesgo aceptado |
| No prender ni apagar la VM automáticamente desde las Actions | Más contras que ventajas: credenciales de la nube en GitHub, demoras y riesgo de dejarla prendida |
| `Excessive response time` en 0,3 s | Para que se dispare rápido en la demo. Después conviene subirlo a unos 2 s |
| Sin scopes en el token | Lo que importa es el permiso por snippet, que un scope no expresa |
| Token en `localStorage` | Con `memory`, la sesión se pierde al recargar en navegadores que bloquean cookies de terceros |
| No separar los workflows de CI y CD | Dividirlos sumaba más complejidad que beneficio |

## 8. Qué queda por hacer

- Crear en New Relic las alertas de Redis, listas vacías y latencia p95, y el SLO (ver [NEW_RELIC.md](NEW_RELIC.md), secciones 9 y 14).
- Synthetic del flujo de negocio (crear, leer y borrar un snippet).
- Logs de nginx, asset-service, bases y Redis.
- Contraseñas de las bases fuera del stack.
