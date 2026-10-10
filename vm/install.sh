#!/usr/bin/env bash
# Instala el deploy automático al boot en esta VM. Correr UNA vez por VM, como azureuser:
#   bash ~/infra-repo/vm/install.sh        (o desde cualquier copia del repo)
# Requisitos: swarm ya inicializado y ~/.env con IMAGE_TAG, DOMAIN_NAME y GITHUB_TOKEN.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp "$DIR/boot-deploy.sh" "$HOME/boot-deploy.sh"
chmod +x "$HOME/boot-deploy.sh"
sudo cp "$DIR/snippetsearcher-boot.service" /etc/systemd/system/snippetsearcher-boot.service
sudo systemctl daemon-reload
sudo systemctl enable snippetsearcher-boot.service

echo "Instalado. Para probarlo sin reiniciar:"
echo "  sudo systemctl start snippetsearcher-boot.service && journalctl -u snippetsearcher-boot.service -n 30 --no-pager"
