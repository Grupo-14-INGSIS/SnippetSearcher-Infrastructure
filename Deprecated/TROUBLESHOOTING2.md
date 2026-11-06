# Guía de Troubleshooting 2: New Relic, Ambientes y Despliegues (SnippetSearcher)

Este documento recopila todas las consultas, diagnósticos, causas raíces y soluciones técnicas trabajadas en relación con **New Relic**, la separación de métricas entre **Develop y Producción**, el **ciclo de actualización de contenedores en VMs**, y la **coexistencia de Localhost con DuckDNS / Reverse Proxy**.

---

## Índice
1. [Diagnóstico de New Relic en los Repositorios](#1-diagnóstico-de-new-relic-en-los-repositorios)
2. [Problema: Queries de New Relic en Develop vs Producción (`_dev` vs limpio)](#2-problema-queries-de-new-relic-en-develop-vs-producción)
3. [Solución: Cómo separar las métricas entre Develop y Producción](#3-solución-cómo-separar-las-métricas-entre-develop-y-producción)
4. [¿Por qué no hace falta cambiar ni pushear cada repositorio Java?](#4-por-qué-no-hace-falta-cambiar-ni-pushear-cada-repositorio-java)
5. [Contenedores corriendo imágenes viejas en la VM](#5-contenedores-corriendo-imágenes-viejas-en-la-vm)
6. [Coexistencia de Localhost y Dominio DuckDNS (VM)](#6-coexistencia-de-localhost-y-dominio-duckdns-vm)

---

## 1. Diagnóstico de New Relic en los Repositorios

### Pregunta
> *¿Hay algo configurado en los repos de New Relic?*

### Estado y Hallazgos
Se detectó que **New Relic** está integrado en los tres microservicios Java/Kotlin (`SnippetSearcher-App`, `SnippetSearcher-Runner` y `SnippetSearcher-AccessManager`):

1. **Dependencia API:**
   * `implementation 'com.newrelic.agent.java:newrelic-api:8.7.0'` en los archivos `build.gradle`.
2. **Artefactos del Agente:**
   * Directorios `newrelic/` que contienen `newrelic.jar` y `newrelic.yml`.
3. **Invocación en Dockerfile:**
   * Los Dockerfiles ejecutan la JVM con el agente:
     ```dockerfile
     ENTRYPOINT ["java", "-javaagent:/usr/local/newrelic/newrelic.jar", "-jar", "/app/app.jar"]
     ```
4. **Instrumentación de Código:**
   * Clases `RequestIdFilter.kt` que registran el atributo personalizado en New Relic:
     ```kotlin
     NewRelic.addCustomParameter("request_id", requestId)
     ```

---

## 2. Problema: Queries de New Relic en Develop vs Producción

### Consulta del Usuario
> *Esta query funciona:*
> ```sql
> SELECT rate(count(*), 1 minute) 
> FROM Transaction 
> WHERE appName = 'AppIngsis_dev'
> TIMESERIES
> ```
> *La siguiente no devuelve nada:*
> ```sql
> SELECT rate(count(*), 1 minute) 
> FROM Transaction 
> WHERE appName = 'AppIngsis'
> TIMESERIES SINCE 60 minutes ago UNTIL now
> ```
> *¿Por qué el dashboard de develop funciona y producción no registra nada?*

### Causa Raíz
1. En los archivos `newrelic.yml` de los 3 microservicios, la propiedad `app_name` venía configurada por defecto con el sufijo `_dev`:
   * `AppIngsis_dev`
   * `RunnerIngsis_dev`
   * `AccessManagerIngsis_dev`
2. En `docker-compose.yml` no se le estaba pasando ninguna variable para sobreescribir el nombre.
3. **Consecuencia:** Tanto la instancia de Develop como la de Producción estaban enviando sus métricas a New Relic bajo el mismo nombre (`*_dev`). La query con `appName = 'AppIngsis'` fallaba porque ningún servicio se había registrado con ese nombre sin sufijo.

---

## 3. Solución: Cómo separar las métricas entre Develop y Producción

### Paso 1: Configurar variables con fallback en `docker-compose.yml`
En [`SnippetSearcher-Infrastructure/docker-compose.yml`](docker-compose.yml), agregar la variable `NEW_RELIC_APP_NAME` en la sección `environment` de cada servicio:

```yaml
  # 1. App
  snippetsearcher-app:
    environment:
      NEW_RELIC_APP_NAME: ${NEW_RELIC_APP_NAME_APP:-AppIngsis_dev}
      JAVA_TOOL_OPTIONS: "-Djava.net.preferIPv4Stack=true"
      DB_USER: app
      # ... demás variables

  # 2. Runner
  snippetsearcher-runner:
    environment:
      NEW_RELIC_APP_NAME: ${NEW_RELIC_APP_NAME_RUNNER:-RunnerIngsis_dev}
      DB_USER: app
      # ... demás variables

  # 3. AccessManager
  snippetsearcher-accessmanager:
    environment:
      NEW_RELIC_APP_NAME: ${NEW_RELIC_APP_NAME_ACCESS:-AccessManagerIngsis_dev}
      DB_USER: access_manager
      # ... demás variables
```

### Paso 2: Configurar el archivo `.env` en cada Servidor/VM

#### En la VM de **Producción** (`.env`):
```env
NEW_RELIC_APP_NAME_APP=AppIngsis
NEW_RELIC_APP_NAME_RUNNER=RunnerIngsis
NEW_RELIC_APP_NAME_ACCESS=AccessManagerIngsis
```

#### En la VM de **Develop** (`.env`):
```env
NEW_RELIC_APP_NAME_APP=AppIngsis_dev
NEW_RELIC_APP_NAME_RUNNER=RunnerIngsis_dev
NEW_RELIC_APP_NAME_ACCESS=AccessManagerIngsis_dev
```

### Paso 3: Reiniciar los contenedores
En la VM correspondiente:
```bash
sudo docker compose up -d --force-recreate snippetsearcher-app snippetsearcher-runner snippetsearcher-accessmanager
```

---

## 4. ¿Por qué no hace falta cambiar ni pushear cada repositorio Java?

### Pregunta
> *¿Para que impacte tengo que pushear los cambios en cada servicio o repo? ¿No era en cada repo eso?*

### Explicación
**No es necesario tocar ni pushear los repositorios Java (`App`, `Runner`, `AccessManager`).**

New Relic resuelve sus configuraciones con el siguiente orden de **prioridad**:

```text
1. Variable de Entorno de Docker (NEW_RELIC_APP_NAME)  --> [MÁXIMA PRIORIDAD]
2. Propiedad del sistema Java (-Dnewrelic.config.app_name)
3. Archivo newrelic.yml dentro del JAR               --> [FALLBACK / MENOR PRIORIDAD]
```

* Al definir `NEW_RELIC_APP_NAME` en `docker-compose.yml`, el agente de New Relic toma ese valor en tiempo de ejecución y descarta el `app_name` del `newrelic.yml`.
* **Ventaja:** La misma imagen Docker ya compilada sirve para todos los entornos. Solo se versiona la configuración en `SnippetSearcher-Infrastructure`.

---

## 5. Contenedores corriendo imágenes viejas en la VM

### Pregunta
> *Veo que los contenedores están corriendo cosas viejas. ¿Cómo se actualizan?*

### Causa
Docker Compose no descarga automáticamente nuevas imágenes de GitHub Container Registry (`ghcr.io`) al ejecutar `docker compose up` si ya existe una imagen previa con el mismo tag (`:develop` o `:main`) en la caché local de la VM.

### Solución
Ejecutar el ciclo completo de actualización en la VM:

```bash
# 1. Traer últimos cambios de infraestructura
cd ~/SnippetSearcher-Infrastructure
git pull

# 2. Descargar las últimas imágenes compiladas por el CI/CD desde GHCR
sudo docker compose pull

# 3. Forzar recreación de contenedores
sudo docker compose up -d --force-recreate

# 4. Eliminar imágenes huérfanas y liberar espacio
sudo docker image prune -f
```

---

## 6. Coexistencia de Localhost y Dominio DuckDNS (VM)

### Pregunta
> *¿Por qué hoy por hoy funciona tanto en localhost como en la UI en DuckDNS?*

### Arquitectura Dual

La configuración de [`docker-compose.yml`](docker-compose.yml) cuenta con **dos capas de acceso en paralelo**:

```text
               +---------------------------------------------+
               |  Acceso en la VM (DuckDNS con SSL)          |
               |  https://snippet26dev.duckdns.org           |
               +---------------------------------------------+
                                     |
                                     v
                       +---------------------------+
                       | NGINX Reverse Proxy (80/443)|
                       +---------------------------+
                        /            |             \
          (location /) /  (location /api/)          \ (location /runner/)
                      v              v               v
            +----------------+ +----------------+ +--------------------+
            | UI (:80)       | | App (:8080)    | | Runner (:8080)     |
            +----------------+ +----------------+ +--------------------+
                      ^              ^               ^
                      |              |               |
          (puerto 5173)    (puerto 19081)    (puerto 19082)
                      +--------------+---------------+
                                     |
               +---------------------------------------------+
               |  Acceso en Local (Host Port Mapping)        |
               |  http://localhost:5173                      |
               +---------------------------------------------+
```

### Elementos clave que lo hacen posible:
1. **Nginx Reverse Proxy (`ports: 80:80, 443:443`):** Gestiona los certificados SSL y rutea el tráfico de dominio por prefijos de path (`/`, `/api/`, `/runner/`) dentro de la red interna de Docker.
2. **Mapeo directo de puertos de desarrollo (`19081`, `19082`, `19083`, `5173`):** Permite conectarse directamente a cada servicio desde una máquina local mediante `localhost`.
3. **Variables de Frontend con Fallback:**
   ```yaml
   snippetsearcher-ui:
     environment:
       - VITE_FRONTEND_URL=${VITE_FRONTEND_URL:-http://localhost:5173}
       - VITE_API_URL=${VITE_API_URL:-http://localhost:19081}
       - VITE_BACKEND_URL=${VITE_BACKEND_URL:-http://localhost:19081}
       - VITE_RUNNER_URL=${VITE_RUNNER_URL:-http://localhost:19082}
   ```
   * En **Local:** Toma los puertos de localhost por defecto.
   * En la **VM:** Se sobreescriben en el `.env` con las URLs públicas del dominio DuckDNS (`https://...`).
