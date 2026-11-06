# Documentación de Despliegue: Docker Swarm, VMs, Stacks y Ambientes

Este documento recopila la arquitectura de despliegue, la configuración de infraestructura, las decisiones técnicas adoptadas y el ciclo de integración y despliegue continuo (CI/CD) para el ecosistema **SnippetSearcher**.

---

## 1. Arquitectura de Despliegue: ¿Por qué y cómo funciona?

### A. Desacoplamiento Total de las VMs (VM Limpia)
- **Problema previo**: En la arquitectura original, la máquina virtual (VM) tenía clones de los repositorios de Git y ejecutaba `git pull` y `docker compose up`. Luego se pasó a copiar archivos por `scp` y leer un `~/.env` local. Esto dejaba credenciales y archivos mutables en el host.
- **Solución implementada (`VM_LIMPIA.md`)**:
  - **Cero archivos del proyecto en la VM**: No hay código fuente, no hay `.env`, no hay carpetas `db/` ni `reverse-proxy/` en el home del usuario `azureuser`.
  - Las VMs solo alojan:
    1. El motor de contenedores (`Docker Engine` en modo `Swarm`).
    2. Los volúmenes persistentes de Docker (`app-pgdata`, `runner-pgdata`, `redis-data`, etc.).
    3. Los certificados SSL de Let's Encrypt (`/etc/letsencrypt/`) y la carpeta de desafíos webroot (`/var/www/certbot/`).
    4. La unidad de systemd para apagado/encendido ordenado (`snippetsearcher-lifecycle`).

---

## 2. Docker Swarm: Nodos, Stacks y Réplicas

### A. ¿Qué es un Docker Node?
En Docker tradicional, la máquina ejecuta contenedores aislados. Al inicializar Docker Swarm con `docker swarm init`, la máquina se transforma en un **nodo** de un cluster orquestado:
- **Manager**: Recibe las definiciones del stack, monitorea la salud y orquesta el estado deseado.
- **Worker**: Ejecuta las tareas/contenedores asignados.
- **Nodo Único**: En nuestras VMs individuales (`dev` y `prod`), el nodo cumple automáticamente **ambos roles (Manager y Worker)**.

### B. ¿Por qué 1 Stack Global de Infraestructura en lugar de 1 Stack por Microservicio?
1. **Un solo archivo declarativo**: Todo el sistema vive en [`docker-stack.yml`](../docker-stack.yml).
2. **Red interna automática**: No se requiere crear ni gestionar redes externas manualmente; Swarm genera automáticamente una red interna overlay para todo el stack (`snippetsearcher_default`).
3. **Cumplimiento de la regla de despliegue**:
   - **Si cambia Infraestructura** $\rightarrow$ se actualiza el stack declarativo y solo se recalculan los servicios afectados.
   - **Si cambia un Microservicio puntual** $\rightarrow$ solo se actualizan las réplicas de ese microservicio con *zero-downtime*.

### C. Redundancia Optimizada: 2 Réplicas vs. 1 Réplica
En [`docker-stack.yml`](../docker-stack.yml) se dimensionó a **2 réplicas** en los componentes sin estado para garantizar redundancia real y conmutación por error:

| Tipo de Componente | Servicios | Réplicas | Justificación Técnica |
| :--- | :--- | :---: | :--- |
| **Stateless (Sin Estado)** | `snippetsearcher-app`<br>`snippetsearcher-runner`<br>`snippetsearcher-accessmanager`<br>`snippetsearcher-ui` | **2** | Alta disponibilidad y redundancia. Docker Swarm distribuye el tráfico en *Round-Robin* mediante su balanceador interno (Routing Mesh / IPVS). Las actualizaciones ocurren de a una réplica (`parallelism: 1`, `order: start-first`), manteniendo el servicio activo. |
| **Stateful (Con Estado)** | `appdb`<br>`runner-db`<br>`accessmanager-db`<br>`redis`<br>`azurite`<br>`reverse-proxy`<br>`certbot` | **1** | Múltiples instancias sobre un mismo volumen local corromperían las bases de datos. Mantienen 1 única réplica garantizando consistencia ACID. |

---

## 3. Preguntas, Dudas y Respuestas Técnicas Discutidas

### P1: ¿Hay un comando `stack init`? ¿Dónde se corre?
> **Respuesta**: No existe ningún comando `stack init`. El único "init" es `docker swarm init`, que se corre **una sola vez en cada VM**. El stack se despliega con `docker stack deploy -c docker-stack.yml snippetsearcher`.

