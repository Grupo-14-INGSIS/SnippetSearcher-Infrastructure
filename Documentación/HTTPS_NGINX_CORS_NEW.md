# HTTPS, Nginx y CORS

## Índice
- [1. Recorrido de una request](#1-recorrido-de-una-request)
- [2. Dos Nginx, dos roles](#2-dos-nginx-dos-roles)
- [3. HTTPS y Renovación Webroot con Certbot](#3-https-y-renovación-webroot-con-certbot)
- [4. El reverse proxy (app.conf)](#4-el-reverse-proxy-appconf)
- [5. CORS](#5-cors)
- [6. Cómo probarlo](#6-cómo-probarlo)
- [7. Preguntas para repasar](#7-preguntas-para-repasar)

---

## 1. Recorrido de una request

```
navegador ──HTTP :80──▶ reverse-proxy ──301──▶ https://<dominio>/...      (siempre a HTTPS)
                        (excepto desafío ACME: /.well-known/acme-challenge/ -> certbot webroot)

navegador ──HTTPS :443──▶ reverse-proxy (termina TLS con certificado de Let's Encrypt)
                            ├─ /          ──▶ snippetsearcher-ui:80             (Nginx estáticos de UI)
                            └─ /api/      ──▶ snippetsearcher-app:8080          (API Backend)

                            Runner y AccessManager no están publicados: solo App los llama, por la red interna.
```

- **Perímetro seguro:** Afuera todo es HTTPS. Adentro, entre Nginx y los servicios, es HTTP plano por la red overlay de Swarm, que no sale de la VM.
- **Aislamiento de puertos:** Los microservicios no exponen puertos al host. Toda la comunicación externa pasa por el proxy en 80 y 443.
- **Sin CORS en las VMs:** La UI y la API comparten dominio y origen (`https://<dominio>`), por lo que el navegador no requiere preflights CORS en la nube.

---

## 2. Dos Nginx, dos roles

| | Reverse proxy (Infra) | Nginx de la UI |
| :--- | :--- | :--- |
| Repo / config | `SnippetSearcher-Infrastructure` → `reverse-proxy/nginx/conf.d/app.conf` | `printscript-ui` → `nginx.conf` |
| Imagen | `nginx:stable-alpine` oficial | `nginx:stable-alpine` con bundle estático en `/usr/share/nginx/html` |
| Servicio de Swarm | `reverse-proxy` (1 réplica) | `snippetsearcher-ui` (2 réplicas) |
| Puertos | **80 y 443 públicos** | 80 en la red interna de Swarm |
| Qué hace | Entrada única: desafío ACME, redirige a HTTPS, termina TLS, rutea por path, inyecta `X-Forwarded-*` | **Sirve archivos estáticos**: compresión gzip, headers de seguridad y caché, y SPA fallback a `index.html` |
| Despliegue | Config de Swarm (`nginx_conf_<hash>`) vía `deploy.yml` | Imagen Docker propia vía `update-infra` y `deploy.yml` |

---

## 3. HTTPS y Renovación Webroot con Certbot

### Certificados SSL
Viven en el host en `/etc/letsencrypt` y el contenedor `reverse-proxy` los monta en modo solo lectura (`ro`):

```yaml
reverse-proxy:
  volumes:
    - /etc/letsencrypt:/etc/letsencrypt:ro
    - /var/www/certbot:/var/www/certbot:ro
```

* `live/<dominio>/fullchain.pem`: Certificado + cadena intermedia.
* `live/<dominio>/privkey.pem`: Clave privada.
* `options-ssl-nginx.conf` y `ssl-dhparams.pem`: Cifrados recomendados por certbot.

### Renovación Automática en Modo Webroot (Implementado)
Para evitar detener Nginx al renovar certificados, la validación ACME opera en modo **webroot**:

1. **Servicio `certbot` en Swarm:**
   En `docker-stack.yml`, un contenedor oficial de `certbot` corre en bucle cada 12 horas:
   ```bash
   certbot renew --webroot -w /var/www/certbot
   ```
2. **Desafío HTTP en el puerto 80:**
   Cuando Let's Encrypt valida el dominio, solicita el token en `http://<dominio>/.well-known/acme-challenge/<token>`.
   En `app.conf`, Nginx no redirige esta ruta a HTTPS sino que la sirve directamente desde `/var/www/certbot`:
   ```nginx
   location /.well-known/acme-challenge/ {
       root /var/www/certbot;
   }
   ```
3. **Recarga dinámica de Nginx:**
   El contenedor `reverse-proxy` ejecuta un reload en segundo plano cada 6 horas (`nginx -s reload`) para tomar el nuevo certificado sin cortar conexiones.

---

## 4. El reverse proxy (`app.conf`)

| Directiva | Qué hace |
| :--- | :--- |
| `location /.well-known/acme-challenge/` | Sirve tokens de renovación webroot de Let's Encrypt en el puerto 80 |
| `return 301 https://$host$request_uri;` | Redirige todo el resto del tráfico a HTTPS |
| `listen 443 ssl; http2 on;` | Terminación TLS con soporte de HTTP/2 |
| `resolver 127.0.0.11 valid=10s ipv6=off;` | Resuelve los servicios en **cada request** con el DNS interno de Docker |
| `set $app http://snippetsearcher-app:8080; proxy_pass $app;` | Upstream dinámico en variable para que Nginx levante incluso si el backend está iniciando |
| `error_page 502 503 504 /50x.html;` | Sirve la página de error corporativa limpia cuando un backend está arrancando |

---

## 5. CORS

* **En las VMs (Dev y Prod):** La interfaz web y los backends comparten el mismo origen (`https://snippet26<env>.duckdns.org`). No hay requerimiento de cabeceras CORS en el navegador.
* **En Desarrollo Local:** La UI corre en `http://localhost:5173` y los backends en `http://localhost:19081` (App) y `:19082` (Runner). Los microservicios Spring implementan `allowedOrigins = [http://localhost:5173, http://127.0.0.1:5173]` en `SecurityConfig.kt` y `CorsConfig.kt`.

---

## 6. Cómo probarlo

### Simular renovación de certificados en la VM:
```bash
docker exec -it $(docker ps -q -f name=snippetsearcher_certbot) certbot renew --dry-run --webroot -w /var/www/certbot
# Debe responder: Congratulations, all simulated renewals succeeded
```

### Probar redirección HTTP a HTTPS:
```bash
curl -sI http://snippet26prod.duckdns.org/api/v1/snippets | head -n 3
# Debe responder: HTTP/1.1 301 Moved Permanently con Location: https://...
```

### Probar certificado y vencimiento:
```bash
echo | openssl s_client -connect snippet26prod.duckdns.org:443 -servername snippet26prod.duckdns.org 2>/dev/null \
  | openssl x509 -noout -subject -enddate
```

---

## 7. Preguntas para repasar

1. **¿Dónde termina HTTPS?** En el contenedor `reverse-proxy` (Nginx). Entre Nginx y los microservicios la comunicación es HTTP plano por la red privada overlay de Swarm.
2. **¿Por qué Certbot corre en un contenedor y no en el host?** Para mantener la VM desacoplada y limpia, gestionando dependencias dentro del stack de Docker.
3. **¿Por qué los upstreams van en variables con resolver?** Con upstreams fijos, si un microservicio aún no inició, Nginx fallaba al arrancar (`host not found in upstream`). Con variables y `resolver 127.0.0.11`, Nginx levanta de inmediato y responde con `50x.html` hasta que el servicio esté listo.
