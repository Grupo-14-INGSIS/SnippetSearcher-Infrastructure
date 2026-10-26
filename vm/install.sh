#!/usr/bin/env bash
# Instala el script de ciclo de vida en la VM, fuera del home:
#   /usr/local/sbin/snippetsearcher-lifecycle.sh
#   /etc/systemd/system/snippetsearcher-lifecycle.service
# Se corre una vez por VM, desde la carpeta vm/ del repo:  sudo bash install.sh
set -euo pipefail
cd "$(dirname "$0")"
install -m 0755 snippetsearcher-lifecycle.sh /usr/local/sbin/snippetsearcher-lifecycle.sh
install -m 0644 snippetsearcher-lifecycle.service /etc/systemd/system/snippetsearcher-lifecycle.service
systemctl daemon-reload
systemctl enable snippetsearcher-lifecycle.service
# `start` deja la unidad "activa": es lo que hace que systemd corra el ExecStop en el próximo apagado.
# Con el stack andando, solo revisa el DNS y termina.
systemctl start snippetsearcher-lifecycle.service
systemctl is-enabled snippetsearcher-lifecycle.service
systemctl is-active snippetsearcher-lifecycle.service
