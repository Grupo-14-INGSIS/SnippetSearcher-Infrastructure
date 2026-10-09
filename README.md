# SnippetSearcher - Infrastructure & Deployment

Repositorio central de infraestructura, orquestación y despliegue continuo (CI/CD) para el ecosistema **SnippetSearcher**.

---

## 1. Índice de Documentación Técnica

Toda la documentación arquitectónica y operativa se encuentra en la carpeta [`Documentación/`](./Documentación/):
* **[Arquitectura General](Documentación/ARQUITECTURA.md)**: Justificación técnica de microservicios, bases de datos PostgreSQL, Redis Streams, Nginx y New Relic.
* **[Dockerización y Docker Compose](Documentación/DOCKERIZACION.md)**: Explicación de los Dockerfiles Multi-stage, imágenes publicadas en GHCR y ejecución local con Docker Compose.
* **[Docker Swarm y Ambientes](Documentación/SWARM_Y_AMBIENTES.md)**: Configuración de Stacks en Swarm, 2 réplicas stateless, balanceo interno IPVS, rolling updates y estrategia de branching (`develop` y `production`).
* **[Flujo de un Snippet y Comparativa](Documentación/FLUJO_Y_COMPARATIVA_ARQUITECTURA.md)**: Diagramas PlantUML de secuencia, Nginx como Reverse Proxy y Redis exclusivamente como Message Queue.
* **[Catálogo de Rutas REST](Documentación/RUTAS_REST.md)**: Especificación técnica de endpoints RESTful.
* **[Checklist de Producción](PRODUCCION.md)**: Guía paso a paso para la puesta a punto y mantenimiento de la VM de Producción.

---

## 2. Ejecución en Entorno Local (Docker Desktop / Docker Compose)

Para levantar el ecosistema completo en tu máquina local:

### Requisitos:
* **Docker Desktop** instalado y en ejecución.
* Repositorios clonados en el mismo directorio padre:
  - `SnippetSearcher-Infrastructure`
  - `SnippetSearcher-App`
  - `SnippetSearcher-Runner`
  - `SnippetSearcher-AccessManager`
  - `printscript-ui`

### Levantar el entorno:
```bash
# 1. Posicionarse en el repositorio de infraestructura
cd SnippetSearcher-Infrastructure

# 2. Iniciar todos los servicios, bases de datos, cola y proxy
docker compose up -d --build

# 3. Verificar el estado de los contenedores
docker compose ps
```

### URLs de acceso local:
* **Frontend Web**: `http://localhost:5173` (o a través del proxy `http://localhost`)
* **App Backend**: `http://localhost:19081`
* **Runner Backend**: `http://localhost:19082`
* **AccessManager Backend**: `http://localhost:19083`

### Detener el entorno:
```bash
# Detener contenedores manteniendo volúmenes de datos
docker compose down

# Detener eliminando volúmenes (reseteo limpio de bases de datos)
docker compose down -v
```

---

## 3. Despliegue en Servidores (Docker Swarm / VMs Azure)

En los servidores de Azure (`dev` y `prod`), el sistema corre desacoplado sin código fuente en la máquina virtual, orquestado como un Stack de Docker Swarm con rolling updates automáticos:

| Ambiente | Dominio DuckDNS | Rama Infra | Rama Microservicios | VM Azure (South Africa North) |
| :--- | :--- | :---: | :---: | :--- |
| **Desarrollo (Dev)** | `https://snippet26dev.duckdns.org` | `develop` | `develop` | `102.133.145.119` (`dev`) |
| **Producción (Prod)** | `https://snippet26prod.duckdns.org` | `main` | `production` | `4.222.216.199` (`prod`) |

### Comandos de diagnóstico en las VMs:
```bash
# Ver estado del Stack y réplicas (2/2 en stateless, 1/1 en bases de datos)
docker stack services snippetsearcher

# Ver detalle de réplicas y eventos
docker stack ps snippetsearcher

# Ver logs en vivo de un microservicio
docker service logs -f snippetsearcher_snippetsearcher-app
docker service logs -f snippetsearcher_snippetsearcher-runner
```

---

## 4. Imágenes Docker en GitHub Container Registry (GHCR)

Las imágenes son construidas y publicadas automáticamente por GitHub Actions ante cada commit en las ramas correspondientes:
* `ghcr.io/grupo-14-ingsis/snippetsearcher-app:<tag>`
* `ghcr.io/grupo-14-ingsis/snippetsearcher-runner:<tag>`
* `ghcr.io/grupo-14-ingsis/snippetsearcher-accessmanager:<tag>`
* `ghcr.io/grupo-14-ingsis/printscript-ui:<tag>`

Para descargarlas manualmente desde una terminal con Docker:
```bash
echo "<GITHUB_TOKEN_O_PAT>" | docker login ghcr.io -u <GITHUB_USER> --password-stdin
docker pull ghcr.io/grupo-14-ingsis/snippetsearcher-runner:develop
```