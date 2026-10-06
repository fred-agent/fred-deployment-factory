SHELL := /bin/bash
include config.env

COMPOSE := docker compose --env-file config.env -f simulation/compose.yaml

.PHONY: help secrets pki render images vms vms-build registry-push deliver deploy deploy-sto deploy-app \
        verify status logs bootstrap-token shell-sto shell-app stop down destroy

help: ## Liste les cibles
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

# ------------------------------------------------------------ Hors réseau
secrets: ## Génère les secrets manquants (n'écrase rien)
	@scripts/secrets.sh

pki: ## Génère la CA interne et le certificat de fred-sto-01
	@scripts/pki.sh

render: secrets pki ## Rend les bundles des deux VMs dans build/
	@$(PYTHON) scripts/render.py

# ------------------------------------------------- Réseau requis (une fois)
images: ## Construit les images durcies (ONLY="nom ..." pour en choisir, REFRESH=1 sans cache)
	@REFRESH=$(REFRESH) scripts/build-images.sh $(ONLY)

vms-build: ## Construit l'image "VM RHEL 9 + podman" (réseau requis)
	$(COMPOSE) build

vms: ## Démarre le registry et les deux VMs
	$(COMPOSE) up -d
	@for vm in fred-sto-01 fred-app-01; do \
	    until docker exec $$vm systemctl is-system-running --wait >/dev/null 2>&1 || \
	          docker exec $$vm systemctl is-system-running 2>/dev/null | grep -q degraded; do sleep 2; done; \
	    echo "$$vm : systemd prêt"; done

registry-push: ## Pousse les images connues dans le registry (VAR=image pour compléter)
	@scripts/registry-push.sh $(IMAGES)

# ---------------------------------------------------------- Déploiement
deliver: render ## Copie les bundles dans les VMs
	@scripts/deliver.sh fred-sto-01
	@scripts/deliver.sh fred-app-01

deploy-sto: ## Lance fred-deploy.sh sur fred-sto-01
	docker exec fred-sto-01 /opt/fred/bin/fred-deploy.sh

deploy-app: ## Lance fred-deploy.sh sur fred-app-01
	docker exec fred-app-01 /opt/fred/bin/fred-deploy.sh

deploy: deliver deploy-sto deploy-app ## Livre puis déploie les deux VMs (stockage d'abord)

verify: ## Contrôle chiffrement, refus du clair et config OIDC servie
	@scripts/verify.sh

# ------------------------------------------------------------- Exploitation
status: ## Conteneurs podman de chaque VM
	@for vm in fred-sto-01 fred-app-01; do echo "== $$vm"; docker exec $$vm podman ps -a --format '{{.Names}}\t{{.Status}}'; done

logs: ## Journaux d'un conteneur : make logs VM=fred-app-01 C=control-plane-backend
	docker exec $(VM) podman logs --tail 200 -f $(C)

bootstrap-token: ## Affiche le jeton de bootstrap du premier administrateur
	@grep '^FRED_BOOTSTRAP_TOKEN=' secrets/generated.env | cut -d= -f2-

shell-sto: ## Shell root dans fred-sto-01
	docker exec -it fred-sto-01 bash

shell-app: ## Shell root dans fred-app-01
	docker exec -it fred-app-01 bash

stop: ## Arrête les VMs (données conservées)
	$(COMPOSE) stop

down: ## Supprime les VMs, conserve volumes (données, images podman, registry)
	$(COMPOSE) down

destroy: ## Supprime tout, volumes compris (base et objets perdus)
	$(COMPOSE) down -v
	rm -rf build
