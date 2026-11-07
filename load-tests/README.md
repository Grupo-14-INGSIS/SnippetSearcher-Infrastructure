# Tests de carga

Scripts de [k6](https://k6.io) para generar tráfico y verlo en New Relic. **Correrlos solo contra dev**: la VM tiene 2
CPUs y la carga afecta a todos los servicios. Detalle de qué mirar en
[Documentación/NEW_RELIC.md](../Documentación/NEW_RELIC.md), sección 12.

| Script | Qué hace | Duración | Necesita login |
| :--- | :--- | :--- | :--- |
| `health.js` | Hasta 20 usuarios contra `/api/actuator/health` | 5 min | No |
| `api-autenticada.js` | Hasta 10 usuarios listando snippets (y leyendo uno, si se indica). Solo lectura | 5 min | Sí |

## Cómo correrlos

Con k6 instalado:
```bash
k6 run -e BASE_URL=https://snippet26dev.duckdns.org load-tests/health.js
```

Sin instalar nada, con Docker (desde la raíz del repo):
```bash
docker run --rm -i grafana/k6 run -e BASE_URL=https://snippet26dev.duckdns.org - < load-tests/health.js
```

## El script con login

Necesita el token de tu propio usuario:

1. Entrá a la app de dev y abrí **DevTools → Network**.
2. Elegí cualquier request a `/api/v1/...` y copiá el valor del header `Authorization` sin la palabra `Bearer`.
3. Opcional: copiá el id de un snippet tuyo para que también lo lea.

```bash
k6 run -e BASE_URL=https://snippet26dev.duckdns.org -e TOKEN=<token> -e SNIPPET_ID=<id> load-tests/api-autenticada.js
```

El token vence: si aparecen errores `401`, sacá uno nuevo. No lo guardes en el repo ni lo compartas.

## Qué esperar

- **APM & Services → AppIngsis_dev:** sube el throughput y el tiempo de respuesta.
- **Alerts:** con el umbral de 0,3 s puede abrirse `Excessive response time` después de unos 5 minutos.
- **Dashboard `Develop`, página `Infraestructura`:** sube la CPU de la VM y de los servicios.
- Cada request de `api-autenticada.js` lleva un `X-Request-Id` que empieza con `k6-`, para encontrarlo en New Relic.
