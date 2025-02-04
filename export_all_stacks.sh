#!/bin/bash

# Constants
PORTAINER_URL="https://localhost:9443"
OUTPUT_DIR="./stacks" # -export-$(date +'%Y%m%dT%H%M%S')"

if [[ -z "$PORTAINER_API_TOKEN" ]]; then
    echo "Please define \$PORTAINER_API_TOKEN"
    exit 1
fi

if ! command -v jq > /dev/null; then
    echo "Please install jq"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

STACKS=$(curl -sk "$PORTAINER_URL/api/stacks" -H "X-API-Key: $PORTAINER_API_TOKEN")
if [[ $? -ne 0 || -z "$STACKS" ]]; then
    echo "Error: Failed to fetch stacks."
    exit 1
fi

STACK_LIST=$(echo "$STACKS" | jq -c '.[] | {id: .Id, name: .Name}')
if [[ -z "$STACK_LIST" ]]; then
    echo "Error: No stacks found."
    exit 1
else
    echo -e "Successfully fetched all stacks.\n"
fi

echo "$STACK_LIST" | while read -r STACK; do
    STACK_ID=$(echo "$STACK" | jq -r '.id')
    STACK_NAME=$(echo "$STACK" | jq -r '.name')

    echo "Processing stack: $STACK_NAME (ID: $STACK_ID)"

    STACK_FILE=$(curl -sk "$PORTAINER_URL/api/stacks/$STACK_ID/file" -H "X-API-Key: $PORTAINER_API_TOKEN" | jq -r '.StackFileContent')
    if [[ $? -ne 0 || -z "$STACK_FILE" ]]; then
        echo "  Warning: Failed to fetch stack file. Skipping."
        continue
    fi
    YML_PATH="$OUTPUT_DIR/$STACK_NAME.yml"
    echo "$STACK_FILE" > "$YML_PATH"
    echo "  Saved stack file to $YML_PATH"

    STACK_ENV=$(curl -sk "$PORTAINER_URL/api/stacks/$STACK_ID" -H "X-API-Key: $PORTAINER_API_TOKEN" | jq -r '.Env')
    if [[ $? -eq 0 && "$STACK_ENV" != "[]" ]]; then
        ENV_PATH="$OUTPUT_DIR/$STACK_NAME.env.json"
        echo "$STACK_ENV" > "$ENV_PATH"
        chmod go-rwx "$ENV_PATH"
        echo "  Saved environment variables to $ENV_PATH"
    else
        echo "  No environment variables found."
    fi

    echo
done
