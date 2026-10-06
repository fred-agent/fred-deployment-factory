#!/usr/bin/env bash
# Crée les secrets de la maquette s'ils n'existent pas. N'écrase jamais rien :
# les mots de passe Postgres sont figés dans la base à sa première initialisation.
set -euo pipefail
cd "$(dirname "$0")/.."

umask 077
mkdir -p secrets

if [[ ! -f secrets/generated.env ]]; then
    r() { openssl rand -hex 24; }
    cat >secrets/generated.env <<EOF
# Généré par scripts/secrets.sh le $(date -I). Ne pas versionner.
POSTGRES_PASSWORD=$(r)
FRED_DB_PASSWORD=$(r)
OPENFGA_DB_PASSWORD=$(r)
TEMPORAL_DB_PASSWORD=$(r)
S3_SECRET_KEY=$(r)
OPENFGA_PRESHARED_KEY=$(r)
FRED_BOOTSTRAP_TOKEN=$(r)
EOF
    echo "Écrit : secrets/generated.env"
else
    echo "Conservé : secrets/generated.env"
fi

if [[ ! -f secrets/llm.env ]]; then
    cat >secrets/llm.env <<'EOF'
# Clé de l'API LLM (Mistral, via le provider "openai" des configs Fred). À remplir.
OPENAI_API_KEY=
EOF
    echo "Écrit : secrets/llm.env (à remplir : OPENAI_API_KEY)"
fi
