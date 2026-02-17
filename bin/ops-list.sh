#!/bin/bash
if [ -z "$1" ]; then
  echo "Usage: ./list.sh <index-name>"
  exit 1
fi

curl -k -u admin:Azerty123_ -X GET "https://localhost:9200/$1/_search?pretty" -H 'Content-Type: application/json' -d '{
  "size": 10
}'
