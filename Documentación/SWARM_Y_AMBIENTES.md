# Documentación de Despliegue: Docker Swarm, VMs, Stacks y Ambientes

Este documento recopila la arquitectura de despliegue, la configuración de infraestructura, las decisiones técnicas adoptadas, las dudas y respuestas resueltas, y el ciclo de integración y despliegue continuo (CI/CD) para el ecosistema **SnippetSearcher**.

---

## 1. Arquitectura de Despliegue: ¿Por qué y cómo funciona?

### A. Desacoplamiento Total de las VMs (Cero Repositorios en la VM)
- **Problema previo**: En la arquitectura original, la máquina virtual (VM) tenía clones de los repositorios de Git y ejecutaba `git pull` y `docker compose up`. Esto violaba las buenas prácticas de inmutabilidad, consumía espacio innecesario, exponía credenciales y acoplaba el entorno productivo al control de versiones.
- **Solución implementada**:
  - **No hay código fuente en las VMs**: Se eliminaron todos los repositorios clonados de las VMs.
  - Las VMs solo alojan:
    1. El motor de contenedores (`Docker Engine` en modo `Swarm`).
    2. El archivo de variables de entorno del host (`~/.env`).
    3. Los volúmenes persistentes de bases de datos (`app-pgdata`, `runner-pgdata`, etc.).
    4. Los certificados SSL de Let's Encrypt (`/etc/letsencrypt/`).

---

## 2. Docker Swarm: Nodos, Stacks y Réplicas

### A. ¿Qué es un Docker Node?
En Docker tradicional, la máquina ejecuta contenedores aislados. Al inicializar Docker Swarm con `docker swarm init`, la máquina se transforma en un **nodo** de un cluster orquestado:
- **Manager**: Recibe las definiciones del stack, monitorea la salud y orquesta el estado deseado.
- **Worker**: Ejecuta las tareas/contenedores asignados.
- **Nodo Único**: En nuestras VMs individuales (`dev` y `prod`), el nodo cumple automáticamente **ambos roles (Manager y Worker)**.

### B. ¿Por qué 1 Stack Global de Infraestructura en lugar de 1 Stack por Microservicio?
1. **Un solo archivo declarativo**: Todo el sistema vive en [`docker-stack.yml`](../docker-stack.yml).
2. **Red interna automática**: No se requiere crear ni gestionar redes externas manualmente; Swarm genera automáticamente una red interna para todo el stack (`snippetsearcher_default`).
3. **Cumplimiento de la regla de despliegue**:
   - **Si cambia Infraestructura** $\rightarrow$ se redeploya todo el stack y se actualizan todos los servicios.
   - **Si cambia un Microservicio puntual** $\rightarrow$ solo se actualiza ese microservicio con *zero-downtime*.

### C. Redundancia Optimizada: 2 Réplicas vs. 1 Réplica
En [`docker-stack.yml`](../docker-stack.yml) se aplicó la distinción entre servicios con y sin estado, dimensionado a **2 réplicas** para garantizar redundancia real y conmutación por error sin agotar la memoria de las VMs de Azure:

| Tipo de Componente | Servicios | Réplicas | Justificación Técnica |
| :--- | :--- | :---: | :--- |
| **Stateless (Sin Estado)** | `snippetsearcher-app`<br>`snippetsearcher-runner`<br>`snippetsearcher-accessmanager`<br>`snippetsearcher-ui` | **2** | Provee alta disponibilidad y redundancia en la misma VM. Docker Swarm distribuye las peticiones en *Round-Robin* mediante su balanceador interno (Routing Mesh / IPVS). Si una réplica se actualiza o reinicia, la otra continúa respondiendo con *zero-downtime*. Con 2 réplicas de Runner, la ejecución interactiva opera de forma **stateless** (el cliente envía los inputs acumulados en cada turno). |
| **Stateful (Con Estado)** | `appdb`<br>`runner-db`<br>`accessmanager-db`<br>`redis`<br>`azurite`<br>`reverse-proxy` | **1** | **Múltiples réplicas de bases de datos relacionales sobre el mismo volumen de disco corrompen los datos**. Mantienen 1 única réplica garantizando integridad referencial y consistencia ACID. |

---

## 3. Preguntas, Dudas y Respuestas Técnicas Discutidas

### P1: ¿Hay un comando `stack init`? ¿Dónde se corre?
> **Respuesta**: No existe ningún comando `stack init`. El único "init" es `docker swarm init`, que se corre **una sola vez en cada VM**. El stack se despliega directamente con `docker stack deploy -c docker-stack.yml <nombre_stack>`.

### P2: ¿Por qué no necesitamos configurar una Docker Network manual si tenemos un solo stack?
> **Respuesta**: Cuando se tienen múltiples stacks separados, es obligatorio crear una red externa manual (`docker network create --driver overlay ...`) para que puedan verse entre sí. Al unificar todo en **un solo stack**, Docker Swarm crea automáticamente la red interna del stack y conecta todos los contenedores sin requerir ninguna línea de configuración de red en el YAML.

### P3: ¿Nginx ya estaba como Reverse Proxy o se agregó ahora?
> **Respuesta**: El contenedor `reverse-proxy` (Nginx) ya existía en compose, pero:
> 1. No estaba formalizado ni dibujado en los diagramas PlantUML de la arquitectura (la UI parecía comunicarse directo con los backends).
> 2. Dependía de carpetas montadas del repositorio local que al borrar los repos de la VM fallarían. Se integró mediante montaje directo del template en `volumes:` y resolución de variable `$DOMAIN_NAME` en tiempo de inicio.

