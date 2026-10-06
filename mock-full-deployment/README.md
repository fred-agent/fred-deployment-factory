# Maquette de déploiement client : Fred sur 2 VMs RHEL 9, podman compose, Entra ID

Ce dépôt simule la livraison des images hardenées de Fred chez un client. Le client
fournit deux VMs RHEL 9 qu'**on ne gère pas** : on lui remet un bundle par VM et une
seule commande à lancer. Ensuite, la VM redémarre la pile toute seule.

| | |
|---|---|
| Application | Fred, branche `feat/use-keycloack-only-as-an-idp` |
| Fournisseur d'identité | Microsoft Entra ID (kit : `../test-entra-perso/GUIDE-ENTRA-ID.md`) |
| VMs | `fred-sto-01` (stockage), `fred-app-01` (applicatif), RHEL 9 (UBI 9 + systemd) |
| Orchestration sur les VMs | `podman compose` (podman rootful + podman-compose), unité systemd |
| Images | registry local `registry.fred.lan:5000`, seule source autorisée pour les VMs |
| Entre les VMs | tout chiffré en TLS, avec vérification du certificat serveur |

---

## 1. Architecture

```
 Poste (navigateur)                         Microsoft Entra ID   API LLM (Mistral)
 http://localhost:5173 ─┐                      ▲  HTTPS 443         ▲ HTTPS 443
                        │ (port publié)        │                    │
 ┌──────────────────────▼──── LAN client 10.89.10.0/24 ─────────────┼───────────────┐
 │  fred-app-01  10.89.10.21                    │                    │               │
 │   frontend :8080 ──► control-plane-backend, knowledge-flow-backend, fred-agents   │
 │                      control-plane-worker, knowledge-flow-worker                  │
 │                      openfga, temporal (+ jobs de migration)                      │
 │        │ Postgres TLS :5432 (verify-full)   │ S3 HTTPS :8333 (CA interne)        │
 │        ▼                                    ▼                                     │
 │  fred-sto-01  10.89.10.11 :  postgres (pgvector) · seaweedfs                      │
 │                                                                                   │
 │  registry.fred.lan  10.89.10.5 : miroir d'images du client                        │
 └───────────────────────────────────────────────────────────────────────────────────┘
```

**Flux réseau**

| De | Vers | Port | Protocole |
|---|---|---|---|
| Navigateur | fred-app-01 (frontend) | 8080 (publié en `localhost:5173`) | HTTP, voir §6 |
| Navigateur | `login.microsoftonline.com` | 443 | HTTPS |
| fred-app-01 | fred-sto-01 Postgres | 5432 | **TLS 1.2+**, `verify-full` |
| fred-app-01 | fred-sto-01 S3 | 8333 | **HTTPS**, CA interne |
| fred-app-01 | `login.microsoftonline.com`, `api.mistral.ai` | 443 | HTTPS |
| fred-sto-01, fred-app-01 | registry.fred.lan | 5000 | HTTP (maquette) |

Tout le reste est fermé : les ports internes de SeaweedFS (9333, 8080, 8888) ne
sortent pas de fred-sto-01, et Temporal, OpenFGA et les backends ne sortent pas de
fred-app-01.

**Écarts avec les configurations `configuration_prod.yaml` du dépôt** (tous écrits par
`scripts/render.py`, configurations validées contre leur schéma JSON) :

- **Pas d'OpenSearch** dans cette pile : vecteurs dans Postgres (`vector_store: pgvector`),
  logs applicatifs sur la sortie standard (donc journald) ; `log_store: in_memory` pour la
  copie consultable dans l'UI (`stdout` est accepté par le schéma mais refusé au démarrage),
  `mcp.opensearch_ops_enabled: false`. Les KPI se replient sur les logs.
- Identité Entra : mêmes valeurs que `deploy/charts/fred/values-entra.example.yaml` et que
  `generer-configs.sh` du kit, avec `FRED_JWT_MAX_LIFETIME_SECONDS=6000` (guide §7.1).
- Jeton de bootstrap par variable d'environnement (`bootstrap_token_env_var`), comme le
  chart Helm, et non par fichier.
