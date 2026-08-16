# Guía de Troubleshooting y Despliegue en VM (SnippetSearcher)

Este documento recopila todos los problemas, causas, diagnósticos y comandos de solución aplicados durante la sesión de puesta en marcha de la infraestructura en la VM de Azure.

---

## Índice
1. [Configuración de Auto-arranque (`restart: unless-stopped`) y Nginx](#1-configuración-de-auto-arranque-y-nginx)
2. [Permisos de Docker en Linux (`permission denied ... docker.sock`)](#2-permisos-de-docker-en-linux)
3. [Autenticación en GitHub Container Registry (`ghcr.io: unauthorized`)](#3-autenticación-en-github-container-registry-ghcrio)
4. [Variables de Entorno en la VM (`.env`)](#4-variables-de-entorno-en-la-vm-env)
5. [Puerto 80 ocupado por Nginx nativo (`address already in use`)](#5-puerto-80-ocupado-por-nginx-nativo)
6. [IP pública de Azure y sincronización con DuckDNS (`ERR_CONNECTION_REFUSED`)](#6-ip-pública-de-azure-y-sincronización-con-duckdns)
7. [Error de Certificados SSL en Nginx (`cannot load certificate: No such file`)](#7-error-de-certificados-ssl-en-nginx)
8. [Pantalla blanca en el navegador (`ReferenceError: process is not defined`) y Tags de Imágenes](#8-pantalla-blanca-en-el-navegador-y-tags-de-imágenes)
9. [Error de Auth0 (`Callback URL mismatch`)](#9-error-de-auth0-callback-url-mismatch)

---

## 1. Configuración de Auto-arranque y Nginx

### Problema
* Al reiniciar o encender la VM, los contenedores no se levantaban automáticamente.
* El servicio `reverse-proxy` (Nginx) se había borrado accidentalmente de `docker-compose.yml` en un conflicto de merge previo.

### Solución
* Se agregó la directiva `restart: unless-stopped` a todos los servicios en `docker-compose.yml`.
* Se restauró el servicio `reverse-proxy` (Nginx) con soporte de SSL y variables de entorno dinámicas.

```yaml
services:
  reverse-proxy:
    image: nginx:alpine
    container_name: reverse-proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - DOMAIN_NAME=${DOMAIN_NAME}
    volumes:
      - ./reverse-proxy/nginx/conf.d/app.conf:/etc/nginx/templates/app.conf.template:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    networks:
      - reverse-proxy-network
    command: /bin/sh -c "envsubst '$$DOMAIN_NAME' < /etc/nginx/templates/app.conf.template > /etc/nginx/conf.d/app.conf && nginx -g 'daemon off;'"
```

---

## 2. Permisos de Docker en Linux

### Error
```text
permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
```

### Causa
El usuario `azureuser` no pertenecía al grupo de usuarios `docker`.

### Solución
```bash
# 1. Agregar usuario al grupo docker
sudo usermod -aG docker $USER

# 2. Aplicar cambios a la sesión actual
newgrp docker
```

---

## 3. Autenticación en GitHub Container Registry (`ghcr.io`)

### Error
```text
! snippetsearcher-app Warning error from registry: unauthorized
unable to prepare context: path "/home/azureuser/SnippetSearcher-Runner" not found
```

### Causa
* Las imágenes en GitHub Packages de la organización son privadas y la VM no tenía la sesión iniciada.
* Docker Compose, al no poder descargar la imagen, intentaba construirla desde el código fuente local (`build: ../SnippetSearcher-Runner`), fallando porque en la VM solo está el repositorio de infraestructura.

### Solución
Iniciar sesión en GHCR con un Personal Access Token (PAT) con permisos de `read:packages`:
```bash
echo "<TU_GITHUB_PAT>" | sudo docker login ghcr.io -u <TU_USUARIO_GITHUB> --password-stdin
```

---

## 4. Variables de Entorno en la VM (`.env`)

### Advertencia
```text
WARN[0000] The "DOMAIN_NAME" variable is not set. Defaulting to a blank string.
WARN[0000] The "GITHUB_TOKEN" variable is not set. Defaulting to a blank string.
```

### Causa
El archivo `.env` no estaba presente dentro del directorio `~/SnippetSearcher-Infrastructure/`.

### Solución
Crear y configurar el archivo `~/SnippetSearcher-Infrastructure/.env`:
```bash
cd ~/SnippetSearcher-Infrastructure
nano .env
```

Contenido requerido:
```env
IMAGE_TAG=develop
DOMAIN_NAME=snippet26dev.duckdns.org
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
```

---

## 5. Puerto 80 ocupado por Nginx nativo

### Error
```text
Error response from daemon: failed to bind host port 0.0.0.0:80/tcp: address already in use
```

### Diagnóstico
```bash
sudo lsof -i :80
# o
sudo ss -tulpn | grep :80
```
Se detectó que el servicio Nginx instalado directamente en Ubuntu (`systemd`) estaba corriendo en segundo plano.

### Solución
Detener y deshabilitar el servicio del sistema operativo para liberar los puertos 80 y 443 al contenedor Docker:
```bash
sudo systemctl stop nginx
sudo systemctl disable nginx
```

---

## 6. IP pública de Azure y sincronización con DuckDNS

### Error
```text
ERR_CONNECTION_REFUSED al ingresar a https://snippet26dev.duckdns.org
```

### Causa
En Azure, al apagar y encender la VM, la IP pública cambia (ej. pasó a `102.133.145.119`). DuckDNS continuaba apuntando a la IP anterior de la semana previa.

### Solución
1. Ingresar a [duckdns.org](https://www.duckdns.org/).
2. Buscar el subdominio `snippet26dev`.
3. Actualizar el campo **current ip** con la IP pública actual de la VM y hacer clic en **update ip**.

---

## 7. Error de Certificados SSL en Nginx

### Error
```text
[emerg] cannot load certificate "/etc/letsencrypt/live/snippet16dev.duckdns.org/fullchain.pem": BIO_new_file() failed
```

### Diagnóstico
```bash
sudo docker logs reverse-proxy
sudo ls /etc/letsencrypt/live/
```

### Causa
Había un error tipográfico en el `.env`: decía `snippet16dev.duckdns.org` en vez de `snippet26dev.duckdns.org`.

### Solución
1. Corregir `DOMAIN_NAME` en `.env`:
   ```env
   DOMAIN_NAME=snippet26dev.duckdns.org
   ```
2. Recrear el contenedor:
   ```bash
   sudo docker compose up -d --force-recreate reverse-proxy
   ```

---

## 8. Pantalla blanca en el navegador y Tags de Imágenes

### Error en Consola del Navegador
```text
Uncaught ReferenceError: process is not defined at index-...js
```

### Causa
1. En aplicaciones Vite (navegador), el objeto de Node `process` no existe a menos que se agregue un polyfill.
2. El equipo ya había corregido esto en `printscript-ui/index.html` con:
   ```html
   <script>
       window.process = window.process || { env: {} };
       window.global = window.global || window;
   </script>
   ```
3. Sin embargo, el pipeline de CI/CD publica las imágenes con el tag del branch (`ghcr.io/grupo-14-ingsis/printscript-ui:develop`), mientras que `docker-compose.yml` tenía hardcodeado `:latest` (una imagen obsoleta).

### Solución
1. Actualizar `docker-compose.yml` para usar la variable dinámica `${IMAGE_TAG:-develop}`.
2. Definir en `.env`:
   ```env
   IMAGE_TAG=develop
   ```
3. Descargar las imágenes actualizadas y recrear contenedores:
   ```bash
   sudo docker compose pull
   sudo docker compose up -d --force-recreate
   sudo docker image prune -f
   ```

---

## 9. Error de Auth0 (`Callback URL mismatch`)

### Error en Auth0
```text
Callback URL mismatch. The provided redirect_uri is not in the list of allowed callback URLs.
```

### Causa
Auth0 no tenía registrado el dominio `https://snippet26dev.duckdns.org` en la lista blanca de URLs autorizadas de la aplicación.

### Solución
1. Ir a [Auth0 Dashboard](https://manage.auth0.com/) > **Applications** > **Applications** > Seleccionar la app.
2. En la sección **Application URIs**, agregar:
   * **Allowed Callback URLs:** `https://snippet26dev.duckdns.org, https://snippet26dev.duckdns.org/`
   * **Allowed Logout URLs:** `https://snippet26dev.duckdns.org, https://snippet26dev.duckdns.org/`
   * **Allowed Web Origins:** `https://snippet26dev.duckdns.org`
   * **Allowed Origins (CORS):** `https://snippet26dev.duckdns.org`
3. Guardar cambios (**Save Changes**).

---

## 🚀 Comandos Rápidos de Mantenimiento

```bash
# Ver estado de todos los contenedores
sudo docker ps -a

# Ver logs de un servicio específico
sudo docker logs -f <nombre_del_contenedor>

# Actualizar y reiniciar todo el stack
cd ~/SnippetSearcher-Infrastructure
sudo docker compose pull
sudo docker compose up -d --force-recreate
sudo docker image prune -f
```
