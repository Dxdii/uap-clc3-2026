FROM mcr.microsoft.com/devcontainers/python:3.13-bookworm

# Azure CLI (+ Bicep via `az bicep install`), Azure Functions Core Tools, jq,
# GitHub CLI (gh) — used by scripts/preflight.sh to push the repo secret/variables.
# Docker CLI comes from the docker-outside-of-docker feature in devcontainer.json
# ('docker-cli' is NOT a Debian bookworm package; 'docker.io' would work too).
# NOTE: https://aka.ms/InstallAzureFuncCoreTools is a dead short link (it now
# redirects to a Bing results page, and piping that HTML into bash is what broke
# this build). Core Tools is therefore installed from the GitHub release zip,
# whose linux-arm64/linux-x64 assets cover both devcontainer architectures.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg jq unzip \
 && curl -fsSL https://aka.ms/InstallAzureCLIDeb -o /tmp/azcli.sh \
 && bash /tmp/azcli.sh \
 && rm -f /tmp/azcli.sh \
 && FUNC_VER="$(curl -fsSL https://api.github.com/repos/Azure/azure-functions-core-tools/releases/latest | jq -r .tag_name)" \
 && FUNC_ARCH="$(dpkg --print-architecture | sed 's/^amd64$/x64/')" \
 && curl -fsSL "https://github.com/Azure/azure-functions-core-tools/releases/download/${FUNC_VER}/Azure.Functions.Cli.linux-${FUNC_ARCH}.${FUNC_VER}.zip" -o /tmp/func-cli.zip \
 && curl -fsSL "https://github.com/Azure/azure-functions-core-tools/releases/download/${FUNC_VER}/Azure.Functions.Cli.linux-${FUNC_ARCH}.${FUNC_VER}.zip.sha2" -o /tmp/func-cli.zip.sha2 \
 && echo "$(cat /tmp/func-cli.zip.sha2)  /tmp/func-cli.zip" | sha256sum -c - \
 && unzip -q /tmp/func-cli.zip -d /usr/local/lib/azure-functions-core-tools \
 && chmod +x /usr/local/lib/azure-functions-core-tools/func \
 && ln -sf /usr/local/lib/azure-functions-core-tools/func /usr/local/bin/func \
 && rm -f /tmp/func-cli.zip /tmp/func-cli.zip.sha2 \
 && az bicep install \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*