- Catalogue de runtimes réduit à `fred-agents` ; applications et systèmes d'information
  désactivés ; URLs `localhost` remplacées par les noms des conteneurs.

---

## 2. Chemins dans les VMs

Même convention sur les deux VMs : `/opt/fred` = ce qui s'exécute, `/etc/fred` =
configuration et secrets, `/var/lib/fred` = données.

### fred-sto-01

| Chemin | Contenu | Mode / propriétaire |
|---|---|---|
| `/opt/fred/compose.yaml` | pile podman (postgres, seaweedfs) | 0644 root |
| `/opt/fred/.env` | images et IP d'écoute (non secret) | 0644 root |
| `/opt/fred/bin/fred-deploy.sh` | **la** commande de l'exploitant | 0755 root |
| `/etc/fred/secrets/postgres.env` | mots de passe Postgres (admin + 3 comptes) | 0600 root |
| `/etc/fred/seaweedfs/s3.json` | identité S3 (clé + secret) | 0600 uid 1000 |
| `/etc/fred/postgres/pg_hba.conf` | accès : TLS seulement, fred-app-01 seulement | 0644 root |
| `/etc/fred/postgres/initdb/` | création des bases (1er démarrage uniquement) | 0755 root |
| `/etc/fred/tls/ca.crt` | CA interne | 0644 root |
| `/etc/fred/tls/postgres/server.{crt,key}` | certificat de `fred-sto-01.fred.lan` | clé 0600 uid 999 |
| `/etc/fred/tls/seaweedfs/server.{crt,key}` | même certificat, pour S3 | clé 0600 uid 1000 |
| `/var/lib/fred/postgres/` | **données Postgres** (`pgdata/`) | 0700 uid 999 |
| `/var/lib/fred/seaweedfs/` | **objets S3** (volumes, filer, master) | 0700 uid 1000 |
| `/etc/systemd/system/fred-stack.service` | redémarrage de la pile au boot | 0644 root |

### fred-app-01

| Chemin | Contenu | Mode / propriétaire |
|---|---|---|
| `/opt/fred/compose.yaml` | pile podman (8 services + 6 jobs one-shot, profil `jobs`) | 0644 root |
| `/opt/fred/.env` | images, nom et IP (non secret) | 0644 root |
| `/opt/fred/bin/fred-deploy.sh` | **la** commande de l'exploitant | 0755 root |
| `/opt/fred/bin/fred-jobs.sh` | jobs one-shot dans l'ordre (appelé par `fred-deploy.sh`) | 0755 root |
| `/etc/fred/config/control-plane-backend.yaml` | configuration CP (et son worker) | 0644 root |
| `/etc/fred/config/knowledge-flow-backend.yaml` | configuration KF (et son worker) | 0644 root |
| `/etc/fred/config/fred-agents.yaml` | configuration du runtime | 0644 root |
| `/etc/fred/config/{models,mcp}_catalog.yaml`, `conversation_policy_catalog.yaml` | catalogues | 0644 root |
| `/etc/fred/secrets/common.env` | mot de passe Postgres `fred`, secret S3, clé OpenFGA | 0600 root |
| `/etc/fred/secrets/control-plane.env` | secret Entra CP, jeton de bootstrap | 0600 root |
| `/etc/fred/secrets/knowledge-flow.env` | secret Entra KF, clé LLM | 0600 root |
| `/etc/fred/secrets/fred-agents.env` | secret Entra Runtime, clé LLM | 0600 root |
| `/etc/fred/secrets/openfga.env` | URI datastore (mot de passe inclus), clé prépartagée | 0600 root |
| `/etc/fred/secrets/temporal.env` | mot de passe Postgres `temporal` | 0600 root |
| `/etc/fred/tls/ca.crt` | CA interne, ajoutée au magasin système par `fred-deploy.sh` | 0644 root |
| `/etc/pki/ca-trust/source/anchors/fred-internal-ca.crt` | idem, côté système RHEL | 0644 root |
| `/etc/systemd/system/fred-stack.service` | redémarrage de la pile au boot | 0644 root |

