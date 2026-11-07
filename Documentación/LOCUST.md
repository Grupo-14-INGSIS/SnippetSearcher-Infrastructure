# Tests de carga con Locust

Archivo: [`load-tests/locustfile.py`](../load-tests/locustfile.py). Sirve para generar tráfico y ver en New Relic cómo
responde el sistema, y para mostrar alertas en una demo. **Correrlo solo contra dev**: la VM tiene 2 CPUs y la carga
afecta a todos los servicios.

## Qué hace

Simula usuarios que hacen requests sin parar. Hay dos tipos y se elige uno al lanzarlo:

| Usuario | Qué pide | Recorrido de cada request | Necesita login |
| :--- | :--- | :--- | :--- |
| `HealthUser` | `GET /api/actuator/health`, cada 0,5 a 1,5 s | nginx → App → base de App, Redis, Runner y AccessManager | No |
| `ApiUser` | `GET /api/v1/snippets` (3 de cada 4 veces) y `GET /api/v1/snippets/{id}` (1 de cada 4, si se indica `SNIPPET_ID`), cada 1 a 2 s | nginx → App → AccessManager y Runner | Sí, con tu token |

- **No modifica datos:** los dos solo leen.
- **Marca sus requests:** cada uno lleva un `X-Request-Id` que empieza con `locust-`, para encontrarlo en New Relic.
- **Valida la respuesta:** `HealthUser` cuenta como falla todo lo que no sea `200` con `"status":"UP"`.

## Cómo correrlo

### Instalación
```bash
pip install locust
```

### Con interfaz web
```bash
locust -f load-tests/locustfile.py --host https://snippet26dev.duckdns.org HealthUser
```
1. Abrí `http://localhost:8089`.
2. Completá **Number of users** (cuántos usuarios simultáneos) y **Ramp up** (cuántos se suman por segundo).
3. Tocá **Start**. Para cortar, **Stop**.

### Sin interfaz
```bash
locust -f load-tests/locustfile.py --host https://snippet26dev.duckdns.org --headless -u 20 -r 2 -t 10m HealthUser
```
`-u` son los usuarios, `-r` cuántos se suman por segundo y `-t` la duración. Al terminar muestra un resumen en la
consola.

### Sin instalar nada (Docker)
```bash
docker run --rm -p 8089:8089 -v "$(pwd)/load-tests:/mnt/locust" locustio/locust -f /mnt/locust/locustfile.py --host https://snippet26dev.duckdns.org HealthUser
```

### `ApiUser`, con login
1. Entrá a la app de dev y abrí **DevTools → Network**.
2. Elegí un request a `/api/v1/...` y copiá el valor del header `Authorization`, sin la palabra `Bearer`.
3. Opcional: copiá el id de un snippet tuyo.

```bash
# Linux / macOS / Git Bash
TOKEN=<token> SNIPPET_ID=<id> locust -f load-tests/locustfile.py --host https://snippet26dev.duckdns.org ApiUser
```
```powershell
# PowerShell
$env:TOKEN="<token>"; $env:SNIPPET_ID="<id>"; locust -f load-tests/locustfile.py --host https://snippet26dev.duckdns.org ApiUser
```
El token vence: si aparecen errores `401`, sacá uno nuevo. No lo guardes en el repo ni lo compartas.

## Qué mirar

### En Locust
| Pestaña | Qué muestra |
| :--- | :--- |
| **Statistics** | Requests por segundo, tiempos (mediana, p95, p99) y cantidad de fallas por endpoint |
| **Charts** | Evolución de requests por segundo, tiempos de respuesta y usuarios |
| **Failures** | Qué falló y con qué mensaje |

### En New Relic
| Dónde | Qué esperar |
| :--- | :--- |
| **APM & Services → AppIngsis_dev** | Sube el throughput y el tiempo de respuesta |
| **APM & Services → RunnerIngsis_dev / AccessManagerIngsis_dev** | También reciben tráfico: App les pregunta en cada request |
| **Traces** | Trazas de `/api/actuator/health` o `/api/v1/snippets`, con el tiempo de cada servicio |
| **Dashboard `Develop` → página `Infraestructura`** | Sube la CPU y la memoria de la VM y de los servicios |
| **Alerts → Issues & Activity** | Las alertas que se abran (ver abajo) |

Consultas útiles:
```sql
-- Requests de Locust por servicio
SELECT count(*), average(duration), percentile(duration, 95) FROM Transaction WHERE request_id LIKE 'locust-%' FACET appName SINCE 30 minutes ago

-- Tiempo de respuesta de App durante la prueba
SELECT average(duration) FROM Transaction WHERE appName = 'AppIngsis_dev' TIMESERIES SINCE 30 minutes ago

-- CPU de la VM durante la prueba
SELECT average(cpuPercent) FROM SystemSample WHERE environment = 'develop' TIMESERIES SINCE 30 minutes ago
```

## Qué alertas puede activar

Ninguna se activa con seguridad: depende de cuánto aguante la VM. Por eso conviene empezar con pocos usuarios e ir
subiendo.

| Alerta | Cuándo se activa | Cómo intentarlo |
| :--- | :--- | :--- |
| `Excessive response time` | Promedio de App mayor a 0,3 s durante 5 min | Es la más probable. `HealthUser` con 20 usuarios durante 10 min; si no alcanza, subir a 50 |
| `VM - CPU alta` | CPU de la VM mayor a 85% durante 10 min | Subir usuarios hasta que la CPU pase el 85% en el dashboard y sostenerlo más de 10 min |
| `Develop backend caído` | El health de dev no responde `UP` durante 5 min | Solo si la VM se satura tanto que el chequeo de Synthetics falla. Es una señal de que la carga es demasiada |
| `High Application Response Time` | El tiempo de respuesta se aparta de lo habitual | Puede saltar con cualquier carga sostenida. Depende de lo que New Relic aprendió del tráfico normal |

No activa `Error overflow`, `Servicio sin contenedores` ni `Servicio con réplica caída`, salvo que la carga tire algún
servicio. Si pasa, conviene frenar la prueba.

Al terminar, las alertas se cierran solas cuando los valores vuelven a la normalidad. Puede tardar unos minutos.

## Para tener en cuenta
- **Solo dev:** en producción afectaría a los usuarios reales y te dispararía las alertas de producción.
- **No probado todavía:** el `locustfile.py` no se corrió contra el sitio real. Los números de usuarios de la tabla
  son un punto de partida, no un valor medido.
- Más detalle de cada alerta y cómo mostrar las demás: [NEW_RELIC.md](NEW_RELIC.md), sección 9.
