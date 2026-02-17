#!/bin/bash
if [ -z "$1" ]; then
  echo "Usage: ./mapping.sh <index-name>"
  exit 1
fi

curl -k -u admin:Azerty123_ https://localhost:9200/$1/_mapping?pretty
