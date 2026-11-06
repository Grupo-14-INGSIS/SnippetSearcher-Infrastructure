# Guía de Diagnóstico y Resolución de Problemas (Troubleshooting)

Este documento centraliza los problemas comunes, causas raíces y procedimientos de diagnóstico y solución para el ecosistema **SnippetSearcher**, diferenciando con precisión el entorno **Local (Docker Compose)** de los entornos en **Servidores / VMs de Azure (Docker Swarm)**.

---

## Índice
- [1. Diferencias de Arquitectura: Local vs. VMs](#1-diferencias-de-arquitectura-local-vs-vms)
- [2. Problemas en Entorno Local (Docker Compose)](#2-problemas-en-entorno-local-docker-compose)
  - [2.1 Error de autenticación en GHCR al compilar o descargar](#21-error-de-autenticación-en-ghcr-al-compilar-o-descargar)
  - [2.2 Error de puertos ocupados (puerto 80, 5432 o 19081)](#22-error-de-puertos-ocupados)
  - [2.3 Reset limpio de volúmenes de base de datos](#23-reset-limpio-de-volúmenes-de-base-de-datos)
- [3. Problemas en Servidores de Azure (Docker Swarm)](#3-problemas-en-servidores-de-azure-docker-swarm)
  - [3.1 El sitio da ERR_CONNECTION_REFUSED tras encender la VM](#31-el-sitio-da-err_connection_refused-tras-encender-la-vm)
  - [3.2 Tareas en ciclo de reinicio o 'unhealthy container exit 137'](#32-tareas-en-ciclo-de-reinicio-o-unhealthy-container-exit-137)
  - [3.3 Fallo al resolver DNS interno (UnknownHostException: appdb)](#33-fallo-al-resolver-dns-interno-unknownhostexception-appdb)
  - [3.4 Rollback en GitHub Actions: 'No such image' o digest mismatch](#34-rollback-en-github-actions-no-such-image-o-digest-mismatch)
  - [3.5 Error 502 Bad Gateway en Nginx](#35-error-502-bad-gateway-en-nginx)
  - [3.6 Renovación de Certificados SSL (Let's Encrypt / Certbot)](#36-renovación-de-certificados-ssl-lets-encrypt--certbot)
  - [3.7 Disco lleno en la VM (no space left on device)](#37-disco-lleno-en-la-vm-no-space-left-on-device)
- [4. Problemas de Frontend y Auth0](#4-problemas-de-frontend-y-auth0)
  - [4.1 Error en Auth0: 'Callback URL mismatch'](#41-error-en-auth0-callback-url-mismatch)
  - [4.2 Polyfills en Vite: 'ReferenceError: process is not defined'](#42-polyfills-en-vite-referenceerror-process-is-not-defined)

---

## 1. Diferencias de Arquitectura: Local vs. VMs

| Característica | Entorno Local | Servidores Azure (Dev / Prod) |
| :--- | :--- | :--- |
| **Orquestador** | `docker compose` (`docker-compose.yml`) | `docker stack` (`docker-stack.yml` en Docker Swarm) |
| **Archivos en host** | Repositorios clonados, `./db/*-init`, `.env` | **VM Limpia**: Sin código fuente, sin `~/.env`, solo `/etc/letsencrypt` |
| **Puertos expuestos** | `19081-19084`, `5173`, `10000-10002`, `80`, `443` | **Solo 80 y 443** (Nginx perimetral) |
| **Configs & SQL** | Montaje de carpetas (`volumes: ./...`) | Configs inmutables de Swarm (`nginx_conf_<hash>`, `app_init_<hash>`) |
| **Actualizaciones** | `docker compose up -d --build` | GitHub Actions (`update-infra` en cada microservicio y `deploy.yml` en Infra) |

---

## 2. Problemas en Entorno Local (Docker Compose)

### 2.1 Error de autenticación en GHCR al compilar o descargar
* **Error:** `unauthorized: authentication required` o `denied` al hacer `docker compose pull`.
* **Causa:** Las imágenes de los microservicios en GitHub Packages (`ghcr.io/grupo-14-ingsis/...`) son privadas.
* **Solución:** Iniciar sesión con un Personal Access Token (PAT) con permisos `read:packages`:
  ```bash
  echo "<TU_GITHUB_PAT>" | docker login ghcr.io -u <TU_USUARIO_GITHUB> --password-stdin
  ```

### 2.2 Error de puertos ocupados
* **Error:** `failed to bind host port 0.0.0.0:80/tcp: address already in use` (o `19081`, `5432`).
* **Causa:** Hay un servicio nativo corriendo en tu máquina (ej. Nginx, Apache, IIS, o PostgreSQL local).
* **Solución:**
  * En Windows (PowerShell):
    ```powershell
    Get-Process -Id (Get-NetTCPConnection -LocalPort 80).OwningProcess
    Stop-Process -Id <PID>
    ```
  * En Linux:
    ```bash
    sudo lsof -i :80
    sudo systemctl stop nginx
    ```

### 2.3 Reset limpio de volúmenes de base de datos
* **Problema:** Errores de Hibernate al cambiar entidades o necesidad de ejecutar scripts de inicialización desde cero.
* **Solución:**
  ```bash
  # Detener y destruir contenedores y volúmenes locales
  docker compose down -v
  # Volver a levantar
  docker compose up -d --build
  ```

---

## 3. Problemas en Servidores de Azure (Docker Swarm)

### 3.1 El sitio da ERR_CONNECTION_REFUSED tras encender la VM
* **Causas frecuentes:**
  1. **IP pública cambiada:** En Azure, al desasignar y volver a encender la VM, la IP pública puede cambiar.
     * *Diagnóstico:* Comparar la IP de la VM en Azure Portal con la IP registrada en DuckDNS.
     * *Solución:* Entrar a [duckdns.org](https://www.duckdns.org/) y actualizar la IP en el subdominio (`snippet26dev` o `snippet26prod`).
  2. **El reverse proxy no levantó automáticamente:**
     * *Diagnóstico:* Entrar por SSH y ejecutar `docker stack services snippetsearcher`. Si `reverse-proxy` está en `0/1`:
     * *Solución:* Revisar logs con `docker service logs snippetsearcher_reverse-proxy --tail 30`. Si falta `/var/www/certbot`, crear el directorio: `sudo mkdir -p /var/www/certbot/.well-known/acme-challenge` y forzar actualización:
       ```bash
       docker service update --force snippetsearcher_reverse-proxy
       ```

### 3.2 Tareas en ciclo de reinicio o 'unhealthy container exit 137'
* **Síntoma:** Al arrancar la VM, App o Runner pasan varios minutos en `0/2`, con `load average` elevado (~30 en 2 CPUs) y tareas que fallan con exit 137.
* **Causa:** Las 6 JVMs compiten intensamente por CPU al arrancar simultáneamente. Si una JVM tarda más de `start_period`, Swarm la marca `unhealthy` y la reinicia.
* **Solución incorporada:** En `docker-stack.yml` se configuró `start_period: 900s` (15 min) y `JAVA_TOOL_OPTIONS: -XX:TieredStopAtLevel=1` para arranque rápido.
* **Recuperación manual de emergencia:**
  ```bash
  # Reducir momentáneamente a 1 réplica para bajar contención de CPU
  docker service scale snippetsearcher_snippetsearcher-app=1 snippetsearcher_snippetsearcher-runner=1 snippetsearcher_snippetsearcher-accessmanager=1
  # Una vez que alcancen 1/1, volver a escalar a 2
  docker service scale snippetsearcher_snippetsearcher-app=2 snippetsearcher_snippetsearcher-runner=2 snippetsearcher_snippetsearcher-accessmanager=2
  ```

### 3.3 Fallo al resolver DNS interno (UnknownHostException: appdb)
* **Síntoma:** Un servicio se cae con `Caused by: java.net.UnknownHostException: appdb`, a pesar de que `appdb` está activo (`1/1`).
* **Causa:** Swarm perdió temporalmente la resolución de nombre tras un apagado no ordenado.
* **Solución:** Recrear la tarea de la base de datos para refrescar el registro DNS (los datos en el volumen no se tocan):
  ```bash
  docker service update --force snippetsearcher_appdb
  ```
* **Prevención:** Asegurarse de tener instalado el servicio [`snippetsearcher-lifecycle`](file:///C:/Users/sergi/faculty/IngenieriaDeSistemas/SnippetSearcher-Infrastructure/vm/snippetsearcher-lifecycle.service) en la VM.

### 3.4 Rollback en GitHub Actions: 'No such image' o digest mismatch
* **Síntoma:** `deploy.yml` falla indicando que el servicio hizo rollback.
* **Causa:** La VM falló al descargar la imagen de GHCR (por timeout de red o porque un `docker image prune` previo interfirió con la descarga).
* **Diagnóstico en la VM:**
  ```bash
  sudo journalctl -u docker | grep "pulling image failed"
  ```
* **Solución:** En el workflow actual, el `prune` se ejecuta únicamente al final del despliegue. Para reintentar el deploy tras una falla de red, volver a disparar el workflow desde GitHub Actions.

### 3.5 Error 502 Bad Gateway en Nginx
* **Causa:** Nginx está levantado pero el microservicio backend aún está arrancando o no responde en el puerto `8080`.
* **Diagnóstico:**
  ```bash
  docker stack services snippetsearcher
  docker service ps snippetsearcher_snippetsearcher-app --no-trunc
  docker service logs snippetsearcher_snippetsearcher-app --tail 40
  ```
* **Comportamiento esperado:** Nginx muestra la página personalizada `50x.html` hasta que el servicio esté listo.

### 3.6 Renovación de Certificados SSL (Let's Encrypt / Certbot)
* **Diagnóstico:**
  ```bash
  # Probar simulación dentro del contenedor certbot
  docker exec -it $(docker ps -q -f name=snippetsearcher_certbot) certbot renew --dry-run --webroot -w /var/www/certbot
  ```
* **Si falla:** Verificar que no haya un timer nativo de certbot en Ubuntu interfiriendo (`systemctl list-timers | grep -i certbot`) y que `/var/www/certbot/.well-known/acme-challenge` exista y tenga permisos de lectura.

### 3.7 Disco lleno en la VM (no space left on device)
* **Causa:** Acumulación histórica de imágenes previas de Java y Node.
* **Solución en la VM:**
  ```bash
  # Ver uso de disco de Docker
  docker system df
  # Limpiar imágenes sin uso
  docker image prune -af
  ```

### 3.8 Falla `Update image version` en un microservicio
* **Síntoma:** El job `update-infra` queda en rojo. La imagen se publicó, pero no aparece el commit en Infra.
* **Causa:** El paso reintenta hasta 6 veces si otro repo escribió primero, así que un rojo suele indicar otro problema: `PAT` sin permisos (`403` / `denied`) o muchos pushes seguidos.
* **Solución:** Leer el error del paso. Si fue por acumulación de pushes, alcanza con **Re-run failed jobs**: la imagen ya está en GHCR.

### 3.9 Un commit humano en Infra no reinició los servicios
* **Síntoma:** En Deploy Stack, el paso `Force redeploy of the microservices` queda `skipped`.
* **Diagnóstico:** Abrir `Decide whether to force a redeploy` y leer `Forzar reinicio de los microservicios: true` o `false`.
* **Causas posibles:** El push tocó solo archivos `.md`, el run fue un *Run workflow*, el autor del commit es `github-actions[bot]`, o el run en espera fue reemplazado por otro push.
* **Solución:** Hacer otro commit humano que toque algo más que `.md`. Las reglas están en [Pipeline CI/CD](Documentación/PIPELINE_CI_CD.md).

---

## 4. Problemas de Frontend y Auth0

### 4.1 Error en Auth0: 'Callback URL mismatch'
* **Error:** Al iniciar sesión en el navegador, Auth0 muestra `Callback URL mismatch. The provided redirect_uri is not in the list of allowed callback URLs.`
* **Causa:** El dominio actual no está autorizado en el Dashboard de Auth0.
* **Solución:**
  1. Ingresar a [Auth0 Dashboard](https://manage.auth0.com/) → **Applications** → Seleccionar la app.
  2. En **Application URIs**, agregar el dominio correspondiente (`https://snippet26dev.duckdns.org` o `https://snippet26prod.duckdns.org`):
     * **Allowed Callback URLs:** `https://snippet26<env>.duckdns.org, https://snippet26<env>.duckdns.org/`
     * **Allowed Logout URLs:** `https://snippet26<env>.duckdns.org, https://snippet26<env>.duckdns.org/`
     * **Allowed Web Origins:** `https://snippet26<env>.duckdns.org`
     * **Allowed Origins (CORS):** `https://snippet26<env>.duckdns.org`
  3. Guardar cambios (**Save Changes**).

### 4.2 Polyfills en Vite: 'ReferenceError: process is not defined'
* **Causa:** Librerías empaquetadas para Node.js que asumen la presencia de la variable global `process`.
* **Solución:** Resuelto en `printscript-ui/index.html` inyectando el polyfill:
  ```html
  <script>
      window.process = window.process || { env: {} };
      window.global = window.global || window;
  </script>
  ```