fred-app-01 ne garde **aucune donnée** : Postgres et S3 sont sur fred-sto-01.

Chaque conteneur ne reçoit que ses secrets (fichiers `env_file` lus par podman, jamais
montés). Les configurations YAML ne contiennent aucun secret.

**Logs** : podman écrit dans journald (`/etc/containers/containers.conf.d/50-fred.conf`).
`journalctl CONTAINER_NAME=control-plane-backend -f` ou `podman logs -f control-plane-backend`.

---

## 3. Chiffrement entre les VMs et impact sur Fred

**Conclusion : aucun changement de code Fred n'est nécessaire.** Tout passe par la
configuration et des variables d'environnement standard. C'est vérifié (voir §8).

| Flux | Comment c'est chiffré | Ce que ça demande à Fred |
|---|---|---|
| Fred → Postgres | `ssl=on` côté serveur ; `pg_hba` rejette tout ce qui n'est pas TLS | `PGSSLMODE=verify-full` + `PGSSLROOTCERT`. libpq (psycopg2, psycopg 3) **et** asyncpg lisent ces variables : les moteurs sync et async de Fred chiffrent et authentifient le serveur. |
| OpenFGA → Postgres | idem | `?sslmode=verify-full&sslrootcert=…` dans l'URI |
| Temporal → Postgres | idem | `SQL_TLS_ENABLED`, `SQL_CA`, `SQL_HOST_VERIFICATION`, `SQL_HOST_NAME` ; `--tls` pour le job de schéma |
| Fred → S3 | SeaweedFS sert S3 en HTTPS uniquement | `secure: true` + endpoint `https://` ; le client minio lit `SSL_CERT_FILE` |

Points d'attention :

1. **`SSL_CERT_FILE` doit contenir les CA publiques ET la CA interne.** S'il ne contenait
   que la CA interne, les appels à Entra et à l'API LLM échoueraient. On monte donc le
   bundle système RHEL (`/etc/pki/tls/certs/ca-bundle.crt`), dans lequel
   `fred-deploy.sh` a ajouté la CA interne.
2. **Le certificat doit porter le nom utilisé** (`fred-sto-01.fred.lan`) : `verify-full`
   vérifie le nom. Un renommage de la VM impose un nouveau certificat.
3. **Coût** : une poignée de main TLS par nouvelle connexion. Les pools SQLAlchemy et
   HTTP réutilisent les connexions : impact négligeable en régime établi.
4. **DuckDB ne lit que le magasin de CA du système de l'image.** Les requêtes
   tabulaires de Knowledge Flow lisent les Parquet par URL présignée
   (`access_mode: presigned_url`) via DuckDB `httpfs`, qui embarque curl : il ignore
   `SSL_CERT_FILE` et `CURL_CA_BUNDLE`, et refusait donc le certificat de fred-sto-01
   (vérifié). Le compose monte le bundle de la VM à la place du magasin de l'image
   (`/etc/ssl/certs/ca-certificates.crt` pour Debian, `/etc/pki/tls/certs/ca-bundle.crt`
   pour UBI) dans tous les conteneurs Fred : lecture vérifiée, sans changement de code.
5. **Les URL présignées destinées au navigateur ne fonctionnent pas** (avatars et
   bannières du Control Plane) : elles sont signées pour `https://fred-sto-01.fred.lan:8333`,
   que le navigateur ne joint pas et dont il ne connaît pas la CA. Ce n'est pas lié au
   chiffrement mais à la topologie. Fred prévoit `content_storage.public_endpoint`,
   mais il faut alors un point d'entrée joignable par le navigateur qui relaie vers S3
   en conservant l'en-tête `Host` (la signature V4 le couvre) : le nginx du frontend
   n'a pas de point d'extension pour cela. Chez un client, c'est une route du reverse
   proxy. **Non traité dans la maquette.**

**Rotation** : nouveau certificat dans `/etc/fred/tls/…`, puis `fred-deploy.sh` sur
fred-sto-01 (`podman compose up -d` recrée les conteneurs dont un fichier a changé ;
sinon `podman restart postgres seaweedfs`). La CA ne change pas, rien à faire côté app.

