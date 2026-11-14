FROM mcr.microsoft.com/devcontainers/python:3.13-bookworm

# Azure CLI (+ Bicep via `az bicep install`), Azure Functions Core Tools, jq.
# Docker CLI comes from the docker-outside-of-docker feature in devcontainer.json
# ('docker-cli' is NOT a Debian bookworm package; 'docker.io' would work too).
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg jq \
 && curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
 && curl -sL https://aka.ms/InstallAzureFuncCoreTools | bash \
 && az bicep install \
 && rm -rf /var/lib/apt/lists/*
