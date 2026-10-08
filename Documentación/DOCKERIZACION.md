
# Documentación de Dockerización y Orquestación

Este documento detalla la estrategia de contenedorización y orquestación del sistema SnippetSearcher, demostrando cómo cumple con la premisa: **"Dockerizar todos los servicios y las bases de datos, cada uno con su Dockerfile, y levantar el sistema entero con un docker-compose.yml"**.

---

## 1. Resumen Ejecutivo del Cumplimiento

| Componente | Tipo | Estrategia Docker / Imagen Base | Rol en la Arquitectura |
| :--- | :--- | :--- | :--- |
| **SnippetSearcher-App** | Microservicio Backend | `Dockerfile` propio (Multi-stage: Gradle 8.14 JDK 21 $\rightarrow$ Temurin 21 JRE) | Core de negocio y orquestador |
| **SnippetSearcher-Runner** | Microservicio Backend | `Dockerfile` propio (Multi-stage: Gradle 8.14 JDK 21 $\rightarrow$ Temurin 21 JRE) | Motor de ejecución (PrintScript, etc.) |
| **SnippetSearcher-AccessManager** | Microservicio Backend | `Dockerfile` propio (Multi-stage: Gradle 8.14 JDK 21 $\rightarrow$ Temurin 21 JRE) | Autorización y gestión de permisos |
| **printscript-ui** | Frontend SPA | `Dockerfile` propio (Multi-stage: Node 20 Alpine $\rightarrow$ Nginx Alpine) | Interfaz gráfica de usuario |
| **appdb** | Base de Datos | `postgres:16` + script init SQL | Persistencia de snippets y metadatos |
| **runner-db** | Base de Datos | `postgres:16` + script init SQL | Persistencia de ejecuciones y estados |
| **accessmanager-db** | Base de Datos | `postgres:16` + script init SQL | Persistencia de permisos y relaciones de usuarios |
| **redis** | Message Queue | `redis:7` | Cola de tareas asíncronas (Streams) |
| **asset-service** | Microservicio Assets | `ghcr.io/austral-ingsis/snippet-asset-service` | API de gestión de archivos binarios/código |
| **azurite** | Object Storage Emulator | `mcr.microsoft.com/azure-storage/azurite` | Emulador de Azure Blob Storage |
| **reverse-proxy** | Edge Proxy / Gateway | `nginx:alpine` + template Nginx dinámico | Punto único de entrada HTTP/HTTPS y ruteo |

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
- **Ubicación**: [`SnippetSearcher-App/Dockerfile`](../../SnippetSearcher-App/Dockerfile)
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
- **Ubicación**: [`SnippetSearcher-Runner/Dockerfile`](../../SnippetSearcher-Runner/Dockerfile)
- **Fase 1 (Build)**:
  - Base: `gradle:8.14-jdk21 AS build`
  - Parámetros de compilación: Acepta `GITHUB_USER` y `GITHUB_TOKEN` como build arguments (`ARG`) para resolver librerías publicadas en GitHub Packages (e.g. plugins del linter y formateador).
  - Ejecuta: `gradle bootJar -x test -PgithubUsername=${GITHUB_USERNAME} -PgithubToken=${GITHUB_TOKEN}`.
- **Fase 2 (Runtime)**:
  - Base: `eclipse-temurin:21-jre`.
  - Copia el JAR generado (`SnippetSearcher-Interpreter-1.0-SNAPSHOT.jar` a `app.jar`).
  - Integra el agente APM New Relic.
  - Expone el puerto `8080`.

---

### C. `SnippetSearcher-AccessManager`
- **Ubicación**: [`SnippetSearcher-AccessManager/Dockerfile`](../../SnippetSearcher-AccessManager/Dockerfile)
- **Fase 1 (Build)**:
  - Base: `gradle:8.14-jdk21 AS build`
  - Ejecuta: `gradle bootJar -x test`.
- **Fase 2 (Runtime)**:
  - Base: `eclipse-temurin:21-jre`.
  - Copia el JAR generado.
  - Integra New Relic para observabilidad de llamadas de autenticación/autorización.
  - Expone el puerto `8080`.

---

### D. `printscript-ui`
- **Ubicación**: [`printscript-ui/Dockerfile`](../../printscript-ui/Dockerfile)
- **Fase 1 (Build)**:
  - Base: `node:20-alpine AS builder`
  - Entorno de compilación: Inyecta variables de Auth0 y URLs de backend mediante `ARG` (`VITE_AUTH0_DOMAIN`, `VITE_API_URL`, etc.).
  - Ejecuta: `npm ci` y `npm run build` produciendo el bundle de producción en `/app/dist`.