---

## 4. Contenu du dépôt

| Chemin | Rôle |
|---|---|
| `ARCHITECTURE.md` | schémas de l'infrastructure et des piles, images durcies |
| `config.env` | paramètres non secrets (IP, noms, chemins du kit Entra et du dépôt Fred) |
| `images.tsv` | catalogue des images du registry ; les images Fred hardenées sont à compléter |
| `simulation/` | **ce que fournit le client** : 2 VMs RHEL 9 (+ podman) et le registry miroir |
| `bundles/` | **ce qu'on livre** : sources des fichiers posés dans chaque VM |
| `scripts/secrets.sh` | génère les secrets manquants dans `secrets/` (n'écrase jamais) |
| `scripts/pki.sh` | CA interne et certificat de fred-sto-01, dans `secrets/pki/` |
| `scripts/render.py` | produit `build/<vm>/`, copie conforme de l'arborescence de chaque VM |
| `scripts/deliver.sh` | copie `build/<vm>/` dans la VM et applique modes et propriétaires |
| `scripts/registry-push.sh` | remplit le registry |
| `scripts/verify.sh` | contrôle conteneurs, chiffrement, refus du clair, OIDC servi |

`secrets/` et `build/` sont versionnés pour cette maquette de test (clé LLM et secrets Entra remplacés par `CHANGE_ME`).

---

## 5. Mise en route

Prérequis sur le poste : Docker (avec compose), `openssl`, le dépôt Fred (pour ses
`configuration_prod.yaml` et un venv avec `pyyaml` et `jsonschema`), et le kit Entra
déjà passé (`test-entra-perso/secrets/entra.env` rempli, guide §3 ou §4).

```bash
make secrets          # puis remplir secrets/llm.env (OPENAI_API_KEY = clé Mistral)
make render           # hors ligne : secrets, PKI, build/ ; échoue si une valeur manque

# --- réseau nécessaire à partir d'ici ---
make vms-build        # image "RHEL 9 + podman" (dnf dans les dépôts UBI)
make vms              # registry + fred-sto-01 + fred-app-01, attend systemd
make registry-push IMAGES="CONTROL_PLANE_IMAGE=… KNOWLEDGE_FLOW_IMAGE=… FRED_AGENTS_IMAGE=… FRONTEND_IMAGE=…"
make deploy           # livre les bundles, puis fred-deploy.sh : stockage d'abord
make verify
```

Puis, dans une fenêtre privée, <http://localhost:5173/> : connexion Microsoft,
conditions d'utilisation, puis **bootstrap administrateur** avec `make bootstrap-token`.
La suite du parcours de test est celle du guide Entra §5.5.

Exploitation : `make status`, `make logs VM=fred-app-01 C=knowledge-flow-backend`,
`make shell-app`, `make stop` / `make vms` (les VMs redémarrent la pile seules),
`make destroy` (efface aussi les données).

**Mettre à jour les images** : pousser la nouvelle image avec le même tag, puis
`make deploy-app` (`fred-deploy.sh` fait `pull`, `fred-jobs.sh`, puis `up -d`). Les jobs de migration
Alembic tournent à chaque déploiement, avant les backends.

---

## 6. Choix de la maquette et limites

- **Accès navigateur en HTTP sur `localhost:5173`.** C'est l'URI de redirection SPA déjà
  déclarée dans « Fred UI » par le kit : aucune modification Entra. Chez un client,
  l'accès passe par son reverse proxy / répartiteur en HTTPS, et l'URL exacte s'ajoute
  aux redirect URIs (Entra n'accepte le HTTP que pour `localhost`).
- **Podman rootful dans un conteneur Docker privilégié.** Fidèle pour les commandes,
  les chemins, systemd et le réseau, pas pour SELinux (désactivé dans un conteneur).
  Les options `:Z`/`:z` des volumes sont déjà en place pour une vraie VM RHEL.
  Les VMs ont leur propre espace de noms cgroup (`cgroup: private`) : avec `host`, leur
  systemd voit l'arborescence du poste et podman ne crée plus ses pods. Recréer une VM
  (`make down` puis `make vms`) efface `/opt/fred` et `/etc/fred` : relancer `make deploy`.
- **Jobs one-shot hors de `depends_on`.** podman-compose traduit `depends_on` en
  `podman --requires`, qui exige que toute la chaîne requise tourne : un job terminé
  bloque alors le démarrage des services qui en dépendent, même indirectement
  (`container state improper`, `up -d` qui ne rend jamais la main). Les jobs sont donc
  dans le profil `jobs`, lancés dans l'ordre par `fred-jobs.sh` (`podman compose run
  --rm`) ; les `depends_on` ne relient que des services permanents. Au boot,
  `fred-stack.service` ne fait que `up -d`.
- **Temporal redémarre une fois après chaque recréation de son conteneur** (mise à jour
  d'image) : il cherche pendant 60 s son ancienne instance, encore inscrite en base
  (`failed to start ringpop`), s'arrête, puis repart sain grâce à `restart`. Sans effet
  sur Fred, dont les clients Temporal se reconnectent.
- **Registry en HTTP.** Le miroir d'un client serait en TLS ; seul
  `simulation/vm/registries.conf` change.
- **Image RHEL** : UBI 9 init. Si `registry.access.redhat.com` est injoignable, mettre
  `VM_BASE_IMAGE=docker.io/redhat/ubi9-init:latest` dans `config.env`.
- **Images Postgres et SeaweedFS** : `PG_UID` et `SEAWEED_UID` (`config.env`) doivent
  correspondre à l'utilisateur des images hardenées, sinon les clés TLS sont illisibles.
- **Postgres** reçoit tous les mots de passe des comptes applicatifs dans son
  environnement : ils ne servent qu'à la création initiale (`initdb/`). Changer un mot
  de passe ensuite se fait par `ALTER ROLE`, pas en régénérant `secrets/generated.env`.

---

## 7. Dépannage

| Symptôme | Cause probable | Correction |
|---|---|---|
| `make vms-build` bloque sur le pull | CDN Red Hat injoignable | `VM_BASE_IMAGE=docker.io/redhat/ubi9-init:latest` |
| un pull échoue dans une VM | image absente du registry | `make registry-push`, vérifier `images.tsv` |
| `pg_hba.conf rejects connection … no encryption` | client sans TLS | `PGSSLMODE` manquant dans le conteneur |
| `certificate verify failed` vers fred-sto-01 | CA interne absente du bundle | relancer `fred-deploy.sh` (installe la CA) |
| HTTPS S3 qui ne répond jamais | clé TLS illisible par `weed` | `SEAWEED_UID` |
| Postgres : `private key file … has group or world access` | modes non appliqués | `make deliver` (applique `.perms`) |
| `podman exec postgres psql` : `Peer authentication failed` | exec en root | `podman exec -u postgres postgres psql` |
| backends en échec au démarrage OIDC | sortie HTTPS vers Entra impossible | réseau de la VM, `HTTPS_PROXY` / `NO_PROXY` |
| `podman compose up` : `unable to create pod cgroup … already loaded` | VM simulée en `cgroup: host` | `cgroup: private` (`simulation/compose.yaml`) |
| `up -d` bloqué, services en `Created`, `container state improper` | job one-shot dans un `depends_on` | jobs dans le profil `jobs` et `fred-jobs.sh` |
| `Unsupported log store configuration: StdoutLogStorageConfig` | `log_store: stdout` non implémenté | `in_memory` (fait par `render.py`) |
| requête tabulaire : `SSL peer certificate … was not OK` | DuckDB ne lit pas `SSL_CERT_FILE` | bundle monté sur le magasin système de l'image (§3 point 4) |
| `make vms` : `bind … 127.0.0.1:5173: address already in use` | serveur de dev Fred sur 5173 | l'arrêter, ou `make vms PUBLIC_PORT=5180` (sans connexion Entra) |
| autres symptômes Entra | — | `GUIDE-ENTRA-ID.md` §6 |

---

## 8. Ce qui a été vérifié, et ce qui ne l'a pas été

**Vérifié hors ligne le 02/10/2026** (images déjà présentes, réplique du LAN avec les
mêmes IP, fichiers exactement tels que rendus) :

- `render.py` produit les deux arborescences ; les trois configurations Fred passent
  leur schéma JSON ; les trois compose passent `docker compose config`.
- Postgres : init des 4 bases + pgvector ; `pg_hba` accepte fred-app-01 en TLS, refuse
  le clair, une autre IP et un compte sur une autre base.
- Pilotes de Fred via SQLAlchemy (psycopg2, psycopg 3, asyncpg) : TLS 1.3 avec les seules
  variables `PGSSL*` ; refus d'un serveur signé par une autre CA.
- OpenFGA (`migrate`) et Temporal (`setup/update-schema`, deux passages) via TLS
  `verify-full`.
- SeaweedFS en HTTPS : le client minio de Fred crée un bucket, écrit et relit un objet ;
  refus sans la CA interne ; requête en clair refusée (400).

**Vérifié le 02/10/2026, en ligne** : `make vms-build` produit l'image des VMs
(RHEL 9.8, podman 5.8.2, podman-compose 1.6.0, miroir `registry.fred.lan:5000`).

**Vérifié le 02/10/2026, en ligne, avec des images Fred construites depuis les
`Dockerfile-prod` du commit `80465686`** (et non les images hardenées : poussées sous le
tag `:hardened` du registry) :

- VMs : systemd `running`, podman 5.8.2 imbriqué (cgroups v2, overlay), pull depuis le
  seul miroir ; healthchecks podman (timers systemd) fonctionnels.
- `fred-deploy.sh` de bout en bout sur les deux VMs ; redémarrage de chaque VM : la pile
  revient seule par `fred-stack.service`, dans l'ordre, sans relancer les jobs.
- podman-compose 1.6.0 respecte les conditions `service_healthy` / `service_started`
  entre services permanents (horodatages des événements podman).
- Migrations Alembic des trois backends, OpenFGA et Temporal : en TLS `verify-full`.
- Les 8 services restent debout. Chaque backend initialise l'OIDC Entra (profil C3,
  issuer et audience stricts) ; le navigateur reçoit la configuration Entra par le
  frontend.
- `make verify` : TLS 1.3 sur toutes les sessions Postgres, aucune en clair, S3 refuse
  le HTTP.
- Entra côté serveur : la sortie HTTPS fonctionne avec le bundle système + CA interne
  (point d'attention 1 du §3) ; le Control Plane obtient un jeton M2M (v2, rôle
  `service_agent`) ; Knowledge Flow et le Control Plane valident ce jeton (401 sans,
  403 avec : authentifié, puis refusé par OpenFGA, normal pour un compte de service).
- DuckDB `httpfs` lit un Parquet de SeaweedFS par URL présignée HTTPS, depuis le
  conteneur Knowledge Flow (après correction, §3 point 4).
- Appel LLM réel depuis fred-agents (`mistral-small-latest`, `langchain-openai`).

Corrigé en chemin : espace de noms cgroup des VMs simulées, jobs hors `depends_on`,
`log_store`, magasin de CA pour DuckDB, healthcheck Postgres (en TCP, `pg_hba` le rejetait : un `FATAL` toutes les
10 s).

Relevé dans Fred, sans effet bloquant : Knowledge Flow journalise une `ERROR` au
démarrage (`connection should be a connection string…`) car
`pgvector_store._create_store` passe `connection_string` à langchain-postgres, qui
attend `connection`. Il retombe sur l'implémentation historique, qui fonctionne.

**Pas encore vérifié** :

- connexion Microsoft dans le navigateur, bootstrap administrateur et parcours du guide
  Entra §5.5 (nécessite le port 5173 libre, voir §7) ;
- les images hardenées elles-mêmes, en particulier `PG_UID` / `SEAWEED_UID` (§6) ;
- les URL présignées pour le navigateur (§3 point 5) : problème confirmé, non traité.
