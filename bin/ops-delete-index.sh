#!/bin/bash

# Usage: ./ops-delete-index.sh <index-name>

if [ -z "$1" ]; then
  echo "Usage: ./ops-delete-index.sh <index-name>"
  exit 1
fi

INDEX_NAME="$1"

echo "❗ Attempting to delete index: $INDEX_NAME"

curl -X DELETE -k -u admin:Azerty123_ "https://localhost:9200/$INDEX_NAME" -w "\n\n✅ Done.\n"
