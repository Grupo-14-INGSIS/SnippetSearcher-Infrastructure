#!/usr/bin/env bash
# Deploy automático al prender la VM.
#
# Los workflows de GitHub (deploy.yml / update_service.yml) solo llegan a la VM si está
# prendida en el momento del push. Si estaba apagada, ese deploy se pierde y Swarm levanta
# con las imágenes cacheadas (viejas). Este script corre en el boot (systemd) y hace lo
# mismo que deploy.yml, pero desde adentro de la VM:
#   1. trae la última versión del repo de Infrastructure (es público, no hace falta token)
#   2. copia docker-stack.yml, reverse-proxy/ y db/ a ~ (mismos paths que usa deploy.yml)
#   3. login en GHCR con el GITHUB_TOKEN de ~/.env
#   4. docker stack deploy --resolve-image always: si la imagen del tag cambió en GHCR,
#      Swarm actualiza ese servicio; si no cambió, no lo toca.
#
# Se puede correr a mano también:  bash ~/boot-deploy.sh
set -euo pipefail

HOME_DIR="${HOME:-/home/azureuser}"
cd "$HOME_DIR"

ENV_FILE="$HOME_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# develop -> rama develop ; production -> rama main (mismo mapeo que los workflows)
IMAGE_TAG="${IMAGE_TAG:-develop}"
if [ "$IMAGE_TAG" = "production" ]; then
  BRANCH="main"
else
  BRANCH="develop"
fi
REPO_URL="https://github.com/Grupo-14-INGSIS/SnippetSearcher-Infrastructure.git"
REPO_DIR="$HOME_DIR/infra-repo"
STACK_NAME="snippetsearcher"

log() { echo "[boot-deploy $(date -u +%H:%M:%S)] $*"; }

# 1. Esperar a que docker y el swarm estén listos (en el boot pueden tardar unos segundos)
for _ in $(seq 1 60); do
  if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active; then
    break
  fi
  sleep 2
done
docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active || { log "swarm no activo, salgo"; exit 1; }

# 2. Traer la última versión del repo (clone la primera vez, pull después)
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" fetch --quiet origin "$BRANCH"
  git -C "$REPO_DIR" checkout --quiet "$BRANCH"
  git -C "$REPO_DIR" reset --quiet --hard "origin/$BRANCH"
else
  git clone --quiet --branch "$BRANCH" --depth 1 "$REPO_URL" "$REPO_DIR"
fi
log "repo en $BRANCH @ $(git -C "$REPO_DIR" rev-parse --short HEAD)"

# 3. Dejar los archivos donde los espera el stack (mismos paths que deploy.yml)
mkdir -p "$HOME_DIR/db/app-init" "$HOME_DIR/db/runner-init" "$HOME_DIR/db/accessmanager-init" \
         "$HOME_DIR/reverse-proxy/nginx/conf.d"
cp "$REPO_DIR/docker-stack.yml" "$HOME_DIR/docker-stack.yml"
cp -r "$REPO_DIR/reverse-proxy/." "$HOME_DIR/reverse-proxy/"
cp -r "$REPO_DIR/db/." "$HOME_DIR/db/"

# 4. Login en GHCR (las imágenes son privadas)
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "$GITHUB_TOKEN" | docker login ghcr.io -u "${GHCR_USER:-grupo-14-ingsis}" --password-stdin >/dev/null
else
  log "AVISO: no hay GITHUB_TOKEN en ~/.env; si el login de GHCR expiró el pull puede fallar"
fi

# 5. Deploy. --resolve-image always re-resuelve cada tag contra GHCR: los servicios cuyo
#    digest cambió se actualizan (rolling update), los demás quedan como están.
log "docker stack deploy ($STACK_NAME, IMAGE_TAG=$IMAGE_TAG)"
docker stack deploy --with-registry-auth --resolve-image always -c "$HOME_DIR/docker-stack.yml" "$STACK_NAME"

docker image prune -f >/dev/null || true
docker stack services "$STACK_NAME" --format '{{.Name}} {{.Replicas}} {{.Image}}'
log "listo"
