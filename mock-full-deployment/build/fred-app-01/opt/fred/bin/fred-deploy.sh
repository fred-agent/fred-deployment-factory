#!/usr/bin/env bash
# Déploie ou met à jour la pile Fred de cette VM. Idempotent, à lancer en root.
# C'est la seule commande de l'exploitant du client ; la VM redémarre ensuite seule
# la pile via fred-stack.service.
set -euo pipefail

COMPOSE=(podman compose -f /opt/fred/compose.yaml)

# La CA interne entre dans le magasin système : le bundle système (CA publiques +
# CA interne) est monté tel quel dans les conteneurs qui parlent en TLS.
if ! cmp -s /etc/fred/tls/ca.crt /etc/pki/ca-trust/source/anchors/fred-internal-ca.crt; then
    install -m 0644 /etc/fred/tls/ca.crt /etc/pki/ca-trust/source/anchors/fred-internal-ca.crt
    update-ca-trust extract
fi

"${COMPOSE[@]}" --profile jobs pull
# "up -d" ne recrée pas un conteneur dont seule l'image a changé (même tag, nouveau
# contenu) : on retire ceux qui ne tournent plus sur l'image actuelle de leur tag.
for c in $(podman ps -a --format '{{.Names}}'); do
    if [[ $(podman inspect -f '{{.Image}}' "$c") != \
          $(podman image inspect -f '{{.Id}}' "$(podman inspect -f '{{.ImageName}}' "$c")" 2>/dev/null) ]]; then
        echo "Image mise à jour : $c sera recréé"
        podman rm -f "$c" >/dev/null
    fi
done
# Jobs one-shot (migrations) de la VM, dans l'ordre, avant la pile. Au boot,
# fred-stack.service ne fait que "up -d" : les migrations sont déjà appliquées.
if [[ -x /opt/fred/bin/fred-jobs.sh ]]; then
    /opt/fred/bin/fred-jobs.sh
fi
"${COMPOSE[@]}" up -d
systemctl daemon-reload
systemctl enable fred-stack.service
"${COMPOSE[@]}" ps