- **Fase 2 (Runtime)**:
  - Base: `nginx:alpine`
  - Copia los estáticos compilados a `/usr/share/nginx/html`.
  - Aplica la configuración de [`nginx.conf`](../../printscript-ui/nginx.conf) para soportar Single Page Applications (SPA fallback ruteando a `index.html`).
  - Expone el puerto `80`.

---

## 3. Configuración de Bases de Datos y Almacenamiento

Todas las bases de datos y almacenes están declarados con sus propios volúmenes persistentes y aislados en la red común:

1. **`appdb`**:
   - Motor: PostgreSQL 16.
   - Volumen: `app-pgdata:/var/lib/postgresql/data` (persistencia permanente).
   - Inicialización automática: Monta [`./db/app-init`](../db/app-init) en `/docker-entrypoint-initdb.d` para aplicar `01-init-snippet.sql` en el primer arranque.
   - Healthcheck: `psql -U app -d appdb -c 'SELECT 1'` (5s intervalo).

2. **`runner-db`**:
   - Motor: PostgreSQL 16.
   - Volumen: `runner-pgdata:/var/lib/postgresql/data`.
   - Inicialización automática: Monta [`./db/runner-init`](../db/runner-init) en `/docker-entrypoint-initdb.d`.

3. **`accessmanager-db`**:
   - Motor: PostgreSQL 16.
   - Volumen: `accessmanager-pgdata:/var/lib/postgresql/data`.
   - Inicialización automática: Monta [`./db/accessmanager-init`](../db/accessmanager-init) ejecutando `01-init-accessmanager.sql`.

4. **`redis`**:
   - Motor: Redis 7.
   - Volumen: `redis-data:/data`.
   - Uso: **Exclusivamente Cola de Mensajes (Redis Streams)** para desacoplar ejecuciones asíncronas.
   - Healthcheck: `redis-cli ping` (30 reintentos cada 1s).

5. **`azurite`**:
   - Motor: Emulador oficial de Microsoft Azure Storage.
   - Volumen: `azurite-data:/data`.
   - Puertos internos expuestos para emulación Blob (10000), Queue (10001) y Table (10002).

---

## 4. Orquestación con `docker-compose.yml`

El archivo [`SnippetSearcher-Infrastructure/docker-compose.yml`](../docker-compose.yml) unifica la infraestructura mediante las siguientes directivas clave:

### A. Dependencias y Orden de Arranque (`depends_on`)
Garantiza que ningún servicio arranque antes de que su base de datos o cola esté verdaderamente lista:
```yaml
snippetsearcher-app:
  depends_on:
    appdb:
      condition: service_healthy       # Espera a que PostgreSQL responda SELECT 1
    redis:
      condition: service_healthy       # Espera a que Redis responda PING
    snippetsearcher-accessmanager:
      condition: service_started
    snippetsearcher-runner:
      condition: service_started
```

### B. Comunicación Interna por DNS de Docker (`networks`)
Todos los contenedores están vinculados a la red común:
```yaml
networks:
  reverse-proxy-network:
    name: reverse-proxy-network
```
Esto permite que los microservicios se comuniquen entre sí usando nombres de contenedor estables como hosts:
- `DB_HOST: appdb`
- `ACCESS_MANAGER_HOST: snippetsearcher-accessmanager`
- `REDIS_HOST: redis`
- `BUCKET_SERVICE: asset-service`

### C. Puerta de Enlace Perimetral: Nginx Reverse Proxy
El servicio `reverse-proxy` expone los puertos públicos `80` y `443` y enruta según el path:
- `/` $\rightarrow$ `snippetsearcher-ui:80`
- `/api/` $\rightarrow$ `snippetsearcher-app:8080`
- `/runner/` $\rightarrow$ `snippetsearcher-runner:8080`
- `/access/` $\rightarrow$ `snippetsearcher-accessmanager:8080`

---

## 5. Comandos para Levantar el Sistema Completo

Desde el directorio `SnippetSearcher-Infrastructure`:

### 1. Construir e Iniciar Todo el Entorno
```powershell
docker compose up -d --build
```

### 2. Verificar el Estado de Todos los Contenedores
```powershell
docker compose ps
```

### 3. Ver Logs en Tiempo Real
```powershell
# Todos los servicios
docker compose logs -f

# Un servicio específico (ejemplo: App o Runner)
docker compose logs -f snippetsearcher-app
docker compose logs -f snippetsearcher-runner
```

### 4. Detener y Limpiar el Entorno
```powershell
# Detener sin borrar volúmenes (mantiene datos de base de datos)
docker compose down

# Detener borrando volúmenes (reseteo limpio de bases de datos)
docker compose down -v
```
