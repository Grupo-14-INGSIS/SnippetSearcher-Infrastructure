# nginx y HTTPS: qué estaba mal y cómo se arregló

Explicación corta de los 7 problemas que encontramos al comparar el proyecto con el material de la
cátedra, y una guía paso a paso para aplicar todo en la VM de **prod**.

Material de referencia:
- **Repo de la cátedra** [`austral-ingsis/nginx-docker`](https://github.com/austral-ingsis/nginx-docker): reverse proxy.
- **PDF `06-https`**: HTTPS con Let's Encrypt + DuckDNS (diapositivas 19 a 27).
- **PDF `07-reverse-proxy`**: qué es un reverse proxy.

---

## Los 7 problemas

### 1. Los servicios se podían usar sin pasar por nginx
- **Qué pasaba:** App, Runner, AccessManager, UI, asset service y Azurite publicaban puertos en la VM
  (19081 a 19084, 5173, 10000 a 10002). Si el firewall los dejaba abiertos, cualquiera podía entrar
  directo, **por HTTP y sin pasar por nginx**. El asset service ni siquiera pide login.
- **Qué se cambió:** en `docker-stack.yml` se sacaron los `ports:` de todos los servicios menos el
  `reverse-proxy`, que es el único que publica (80 y 443).
- **Por qué no se rompe nada:** los servicios se hablan entre sí por nombre (`snippetsearcher-app:8080`),
  no por esos puertos. En la VM la UI llama a `/api` y `/runner` del mismo dominio. En local
  (`docker-compose.yml`) los puertos siguen, porque ahí la UI sí los usa.
- **En qué se basa:** repo `nginx-docker`: *"Those backends have no published host ports"*. El proxy
  tiene que ser la única puerta de entrada.

### 2. Let's Encrypt no podía verificar el dominio (el certificado no se renovaba)
- **Qué pasaba:** para renovar, Let's Encrypt pide un archivo (token) por HTTP en
  `http://<dominio>/.well-known/acme-challenge/...`. Nuestro nginx mandaba **todo** el puerto 80 a
  HTTPS, así que nunca devolvía el token. Además certbot estaba configurado en modo `nginx`, que
  necesita un nginx instalado en Ubuntu, y el nuestro está en un contenedor. **Resultado:** el
  certificado de dev estuvo a 9 días de vencer.
- **Qué se cambió:**
  - `app.conf`: en el puerto 80 se agregó `location /.well-known/acme-challenge/` que sirve la carpeta
    `/var/www/certbot`. Todo lo demás sigue yendo a HTTPS.
  - `docker-stack.yml`: el `reverse-proxy` monta `/var/www/certbot`.
  - certbot pasó a modo **webroot**: deja el token en esa carpeta y nginx lo sirve. **Sigue siendo
    nginx el que responde.** Lo único que cambia es cómo le llega el token.
- **En qué se basa:** PDF 06, diap. 22 (cómo verifica Let's Encrypt) y diap. 25 (el mismo `location`).

### 3. certbot no corría en un contenedor
- **Qué pasaba:** certbot estaba instalado en la VM, fuera de Docker y del stack.
- **Qué se cambió:** se agregó el servicio `certbot` a `docker-stack.yml`. Cada 12 horas corre
  `certbot renew`, que solo renueva si faltan menos de 30 días. Comparte con nginx las carpetas
  `/etc/letsencrypt` (certificados) y `/var/www/certbot` (tokens). También se sumó a
  `vm/snippetsearcher-lifecycle.sh` para que se baje y suba con la VM.
- **En qué se basa:** PDF 06, diap. 20 ("container certbot") y diap. 24 (nginx y certbot en Compose,
  compartiendo carpetas).

### 4. nginx no tomaba el certificado nuevo
- **Qué pasaba:** nginx lee el certificado **solo al arrancar**. Aunque certbot renovara, nginx seguía
  sirviendo el viejo.
- **Qué se cambió:** el `reverse-proxy` hace `nginx -s reload` cada 6 horas. Recarga sin cortar
  conexiones y, si el certificado no cambió, no pasa nada.
- **En qué se basa:** PDF 06, diap. 26: *"nginx lee el certificado al arrancar: después de renovar,
  nginx -s reload"*.

### 5. No había página de error propia
- **Qué pasaba:** si un servicio estaba caído o arrancando, se veía la página fea de nginx (502).
- **Qué se cambió:** página nueva `reverse-proxy/nginx/errors/50x.html` ("Servicio no disponible").
  `app.conf` la usa para 502/503/504 y viaja como config de Swarm (`nginx_50x_<hash>`).
- **En qué se basa:** repo `nginx-docker`, que usa `error_page` con una página propia marcada `internal`.
  Es una mejora, no un requisito fuerte.

### 6. La imagen de nginx no era la estable
- **Qué pasaba:** se usaba `nginx:alpine`, que es la rama de desarrollo de nginx y cambia seguido.
- **Qué se cambió:** `nginx:stable-alpine` en `docker-stack.yml`, `docker-compose.yml` y el
  `Dockerfile` de la UI.
- **En qué se basa:** repo `nginx-docker`, que usa `nginx:stable-alpine`. El PDF 06 usa una versión
  fija (`nginx:1.27`). Es una mejora menor.

### 7. La UI perdía sus headers de seguridad
- **Qué pasaba:** en `printscript-ui/nginx.conf`, los headers de seguridad (`X-Frame-Options`, etc.)
  estaban en el `server`. Pero un `location` que tiene su propio `add_header` **no hereda** los del
  `server`, así que los `.js`, los `.css` e `index.html` salían sin ellos.
- **Qué se cambió:** se repiten los tres headers dentro de esos dos `location`.
- **En qué se basa:** no viene del material. Es un bug de configuración de nginx que encontramos de
  paso.

### Resumen

| # | Problema | Archivo(s) | Material |
|---|---|---|---|
| 1 | Servicios accesibles sin nginx | `docker-stack.yml` | Repo `nginx-docker` |
| 2 | Token de Let's Encrypt redirigido | `app.conf`, `docker-stack.yml` | PDF 06, diap. 22 y 25 |
| 3 | certbot fuera de Docker | `docker-stack.yml`, `vm/snippetsearcher-lifecycle.sh` | PDF 06, diap. 20 y 24 |
| 4 | nginx no recargaba el certificado | `docker-stack.yml` | PDF 06, diap. 26 |
| 5 | Sin página de error propia | `50x.html`, `app.conf`, `docker-stack.yml`, `deploy.yml` | Repo `nginx-docker` |
| 6 | Imagen no estable | `docker-stack.yml`, `docker-compose.yml`, `Dockerfile` (UI) | Repo `nginx-docker` |
| 7 | Headers perdidos en la UI | `printscript-ui/nginx.conf` | (bug, no del material) |

Los problemas 1 a 4 eran **incumplimientos** del material. Del 5 al 7 son **mejoras**.

---

## Guía para prod (cuando todo esté pusheado en `develop`)

> En la VM de dev esto ya está hecho. Ver la nota al final.

### Paso 1. Antes de mergear: preparar la VM de prod
Entrar por SSH a la VM de prod y correr:
```bash
# Carpeta para los tokens. TIENE que existir antes del deploy: si no, el reverse-proxy no arranca.
sudo mkdir -p /var/www/certbot/.well-known/acme-challenge

# Ver cuándo vence el certificado y en qué modo está (seguramente dice "nginx")
sudo certbot certificates | grep -E "Domains|Expiry"
sudo grep -h authenticator /etc/letsencrypt/renewal/*.conf
```

### Paso 2. Merges (en este orden)
1. **`printscript-ui`**: merge de `develop` → `production`. El CI construye la imagen `:production`
   (headers + `nginx:stable-alpine`). Esperar a que el CI termine en verde.
2. **`SnippetSearcher-Infrastructure`**: merge de `develop` → `main`. El workflow *Deploy Stack*
   despliega en prod. Esperar a que termine en verde.

### Paso 3. Después del deploy: certificado en modo webroot
En la VM de prod:
```bash
# 1. Comprobar que nginx sirve la carpeta de tokens (tiene que imprimir: ok)
echo ok | sudo tee /var/www/certbot/.well-known/acme-challenge/test
curl http://snippet26prod.duckdns.org/.well-known/acme-challenge/test
sudo rm /var/www/certbot/.well-known/acme-challenge/test

# 2. Apagar el certbot instalado en la VM (ahora lo hace el contenedor). Uno de los dos va a existir:
sudo systemctl disable --now certbot.timer
sudo snap stop --disable certbot.renew

# 3. Pasar el certificado a modo webroot y renovarlo
docker run --rm \
  -v /etc/letsencrypt:/etc/letsencrypt -v /var/www/certbot:/var/www/certbot \
  certbot/certbot:v2.11.0 certonly --webroot -w /var/www/certbot \
  -d snippet26prod.duckdns.org --force-renewal --non-interactive

# 4. Que nginx tome el certificado nuevo ya
docker exec $(docker ps -q -f name=snippetsearcher_reverse-proxy) nginx -s reload

# 5. Borrar el hook viejo, si existe
sudo rm -f /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# 6. Que el script de apagado/prendido de la VM también maneje certbot
sudo sed -i 's/^APP_SERVICES="reverse-proxy/APP_SERVICES="certbot reverse-proxy/' /usr/local/sbin/snippetsearcher-lifecycle.sh
grep ^APP_SERVICES /usr/local/sbin/snippetsearcher-lifecycle.sh     # tiene que empezar con "certbot"
```

### Paso 4. Verificar
```bash
# Modo webroot (no tiene que decir nginx)
sudo grep -hE "authenticator|installer" /etc/letsencrypt/renewal/*.conf

# La renovación automática funciona. Tiene que decir "Congratulations, all simulated renewals succeeded".
# Usar -it: así Ctrl+C sí lo corta si algo se traba.
docker exec -it $(docker ps -q -f name=snippetsearcher_certbot) certbot renew --dry-run --webroot -w /var/www/certbot

# Los backends ya no están abiertos desde afuera (tiene que fallar o dar timeout)
curl -m 5 http://snippet26prod.duckdns.org:19081/

# El sitio anda por HTTPS
curl -sI https://snippet26prod.duckdns.org/ | head -n 1
```
En el navegador, el certificado de `snippet26prod.duckdns.org` tiene que figurar **emitido hoy** y con
**vencimiento en unos 90 días**. Probar también entrar, crear un snippet y ejecutarlo.

### Si algo sale mal
- **El `reverse-proxy` no arranca:** casi seguro falta `/var/www/certbot`. Crearla (paso 1) y correr
  `docker service update --force snippetsearcher_reverse-proxy`.
- **"Another instance of Certbot is already running":** hay otro certbot corriendo. Esperar un minuto o
  reiniciar el servicio con `docker service update --force snippetsearcher_certbot`.
- **Ver qué hizo certbot:** `docker service logs snippetsearcher_certbot --tail 30`.

---

### Nota: pendientes en la VM de dev
El certificado de dev ya se renovó (vence el 22/01/2027) y la prueba de renovación pasó. Falta:
```bash
sudo rm -f /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
systemctl list-timers | grep -i certbot            # no debería aparecer nada; si aparece, apagarlo (paso 3.2)
sudo sed -i 's/^APP_SERVICES="reverse-proxy/APP_SERVICES="certbot reverse-proxy/' /usr/local/sbin/snippetsearcher-lifecycle.sh
```
