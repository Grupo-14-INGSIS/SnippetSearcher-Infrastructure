# Documentación de Dockerización y Orquestación

Este documento detalla la estrategia de contenedorización y orquestación del sistema SnippetSearcher, demostrando cómo cumple con la premisa: **"Dockerizar todos los servicios y las bases de datos, cada uno con su Dockerfile, y levantar el sistema entero con un docker-compose.yml (en local) y docker-stack.yml (en Swarm)"**.

---

## 1. Resumen Ejecutivo del Cumplimiento

| Componente | Tipo | Estrategia Docker / Imagen Base | Rol en la Arquitectura |
| :--- | :--- | :--- | :--- |
| **SnippetSearcher-App** | Microservicio Backend | `Dockerfile` propio (Multi-stage: Gradle 8.14 JDK 21 $\rightarrow$ Temurin 21 JRE) | Core de negocio y BFF |
| **SnippetSearcher-Runner** | Microservicio Backend | `Dockerfile` propio (Multi-stage: Gradle 8.14 JDK 21 $\rightarrow$ Temurin 21 JRE) | Motor de ejecución (PrintScript, etc.) |
| **SnippetSearcher-AccessManager** | Microservicio Backend | `Dockerfile` propio (Multi-stage: Gradle 8.14 JDK 21 $\rightarrow$ Temurin 21 JRE) | Autorización y gestión de permisos |
| **printscript-ui** | Frontend SPA | `Dockerfile` propio (Multi-stage: Node 20 Alpine $\rightarrow$ Nginx Stable Alpine) | Interfaz gráfica de usuario |
| **appdb** | Base de Datos | `postgres:16` + script init SQL | Persistencia de snippets (compliant boolean) |
| **runner-db** | Base de Datos | `postgres:16` + Hibernate ddl-auto | Persistencia de reglas y ejecuciones |
| **accessmanager-db** | Base de Datos | `postgres:16` + script init SQL | Persistencia de permisos y relaciones de usuarios |
| **redis** | Message Queue | `redis:7` | Cola de tareas asíncronas (Streams: jobs y results) |
| **asset-service** | Microservicio Assets | `ghcr.io/austral-ingsis/snippet-asset-service` | API de gestión de archivos binarios/código |
| **azurite** | Object Storage Emulator | `mcr.microsoft.com/azure-storage/azurite` | Emulador de Azure Blob Storage |
| **reverse-proxy** | Edge Proxy / Gateway | `nginx:stable-alpine` + template dinámico | Punto único de entrada HTTP/HTTPS y ruteo |
| **certbot** | Gestor SSL (Swarm) | `certbot/certbot:v2.11.0` | Renovación periódica en modo webroot |

---

## 2. Detalle de Dockerfiles por Microservicio

Todos los servicios implementan el patrón **Multi-Stage Build**, lo cual garantiza:
1. **Seguridad y tamaño mínimo**: Las herramientas de compilación (Gradle, NPM, compiladores) no viajan a la imagen de producción final.
2. **Caché de capas**: Las dependencias no se descargan de nuevo salvo que cambien `build.gradle.kts` o `package.json`.

```
          [ STAGE 1: BUILD ]                        [ STAGE 2: RUNTIME ]
  +--------------------------------+       +------------------------------------+
  | Código fuente + SDK / Gradle   | ----> | JRE / Nginx Mínimo                |
  | Generación de JAR / Bundle     |       | Artefacto final + Agente Monitoreo |
  +--------------------------------+       +------------------------------------+
```

---

### A. `SnippetSearcher-App`
- **Fase 1 (Build)**:
  - Base: `gradle:8.14-jdk21 AS build`
  - Ejecuta: `gradle bootJar -x test` para empaquetar el ejecutable de Spring Boot.
- **Fase 2 (Runtime)**:
  - Base: `eclipse-temurin:21-jre` (solo el runtime de Java, ligero y seguro).
  - Incluye el agente APM de New Relic: `newrelic/newrelic.jar` y su configuración `newrelic.yml`.
  - Expone el puerto `8080`.
  - Entrypoint: `["java", "-javaagent:/usr/local/newrelic/newrelic.jar", "-jar", "app.jar"]`.

---

### B. `SnippetSearcher-Runner`
- **Fase 1 (Build)**:
  - Base: `gradle:8.14-jdk21 AS build`
  - Parámetros de compilación: Acepta `GITHUB_USER` y `GITHUB_TOKEN` como build arguments (`ARG`) para resolver librerías publicadas en GitHub Packages (PrintScript tools, linter, formateador).
  - Ejecuta: `gradle bootJar -x test -PgithubUsername=${GITHUB_USERNAME} -PgithubToken=${GITHUB_TOKEN}`.
