# Copyright Thales 2025
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#!/usr/bin/env bash

CERTS_DIR=$1
COUNTRY="FR"
STATE="France"
LOCATION="Rennes"
ORGANIZATION="Dev"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

function generate_root_cert
{
    [ ! -f ca.key ] && \
        openssl genpkey -algorithm RSA -out ca.key -pkeyopt rsa_keygen_bits:4096
    [ ! -f ca.crt ] && \
        openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/C=${COUNTRY}/ST=${STATE}/L=${LOCATION}/O=${ORGANIZATION}/CN=OpenSearch-CA"
}

function generate_cert
{
    local NAME=$1
    local COMMON_NAME=$2
    [ ! -f ${NAME}.key ] && \
        openssl genpkey -algorithm RSA -out ${NAME}.key -pkeyopt rsa_keygen_bits:4096
    [ ! -f ${NAME}.csr ] && \
        openssl req -new -key ${NAME}.key -out ${NAME}.csr -subj "/C=${COUNTRY}/ST=${STATE}/L=${LOCATION}/O=${ORGANIZATION}/CN=${COMMON_NAME}"
    [ ! -f ${NAME}.crt ] && \
        openssl x509 -req -in ${NAME}.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out ${NAME}.crt -days 365 -sha256
    [ ! -f ${NAME}.pem ] && \
        cat ${NAME}.crt ${NAME}.key > ${NAME}.pem
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

[ ! -d $CERTS_DIR ] && mkdir $CERTS_DIR

cd $CERTS_DIR

generate_root_cert
generate_cert "transport" "node"
generate_cert "admin" "admin"
generate_cert "rest" "rest"

# User:group is 1000:1000 in OpenSearch docker images
chown -R 1000:1000 $CERTS_DIR
