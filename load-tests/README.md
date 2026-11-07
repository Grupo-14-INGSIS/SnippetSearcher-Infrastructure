# Tests de carga (Locust)

> Guía completa, con qué mirar y qué alertas puede activar: [Documentación/LOCUST.md](../Documentación/LOCUST.md).

`locustfile.py` genera tráfico para verlo en New Relic. **Correrlo solo contra dev**: la VM tiene 2 CPUs y la carga
afecta a todos los servicios. Qué mirar mientras corre: [Documentación/NEW_RELIC.md](../Documentación/NEW_RELIC.md),
sección 12.

| Usuario | Qué hace | Necesita login |
| :--- | :--- | :--- |
| `HealthUser` | Pide `/api/actuator/health` (pasa por nginx, App, Runner y AccessManager) | No |
| `ApiUser` | Lista tus snippets y, si se indica `SNIPPET_ID`, lee uno. Solo lectura | Sí |

## Instalación
```bash
pip install locust
```

## Con interfaz web
```bash
locust -f load-tests/locustfile.py --host https://snippet26dev.duckdns.org HealthUser
```
Abrí `http://localhost:8089`, elegí la cantidad de usuarios (por ejemplo 20) y la velocidad de arranque (por ejemplo 2
por segundo), y tocá **Start**. Los gráficos muestran requests por segundo, tiempos y fallas.

## Sin interfaz (5 minutos, 20 usuarios)
```bash
locust -f load-tests/locustfile.py --host https://snippet26dev.duckdns.org --headless -u 20 -r 2 -t 5m HealthUser
```

## Usuario con login
Necesita el token de tu propio usuario:

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

## Qué esperar
- **APM & Services → AppIngsis_dev:** sube el throughput y el tiempo de respuesta.
- **Alerts:** con el umbral de 0,3 s puede abrirse `Excessive response time` después de unos 5 minutos.
- **Dashboard `Develop`, página `Infraestructura`:** sube la CPU de la VM y de los servicios.
- Cada request lleva un `X-Request-Id` que empieza con `locust-`, para encontrarlo en New Relic:
  `SELECT count(*) FROM Transaction WHERE request_id LIKE 'locust-%' FACET appName SINCE 1 hour ago`
