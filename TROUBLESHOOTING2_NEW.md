# Guía de Diagnóstico 2: New Relic, Ambientes y Puertos (SnippetSearcher)

> Este documento trata la configuración del agente y los nombres por ambiente. Para todo lo que se monitorea en New Relic
> (alertas, Synthetics, dashboards, consultas y cómo seguir un request), ver [Documentación/NEW_RELIC.md](Documentación/NEW_RELIC.md).
> El Runner de producción reporta como `runnerIngsis`, con minúscula.

Este documento detalla la integración de **New Relic**, la separación de métricas entre **Develop y Producción**, cómo se propagan las variables en **Docker Swarm vs Local**, y la **coexistencia de Localhost con el Reverse Proxy**.

---

## Índice
1. [Integración de New Relic en los Microservicios](#1-integración-de-new-relic-en-los-microservicios)
2. [Separación de Métricas: Develop vs Producción](#2-separación-de-métricas-develop-vs-producción)
3. [Prioridad de Configuración en Spring Boot / New Relic](#3-prioridad-de-configuración-en-spring-boot--new-relic)
4. [Coexistencia: Localhost vs DuckDNS / VMs](#4-coexistencia-localhost-vs-duckdns--vms)

---

## 1. Integración de New Relic en los Microservicios

New Relic está instrumentado en los tres microservicios Kotlin (`SnippetSearcher-App`, `SnippetSearcher-Runner` y `SnippetSearcher-AccessManager`):

1. **Dependencia API:**
   `implementation 'com.newrelic.agent.java:newrelic-api:8.7.0'` en `build.gradle`.
2. **Artefactos del Agente:**
   Directorio `newrelic/` en cada repositorio con `newrelic.jar` y `newrelic.yml`.
3. **Invocación en el Dockerfile:**
   Los contenedores arrancan la JVM vinculando el agente:
   ```dockerfile
   ENTRYPOINT ["java", "-javaagent:/usr/local/newrelic/newrelic.jar", "-jar", "/app/app.jar"]
   ```
4. **Trazabilidad por Request ID:**
   El filtro `RequestIdFilter.kt` asocia el identificador de correlación HTTP a la transacción de New Relic:
   ```kotlin
   NewRelic.addCustomParameter("request_id", requestId)
   ```

---

## 2. Separación de Métricas: Develop vs Producción

### El Problema Histórico
Por defecto, los archivos `newrelic.yml` de los repositorios traían el nombre de aplicación hardcodeado con sufijo `_dev` (`AppIngsis_dev`, `RunnerIngsis_dev`, etc.).
Si no se sobreescribe el nombre en runtime, tanto la instancia de Develop como la de Producción reportan bajo la misma etiqueta, mezclando datos y dejando las consultas de producción (`appName = 'AppIngsis'`) vacías.

### Solución en la Arquitectura Actual

#### En Docker Swarm (Servidores Azure Dev y Prod)
En Swarm no se utilizan archivos `.env` en las VMs. Las variables se definen como **Environment Variables de GitHub** (`Settings` → `Environments` → `develop` / `production`):

* **En el Environment `develop` de GitHub:**
  * `NEW_RELIC_APP_NAME_APP` = `AppIngsis_dev`
  * `NEW_RELIC_APP_NAME_RUNNER` = `RunnerIngsis_dev`
  * `NEW_RELIC_APP_NAME_ACCESS` = `AccessManagerIngsis_dev`

* **En el Environment `production` de GitHub:**
  * `NEW_RELIC_APP_NAME_APP` = `AppIngsis`
  * `NEW_RELIC_APP_NAME_RUNNER` = `RunnerIngsis`
  * `NEW_RELIC_APP_NAME_ACCESS` = `AccessManagerIngsis`

El workflow [`.github/workflows/deploy.yml`](file:///.github/workflows/deploy.yml) inyecta estos valores en tiempo de despliegue en las variables de entorno de cada servicio en `docker-stack.yml`:

```yaml
  snippetsearcher-app:
    environment:
      NEW_RELIC_APP_NAME: ${NEW_RELIC_APP_NAME_APP:-AppIngsis_dev}
```

#### En Desarrollo Local (Docker Compose)
En `docker-compose.yml`, los servicios cuentan con el fallback `${NEW_RELIC_APP_NAME_APP:-AppIngsis_dev}`, por lo que en local reportan automáticamente con sufijo `_dev` sin requerir configuración adicional.

---

## 3. Prioridad de Configuración en Spring Boot / New Relic

El agente de New Relic resuelve sus configuraciones con el siguiente orden de precedencia:

```text
1. Variable de Entorno del Contenedor (NEW_RELIC_APP_NAME)  --> [MÁXIMA PRIORIDAD]
2. Propiedad del sistema Java (-Dnewrelic.config.app_name)
3. Archivo newrelic.yml empaquetado en la imagen            --> [FALLBACK / MENOR PRIORIDAD]
```

Gracias a esto:
* **Una única imagen Docker inmutable** sirve para local, desarrollo y producción.
* No se requiere recompilar ni pushear los repositorios Java para cambiar los entornos de telemetría.

---

## 4. Coexistencia: Localhost vs DuckDNS / VMs

El repositorio de infraestructura mantiene dos modelos de acceso claros y diferenciados:

```text
                 [ ACCESO PÚBLICO EN LA VM ]
                 https://snippet26<env>.duckdns.org (443 SSL)
                               |
                               v
                 +---------------------------+
                 | Nginx Reverse Proxy (80/443)|
                 +---------------------------+
                   /          |             \
     (location /) / (location /api/)         \ (red interna, solo App)
                 v            v               v
               +----+      +-----+         +------+
               | UI |      | App |         |Runner|
               +----+      +-----+         +------+
                 ^            ^               ^
                 |            |               |
                 +------------+---------------+
                               |
                 [ ACCESO EN DESARROLLO LOCAL ]
                 http://localhost:5173  (UI)
                 http://localhost:19081 (App)
                 http://localhost:19082 (Runner)
```

1. **En las VMs (Docker Swarm - `docker-stack.yml`):**
   * **Puertos internos cerrados:** Por seguridad, se eliminaron los mapeos de puertos directos (`19081-19084`, `5173`).
   * **Entrada perimetral única:** Todo el tráfico pasa obligatoriamente por Nginx en los puertos `80` y `443` con terminación SSL.
   * La UI web se comunica con `/api` y `/runner` en el mismo origen (`window.location.origin`), eliminando la necesidad de CORS en la nube.
2. **En Local (Docker Compose - `docker-compose.yml`):**
   * Los puertos de desarrollo están mapeados directamente al host para permitir depuración directa con Postman, `curl`, o Cypress local.