### P2: ¿Cómo llegan la configuración de Nginx y los SQL de inicialización sin copiar archivos a la VM?
> **Respuesta**: Mediante **Configs de Swarm** (`configs:` en `docker-stack.yml`). `deploy.yml` lee los archivos directamente en el runner de GitHub Actions y los envía a través de la API de Docker por SSH. Para que Swarm reconozca cambios en archivos inmutables, sus nombres llevan el hash SHA256 de su contenido (`nginx_conf_${NGINX_CONF_HASH}`).

### P3: ¿Dónde se configuran las variables de entorno si no hay `.env` en la VM?
> **Respuesta**: En los **Environments de GitHub** (`develop` y `production`). Variables como `DOMAIN_NAME` y `NEW_RELIC_APP_NAME_*` se cargan en la interfaz web de GitHub y el workflow `deploy.yml` las sustituye en tiempo de despliegue antes de invocar `docker stack deploy`.

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
  workflow_dispatch:

jobs:
  deploy:
    environment: ${{ github.ref_name == 'main' && 'production' || 'develop' }}
```
- **Sin filtro de paths**: `deploy.yml` es **idempotente**. Con `--resolve-image always` y configs hasheados, si un commit automático o de documentación no altera la definición de un servicio, Swarm no lo reinicia. Un commit humano que toque algo más que archivos `.md` fuerza el reinicio de App, Runner, AccessManager y UI.
- **Push a `develop` en Infra** $\rightarrow$ Utiliza el environment `develop` de GitHub y despliega en la **VM de Dev** (`snippet26dev.duckdns.org`).
- **Push / Merge a `main` en Infra** $\rightarrow$ Utiliza el environment `production` de GitHub y despliega en la **VM de Prod** (`snippet26prod.duckdns.org`).

### B. Flujo de Despliegue de Infraestructura (`deploy.yml`)
1. Checkout del repositorio en GitHub Actions.
2. Configura la clave SSH, agrega la VM a `known_hosts` e inicia sesión en GHCR dentro del runner de Actions con el secret `PAT`.
3. Calcula los hashes SHA256 de `app.conf`, `50x.html` y los scripts SQL de inicialización.
4. Crea el contexto de Docker `swarm-vm` (`ssh://<SSH_USER>@<SSH_HOST>`).
5. Ejecuta `docker --context swarm-vm stack deploy --with-registry-auth --resolve-image always --compose-file docker-stack.yml snippetsearcher`.
6. **Redeploy forzado:** Solo con un commit humano que toque algo más que `.md`: `docker service update --force` de los cuatro microservicios, de a uno.
7. **Verificación anti-rollback:** Espera hasta 40 minutos a que cada microservicio corra el digest de la imagen que pide `docker-stack.yml`. Si Swarm hace rollback por falla de arranque o descarga, el job falla en rojo con el detalle del error.
8. **Limpieza segura:** Ejecuta `docker image prune -f` y remueve configs viejos únicamente tras confirmar que las imágenes ya terminaron de descargarse.

### C. Flujo de Despliegue de Microservicios (`update-infra`)
Cuando se hace push en `develop` o `production` de un microservicio (`App`, `Runner`, `AccessManager`, `UI`):
1. El microservicio compila, valida linters, tests y cobertura, y publica su imagen en GHCR (`:<ambiente>` e inmutable `:<ambiente>-<sha>`).
2. El job `update-infra` escribe la versión inmutable en `docker-stack.yml` de Infra y hace commit directo: `develop` escribe en la rama `develop`, y `production` en la rama `main`.
3. Ese push dispara `deploy.yml`.
4. Swarm actualiza **únicamente el servicio cuya imagen cambió, con rolling update (zero-downtime)**.

Un pull request solo corre el CI. `update_service.yml` y `repository_dispatch` pertenecen al esquema anterior y ya no se usan.

### D. Diferencias entre `develop` y `main` en Infra
Las dos ramas solo difieren en las cuatro líneas `image:` de App, Runner, AccessManager y UI en `docker-stack.yml`. **No se mergean entre sí**: un merge podría poner imágenes de desarrollo en producción. Los demás cambios se aplican en las dos ramas (ver [PIPELINE_CI_CD.md](PIPELINE_CI_CD.md)).

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

# Ver en detalle las réplicas y eventos de actualización
docker stack ps snippetsearcher --no-trunc

# Ver los logs en tiempo real de un microservicio específico
docker service logs -f snippetsearcher_snippetsearcher-app
docker service logs -f snippetsearcher_snippetsearcher-runner
docker service logs -f snippetsearcher_reverse-proxy
```
