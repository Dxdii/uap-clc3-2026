FROM mcr.microsoft.com/devcontainers/python:3.13-bookworm

# Azure CLI (+ Bicep via `az bicep install`), Azure Functions Core Tools, jq,
# GitHub CLI (gh) — used by scripts/preflight.sh to push the repo secret/variables.
# Docker CLI comes from the docker-outside-of-docker feature in devcontainer.json
# ('docker-cli' is NOT a Debian bookworm package; 'docker.io' would work too).
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg jq \
 && curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
 && curl -sL https://aka.ms/InstallAzureFuncCoreTools | bash \
 && az bicep install \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*
