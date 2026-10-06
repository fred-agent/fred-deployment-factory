#!/usr/bin/env bash
# PKI interne de la maquette : une CA et le certificat serveur de fred-sto-01
# (Postgres et S3). Chez un client, ces fichiers viennent de sa propre PKI.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source config.env; set +a

umask 077
P=secrets/pki
mkdir -p "$P"

if [[ ! -f $P/ca.crt ]]; then
    openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 3650 \
        -keyout "$P/ca.key" -out "$P/ca.crt" \
        -subj "/O=Fred mock/CN=Fred mock internal CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
    echo "Écrit : $P/ca.crt"
fi

if [[ ! -f $P/fred-sto-01.crt ]]; then
    openssl req -newkey rsa:2048 -sha256 -nodes \
        -keyout "$P/fred-sto-01.key" -out "$P/fred-sto-01.csr" \
        -subj "/O=Fred mock/CN=$STO_FQDN" 2>/dev/null
    openssl x509 -req -in "$P/fred-sto-01.csr" -CA "$P/ca.crt" -CAkey "$P/ca.key" \
        -CAcreateserial -days 825 -sha256 -out "$P/fred-sto-01.crt" \
        -extfile <(printf '%s\n' \
            "subjectAltName=DNS:$STO_FQDN,DNS:fred-sto-01,IP:$STO_IP" \
            "keyUsage=critical,digitalSignature,keyEncipherment" \
            "extendedKeyUsage=serverAuth") 2>/dev/null
    rm -f "$P/fred-sto-01.csr"
    echo "Écrit : $P/fred-sto-01.crt"
fi

openssl verify -CAfile "$P/ca.crt" "$P/fred-sto-01.crt"