- **Fase 2 (Runtime)**:
  - Base: `eclipse-temurin:21-jre`.
  - Copia el JAR generado.
  - Integra el agente APM New Relic.
  - Expone el puerto `8080`.

---

### C. `SnippetSearcher-AccessManager`
- **Fase 1 (Build)**:
  - Base: `gradle:8.14-jdk21 AS build`
  - Ejecuta: `gradle bootJar -x test`.
- **Fase 2 (Runtime)**:
  - Base: `eclipse-temurin:21-jre`.
  - Copia el JAR generado.
  - Integra New Relic para observabilidad de llamadas de autorización.
  - Expone el puerto `8080`.

---

### D. `printscript-ui`
- **Fase 1 (Build)**:
  - Base: `node:20-alpine AS builder`
  - Entorno de compilación: Inyecta variables de Auth0 y URLs de backend mediante `ARG` (`VITE_AUTH0_DOMAIN`, `VITE_API_URL`, etc.).
  - Ejecuta: `npm ci` y `npm run build` produciendo el bundle de producción en `/app/dist`.
- **Fase 2 (Runtime)**:
  - Base: `nginx:stable-alpine`
  - Copia los estáticos compilados a `/usr/share/nginx/html`.
  - Aplica la configuración de `nginx.conf` para soportar Single Page Applications (SPA fallback ruteando a `index.html`) con cabeceras de seguridad explícitas en cada `location`.
  - Expone el puerto `80`.

---

## 3. Configuración de Bases de Datos y Almacenamiento

Todas las bases de datos y almacenes están declarados con sus propios volúmenes persistentes y aislados en la red común:

1. **`appdb`**:
   - Motor: PostgreSQL 16.
   - Volumen: `app-pgdata:/var/lib/postgresql/data` (persistencia permanente).
   - Inicialización automática: Aplica `01-init-snippet.sql` en el primer arranque (con `compliant BOOLEAN`).
   - Healthcheck: `psql -U app -d appdb -c 'SELECT 1'` (5s intervalo).

2. **`runner-db`**:
   - Motor: PostgreSQL 16.
   - Volumen: `runner-pgdata:/var/lib/postgresql/data`.
   - Inicialización: Tablas gestionadas por Hibernate.

3. **`accessmanager-db`**:
   - Motor: PostgreSQL 16.
   - Volumen: `accessmanager-pgdata:/var/lib/postgresql/data`.
   - Inicialización automática: Aplica `01-init-accessmanager.sql`.

4. **`redis`**:
   - Motor: Redis 7.
   - Volumen: `redis-data:/data`.
   - Uso: **Exclusivamente Cola de Mensajes (Redis Streams)** para desacoplar ejecuciones asíncronas (`snippet-jobs`, `snippet-job-results`).
   - Healthcheck: `redis-cli ping`.

5. **`azurite`**:
   - Motor: Emulador oficial de Microsoft Azure Storage.
   - Volumen: `azurite-data:/data`.
   - Puertos internos expuestos para emulación Blob (10000), Queue (10001) y Table (10002).

---

## 4. Orquestación con `docker-compose.yml` (Entorno Local)

El archivo [`SnippetSearcher-Infrastructure/docker-compose.yml`](../docker-compose.yml) unifica la infraestructura para pruebas locales mediante:
* Mapeo de puertos directos a host (`19081`, `19082`, `19083`, `5173`).
* Montaje en vivo de plantillas de Nginx y scripts de inicialización.
* `depends_on` con condiciones de salud (`service_healthy` en `appdb` y `redis`).

---

## 5. Orquestación en Servidores con Docker Swarm (`docker-stack.yml`)

Para entornos productivos y de desarrollo en VMs de Azure, se utiliza [`SnippetSearcher-Infrastructure/docker-stack.yml`](../docker-stack.yml):
1. **Red Overlay Automática**: Conexión privada entre contenedores sin exponer puertos al host salvo Nginx.
2. **Redundancia (2 Réplicas en Stateless)**: `snippetsearcher-app`, `snippetsearcher-runner`, `snippetsearcher-accessmanager` y `snippetsearcher-ui` cuentan con 2 réplicas balanceadas por IPVS interno de Swarm con rolling updates (`start-first`).
3. **Persistencia ACID (1 Réplica en Stateful)**: Bases de datos, Redis, Azurite y Certbot limitadas a 1 réplica.
4. **Configs Inmutables de Swarm**: La configuración de Nginx y los SQL se inyectan como configs con hash SHA256 (`nginx_conf_<hash>`, `app_init_<hash>`).
5. **Renovación Webroot con Certbot**: Contenedor `certbot` integrado para renovar certificados SSL cada 12 horas compartiendo `/var/www/certbot`.
