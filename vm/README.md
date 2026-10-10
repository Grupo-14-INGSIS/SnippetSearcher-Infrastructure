# Deploy automático al prender la VM

## Problema

Los workflows de GitHub (`deploy.yml` y `update_service.yml`) entran por SSH a la VM en el
momento del push. Si la VM está apagada, ese deploy falla y no se reintenta: al prenderla,
Swarm levanta los servicios con las imágenes que tenía cacheadas, o sea las viejas.

## Solución

Un servicio de systemd (`snippetsearcher-boot.service`) corre `boot-deploy.sh` en cada boot:

1. Trae la última versión de este repo (`develop` si `IMAGE_TAG=develop`, `main` si
   `IMAGE_TAG=production`, leído de `~/.env`). El repo es público, no necesita token.
2. Copia `docker-stack.yml`, `reverse-proxy/` y `db/` a `~`, los mismos paths que usa `deploy.yml`.
3. Hace login en GHCR con el `GITHUB_TOKEN` de `~/.env`.
4. `docker stack deploy --with-registry-auth --resolve-image always`: re-resuelve cada tag
   contra GHCR. Los servicios cuya imagen cambió se actualizan con rolling update; los que
   no cambiaron no se tocan.

Es equivalente al `docker compose pull && up -d` que se usaba antes del swarm.

## Instalar (una vez por VM)

```bash
git clone --depth 1 --branch develop https://github.com/Grupo-14-INGSIS/SnippetSearcher-Infrastructure.git ~/infra-repo
bash ~/infra-repo/vm/install.sh
```

En prod usar `--branch main`. El script después mantiene `~/infra-repo` actualizado solo.

Probarlo sin reiniciar:

```bash
sudo systemctl start snippetsearcher-boot.service
journalctl -u snippetsearcher-boot.service -n 30 --no-pager
```

## Ver qué hizo en el último boot

```bash
journalctl -u snippetsearcher-boot.service -b --no-pager
```

## Notas

- Los workflows de GitHub siguen funcionando igual cuando la VM está prendida; esto solo
  cubre el caso "pusheé con la VM apagada".
- Si el `GITHUB_TOKEN` de `~/.env` expira, el pull de imágenes privadas falla. El log lo dice.
- El stack deploy no reinicia servicios cuya imagen y configuración no cambiaron.
