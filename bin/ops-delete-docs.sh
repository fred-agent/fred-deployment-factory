#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: ./delete_all.sh <index-name>"
  exit 1
fi

INDEX="$1"

curl -k -u admin:Azerty123_ -X POST "https://localhost:9200/${INDEX}/_delete_by_query?pretty" \
  -H 'Content-Type: application/json' \
  -d '{
    "query": {
      "match_all": {}
    }
  }'
