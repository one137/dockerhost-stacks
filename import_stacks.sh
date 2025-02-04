#!/bin/bash

PORTAINER_URL="https://localhost:9443/api"
INPUT_DIR="./stacks"

if [[ ! "$PORTAINER_API_TOKEN" ]]; then
    echo "Please define \$PORTAINER_API_TOKEN"
    exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
    echo "Please install jq"
    exit 1
fi

# Query Portainer API to get the endpointId

response=$(curl -ks "$PORTAINER_URL/endpoints" -H "X-API-Key: $PORTAINER_API_TOKEN")
endpoint_count=$(echo "$response" | jq '. | length')

if [[ "$endpoint_count" -eq 1 ]]; then
    endpoint_id=$(echo "$response" | jq -r '.[0].Id')
    echo "Using endpointId: $endpoint_id"
else
    echo "Error: No or multiple endpoints found. Try running:"
    echo " curl -ks \"$PORTAINER_URL/endpoints\" -H \"X-API-Key: \$PORTAINER_API_TOKEN\" | jq"
    exit 1
fi

# Create the stacks

echo -e "Reading $INPUT_DIR/*.yml files...\n"
for yml_file in $INPUT_DIR/*.yml; do
    base_name=$(basename "$yml_file" .yml) # e.g. "30-st-pihole" from "stacks/30-st-pihole.yml"
    echo "* Creating stack $base_name"

    env_file="$INPUT_DIR/${base_name}.env.json"
    if [[ -f "$env_file" ]]; then
        curl -k -X POST "$PORTAINER_URL/stacks/create/standalone/file?endpointId=$endpoint_id" \
             -H "X-API-Key: $PORTAINER_API_TOKEN" \
             -F "Name=$base_name" \
             -F "file=@$yml_file" \
             -F "Env=$(cat "$env_file")"
    else
        curl -k -X POST "$PORTAINER_URL/stacks/create/standalone/file?endpointId=$endpoint_id" \
             -H "X-API-Key: $PORTAINER_API_TOKEN" \
             -F "Name=$base_name" \
             -F "file=@$yml_file"
    fi
    echo -e "\n"
done