### P4: ¿Se pierden las variables de entorno al borrar los repositorios de la VM?
> **Respuesta**: No, porque antes del borrado se resguardó el archivo `.env` en la raíz del usuario (`~/.env`). Los repositorios clonados (`rm -rf SnippetSearcher-*`) se borraron, pero `~/.env` permanece en el host.

### P5: ¿Más de una réplica de base de datos puede traer problemas?
> **Respuesta**: Sí, gravísimos. PostgreSQL no admite que múltiples procesos escriban concurrentemente en el mismo directorio de datos sin un software de clustering distribuido (como Patroni). Por eso, las bases de datos tienen estrictamente `replicas: 1`.

---

## 4. Estrategia de CI/CD: Ambientes Develop y Producción

### A. Separación de Ambientes por Ramas en Infraestructura
En [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml):
```yaml
on:
  push:
    branches:
      - main
      - develop
    paths:
      - 'docker-stack.yml'
      - 'reverse-proxy/**'
      - 'db/**'

jobs:
  deploy:
    name: Deploy Stack to ${{ github.ref_name == 'main' && 'production' || 'develop' }}
    environment: ${{ github.ref_name == 'main' && 'production' || 'develop' }}
```
- **Filtro de paths**: `deploy.yml` sólo se activa si hay cambios estructurales (`docker-stack.yml`, `reverse-proxy/`, `db/`), evitando redeploys innecesarios ante cambios en documentación o workflows.
- **Push a `develop` en Infra** $\rightarrow$ Utiliza los GitHub Secrets del environment `develop` y despliega en la **VM de Dev**.
- **Push / Merge a `main` en Infra** $\rightarrow$ Utiliza los GitHub Secrets del environment `production` y despliega en la **VM de Prod**.

### B. Flujo de Despliegue de Infraestructura (`deploy.yml`)
1. Hace checkout del repo de infraestructura en GitHub Actions.
2. Copia vía **SCP** el archivo `docker-stack.yml`, la carpeta `reverse-proxy/` y las carpetas de inicialización de base de datos (`db/`) al `~` de la VM destino (creando los directorios con `mkdir -p` como red de seguridad).
3. Se conecta por SSH a la VM:
   - Carga las variables locales del host (`source ~/.env`).
   - Se autentica en GitHub Container Registry (`docker login ghcr.io`).
   - Despliega el stack: `docker stack deploy --with-registry-auth -c docker-stack.yml snippetsearcher`.
   - Limpia imágenes obsoletas con `docker image prune -f || true`.

### C. Flujo de Despliegue de Microservicios (`update_service.yml`)
Cuando se hace commit en un microservicio (`App`, `Runner`, `AccessManager`, `UI`):
1. El microservicio compila, corre tests y publica su imagen en GHCR (`ghcr.io/grupo-14-ingsis/<service>:<branch>`).
2. Envía un `repository_dispatch` hacia el repositorio de infraestructura con evento `new-image-ready`, indicando el servicio y el environment.
3. El workflow `update_service.yml` maneja **concurrencia por servicio y ambiente**:
   ```yaml
   concurrency:
     group: deploy-${{ github.event.client_payload.environment }}-${{ github.event.client_payload.service }}
     cancel-in-progress: false
   ```
   Esto evita que pushes simultáneos a diferentes microservicios cancelen despliegues en curso ("superseded").
4. **Mapeo de nombres**: Mapea automáticamente el servicio Swarm al paquete GHCR correspondiente:
   - `snippetsearcher-ui` $\rightarrow$ imagen `ghcr.io/grupo-14-ingsis/printscript-ui:<env>`
   - `snippetsearcher-app` $\rightarrow$ imagen `ghcr.io/grupo-14-ingsis/snippetsearcher-app:<env>`
   - `snippetsearcher-runner` $\rightarrow$ imagen `ghcr.io/grupo-14-ingsis/snippetsearcher-runner:<env>`
   - `snippetsearcher-accessmanager` $\rightarrow$ imagen `ghcr.io/grupo-14-ingsis/snippetsearcher-accessmanager:<env>`
5. Ejecuta en la VM:
   ```bash
   docker service update --with-registry-auth --image "$IMAGE_URI" "$SWARM_SERVICE"
   ```
6. **Resultado**: Swarm actualiza **únicamente las 2 réplicas de ese microservicio con rolling update (zero-downtime)**, sin reiniciar bases de datos ni tocar ningún otro componente.

### D. Configuración Dinámica de Tests E2E (Cypress)
En `printscript-ui/cypress.config.ts`, Cypress detecta la rama activa:
- En **`develop`**: Configura `baseUrl: https://snippet26dev.duckdns.org`.
- En **`main`** / **`production`**: Configura `baseUrl: https://snippet26prod.duckdns.org`.

---

## 5. Comandos Útiles de Monitoreo en las VMs

Para inspeccionar el estado del cluster en la VM (`dev` o `prod`):

```bash
# Ver el estado del nodo Swarm
docker node ls

# Listar los stacks activos
docker stack ls

# Ver todos los servicios del stack y sus réplicas activas (ej: 2/2)
docker stack services snippetsearcher

# Ver en detalle las réplicas y en qué estado se encuentran
docker stack ps snippetsearcher

# Ver los logs en tiempo real de un microservicio específico
docker service logs -f snippetsearcher_snippetsearcher-app
docker service logs -f snippetsearcher_snippetsearcher-runner
```
