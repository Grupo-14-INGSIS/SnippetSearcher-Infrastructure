# HTTPS, nginx y CORS

## Índice
- [1. Recorrido de una request](#1-recorrido-de-una-request)
- [2. Dos nginx, dos roles](#2-dos-nginx-dos-roles)
- [3. HTTPS](#3-https)
- [4. El reverse proxy (app.conf)](#4-el-reverse-proxy-appconf)
- [5. CORS](#5-cors)
- [6. Cómo probarlo](#6-cómo-probarlo)
- [7. Preguntas para repasar](#7-preguntas-para-repasar)

---

## 1. Recorrido de una request

```
navegador ──HTTP :80──▶ reverse-proxy ──301──▶ https://<dominio>/...      (siempre a HTTPS)

navegador ──HTTPS :443──▶ reverse-proxy (termina TLS con el certificado de Let's Encrypt)
                            ├─ /          ──▶ snippetsearcher-ui:80             (nginx de la UI: HTML/JS/CSS)
                            ├─ /api/      ──▶ snippetsearcher-app:8080          (/api/... tal cual)
                            ├─ /runner/   ──▶ snippetsearcher-runner:8080       (/runner/x -> /x)
                            └─ /access/   ──▶ snippetsearcher-accessmanager:8080 (/access/x -> /x)
```

- Afuera todo es HTTPS. Adentro, entre nginx y los servicios, es HTTP plano por la red overlay de Swarm, que no
  sale de la VM.
- nginx manda a `snippetsearcher-app` y Swarm reparte entre las réplicas: la IP virtual del servicio balancea.
  nginx no balancea.
- La UI y la API comparten dominio. Por eso en las VMs **no hay CORS** (ver §5).

---

## 2. Dos nginx, dos roles

| | Reverse proxy (Infra) | nginx de la UI |
| :--- | :--- | :--- |
| Repo / config | `SnippetSearcher-Infrastructure` → `reverse-proxy/nginx/conf.d/app.conf` | `printscript-ui` → `nginx.conf` |
| Imagen | `nginx:alpine` oficial | La de la UI: el `Dockerfile` compila el frontend con Node y lo copia a un `nginx:alpine` |
| Servicio de Swarm | `reverse-proxy` (1 réplica) | `snippetsearcher-ui` (2 réplicas) |
| Puertos | **80 y 443 públicos** | 80 en la red interna (y 5173 publicado) |
| Qué hace | Entrada: redirige a HTTPS, termina TLS, rutea por path, agrega `X-Forwarded-*` | **Sirve archivos estáticos**: gzip, headers de seguridad y caché, y cualquier ruta → `index.html` (SPA) |
| Cuándo cambia | Rutas, dominio, certificados | Con cada versión de la UI |

**Por qué dos.** Cada uno cambia por motivos distintos y viaja con su repo. Cuando cambia el frontend, el CI de
la UI publica una imagen nueva y `update_service.yml` actualiza solo `snippetsearcher-ui`: la entrada del sitio
no se toca. Juntarlos obligaría a reconstruir el proxy con cada cambio de la UI, o a copiar el frontend
compilado a la VM. Un nginx de estáticos usa pocos MB: en la VM lo que pesa son las JVM.

Los dos **corren en la VM como contenedores de Swarm**: no están instalados en Ubuntu (no hay `apt install
nginx`) y no tienen archivos en el home. La config del proxy viaja como **config de Swarm** `nginx_conf_<hash>`
(ver VM_LIMPIA.md).

---

## 3. HTTPS

**Certificados.** Son de **Let's Encrypt** y viven en el host, en `/etc/letsencrypt` (lo maneja **certbot**, a
nivel sistema, fuera del home). El reverse proxy los monta en solo lectura:

```yaml
reverse-proxy:
  volumes:
    - /etc/letsencrypt:/etc/letsencrypt:ro
```

| Archivo | Para qué |
| :--- | :--- |
| `live/<dominio>/fullchain.pem` | Certificado + cadena intermedia (`ssl_certificate`) |
| `live/<dominio>/privkey.pem` | Clave privada (`ssl_certificate_key`). Solo la lee root. |
| `options-ssl-nginx.conf` | Protocolos y cifrados recomendados por certbot (`include`) |
| `ssl-dhparams.pem` | Parámetros Diffie-Hellman (`ssl_dhparam`) |

`<dominio>` sale de la variable `DOMAIN_NAME` del environment de GitHub (`snippet26dev.duckdns.org` /
`snippet26prod.duckdns.org`). Al arrancar, el contenedor hace `envsubst '$DOMAIN_NAME'` sobre `app.conf`:
reemplaza solo esa variable y deja intactas las de nginx (`$host`, `$app`, ...).

**HTTP → HTTPS.** El bloque del puerto 80 responde `301` a la misma URL con `https://`. Si se entra por IP, también
redirige, pero el navegador avisa que el certificado no corresponde (es del dominio, no de la IP).

**HTTP/2** está activado en el 443 (`http2 on;`).

**Renovación (cada 90 días).** La hace certbot en el host con un timer de systemd. **A revisar:** la validación
por HTTP de Let's Encrypt entra por el puerto 80 a `/.well-known/acme-challenge/`, y con esta config esa ruta se
redirige a HTTPS y no hay regla para servirla. Si certbot renueva en modo *standalone* además necesita el puerto
80 libre, y lo ocupa el contenedor. Para ver cómo está configurado y hasta cuándo vale:

```bash
sudo grep -h authenticator /etc/letsencrypt/renewal/*.conf
sudo certbot certificates | grep -E "Domains|Expiry"
sudo certbot renew --dry-run      # prueba la renovación sin cambiar nada
```

Si el `--dry-run` falla, las opciones son: renovar parando un momento el proxy
(`--pre-hook "docker service scale snippetsearcher_reverse-proxy=0" --post-hook "docker service scale
snippetsearcher_reverse-proxy=1"`), o agregar a `app.conf`, en el bloque del 80, un `location
/.well-known/acme-challenge/` servido desde un directorio montado (modo `webroot`).

---

## 4. El reverse proxy (`app.conf`)

| Directiva | Qué hace |
| :--- | :--- |
| `return 301 https://$host$request_uri;` (puerto 80) | Todo a HTTPS |
| `listen 443 ssl; http2 on;` | HTTPS con HTTP/2 |
| `resolver 127.0.0.11 valid=10s ipv6=off; resolver_timeout 5s;` | Resuelve los servicios en **cada request** con el DNS interno de Docker |
| `set $app http://snippetsearcher-app:8080; proxy_pass $app;` | El upstream va en una variable para que se resuelva en runtime |
| `rewrite ^/runner/(.*)$ /$1 break;` | Saca el prefijo `/runner/` (lo mismo con `/access/`) |
| `proxy_set_header Host / X-Real-IP / X-Forwarded-For / X-Forwarded-Proto https` | El backend ve el host, la IP y el protocolo originales |
| `proxy_read_timeout 300s` (`600s` en `/runner/`) | Ejecuciones y tests largos |

**Por qué los upstreams van en variables.** Con `proxy_pass http://snippetsearcher-app:8080` fijo, nginx resuelve
el nombre **al arrancar**: si el App todavía no está en la red (por ejemplo al prender la VM), nginx no levanta
(`host not found in upstream`) y el sitio entero queda caído. Con una variable y `resolver`, nginx arranca
siempre y esa ruta devuelve 502 hasta que el servicio esté listo.

---

## 5. CORS

**Qué es.** Un navegador bloquea que una página de un origen (esquema + dominio + puerto) lea respuestas de otro,
salvo que el servidor lo permita con headers `Access-Control-Allow-*`. Para pedidos que no son "simples" (con
`Authorization` o JSON) el navegador manda antes un **preflight** (`OPTIONS`) preguntando si puede.

**Cuándo aplica acá.**

| Dónde | Origen de la UI | Origen de la API | ¿CORS? |
| :--- | :--- | :--- | :--- |
| VM dev / prod | `https://snippet26dev.duckdns.org` | el mismo (`/api/`, `/runner/`) | **No**: mismo origen |
| Local | `http://localhost:5173` | `http://localhost:19081` (App), `:19082` (Runner) | **Sí** |

CORS solo lo controla el navegador: no protege de `curl` ni de otro servidor. La protección real de la API es
el JWT de Auth0.

**Antes (mal).** En App (`SecurityConfig.kt`) y Runner (`CorsConfig.kt`):

```kotlin
allowedOriginPatterns = listOf("*")   // cualquier origen
allowCredentials = true               // y con credenciales
```

`"*"` + credenciales hace que Spring devuelva como permitido el `Origin` exacto de cualquier sitio: equivale a no
tener CORS. Además `allowCredentials` sirve para cookies, y acá la autenticación es `Authorization: Bearer`.

**Ahora.**

```kotlin
allowedOrigins = [ https://snippet26dev.duckdns.org, https://snippet26prod.duckdns.org,
                   http://localhost:5173, http://127.0.0.1:5173 ]      // configurable
allowedMethods = GET, POST, PUT, DELETE, OPTIONS, PATCH
allowedHeaders = Authorization, Content-Type, Accept, X-Request-Id    // los que manda la UI
exposedHeaders = Content-Disposition                                  // App: nombre del archivo en la descarga
allowCredentials = false
maxAge = 3600                                                         // el navegador cachea el preflight 1 h
```

**Configurable** con la propiedad `app.cors.allowed-origins` (lista separada por comas), o con la variable de
entorno equivalente `APP_CORS_ALLOWED_ORIGINS`. Si no se define, se usan los cuatro orígenes de arriba. Para
agregar un dominio nuevo (por ejemplo, otra VM), se define esa variable en el servicio, en `docker-stack.yml`.

El AccessManager no tiene CORS: solo lo llama el App desde el servidor, nunca el navegador. Los nginx no agregan
headers de CORS: lo resuelven los servicios Spring.

---

## 6. Cómo probarlo

```bash
# 80 -> 443
curl -sI http://snippet26dev.duckdns.org/api/v1/snippets | head -n 3          # 301 + Location: https://...

# Certificado y vencimiento
echo | openssl s_client -connect snippet26dev.duckdns.org:443 -servername snippet26dev.duckdns.org 2>/dev/null \
  | openssl x509 -noout -subject -enddate

# CORS: origen permitido -> 200 con Access-Control-Allow-Origin
curl -si -X OPTIONS http://localhost:19081/api/v1/snippets \
  -H "Origin: http://localhost:5173" -H "Access-Control-Request-Method: GET" | grep -i access-control

# CORS: otro origen -> 403 sin Access-Control-Allow-Origin
curl -si -X OPTIONS http://localhost:19081/api/v1/snippets \
  -H "Origin: https://evil.example.com" -H "Access-Control-Request-Method: GET" | head -n 1
```

En los tests: `SecurityConfigCorsTest` y los preflight de `SnippetControllerTest` (App), `CorsConfigTest` (Runner).

---

## 7. Preguntas para repasar

1. **¿Dónde se termina el HTTPS?** En el reverse proxy. Adentro de la VM, entre nginx y los servicios, es HTTP.
2. **¿Por qué hay dos nginx?** Uno es la entrada (HTTPS y ruteo) y es infraestructura; el otro sirve el frontend
   y viaja con la imagen de la UI, así la UI se despliega sola.
3. **¿Dónde están los certificados y quién los renueva?** En `/etc/letsencrypt` del host; los renueva certbot.
4. **¿Por qué nginx resuelve los servicios en cada request?** Para arrancar aunque el App no esté listo.
5. **¿Por qué en la VM no hay CORS?** La UI y la API están en el mismo origen.
6. **¿Qué estaba mal con `*` + `allowCredentials(true)`?** Permitía cualquier origen, con credenciales.
7. **¿CORS protege la API?** No: es una regla del navegador. La API la protege el JWT.
