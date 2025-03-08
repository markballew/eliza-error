#!/bin/bash

# Build all necessary packages
cd packages/core && bun run build
cd ../plugin-sql && bun run build
cd ../cli && bun run build
cd ../plugin-slack && bun run build
cd ../the-org && bun run build
cd ../..

# Set the character path and run the application
export ELIZA_CHARACTER_PATH=$(pwd)/slack-character.json
export NODE_PATH=$NODE_PATH:$(pwd)/packages

echo "Starting Eliza with Slack character from: $ELIZA_CHARACTER_PATH"
echo "Make sure to update the Slack tokens in slack-character.json or .env file"

# Start elizaos
bun x elizaos start 