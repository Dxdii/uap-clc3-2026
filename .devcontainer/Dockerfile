FROM mcr.microsoft.com/devcontainers/python:3.13-bookworm

# Azure CLI (includes Bicep via `az bicep`), Azure Functions Core Tools, Docker CLI, jq
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates apt-transport-https lsb-release gnupg jq \
 && curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
 && curl -sL https://aka.ms/InstallAzureFuncCoreTools | bash \
 && curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/azure-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends azure-cli docker-cli \
 && az bicep install \
 && rm -rf /var/lib/apt/lists/*

# Docker-in-Docker support (Docker daemon must be started by the host or via feature in devcontainer.json when available)
RUN groupadd -f docker || true
