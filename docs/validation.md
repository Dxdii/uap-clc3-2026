# Validation log (2026-11-14)

What was executed and verified while implementing this repo. No production resources
were created; the only write was a temporary empty resource group used for server-side
what-if validation (deleted again afterwards).

## Infrastructure (Bicep)

| Check | Command | Result |
|---|---|---|
| Local compile (Bicep CLI 0.49.2) | `bicep build infrastructure/main.bicep` | PASS, 0 errors (only informational linter notes) |
| Server-side validation + change preview (read-only) | `az deployment sub what-if --location westeurope --template-file infrastructure/main.bicep --parameters rgName=... location=westeurope` | PASS — "22 to create", all resource types accepted (incl. FC1 plan, Flex `functionAppConfig`, Event Grid subscription, project-scoped model deployment) |

Two real issues were found and fixed via what-if:

1. Model deployments must be **project-scoped** child resources
   (`Microsoft.CognitiveServices/accounts/projects/deployments@2025-06-01`); account-level
   deployments fail RP preflight when the account is created in the same deployment.
2. The deployment SKU is the **top-level `sku`** (`{ name: 'GlobalStandard', capacity: 1 }`);
   `properties.scaleSettings.scaleType` rejects `GlobalStandard` server-side.

## Pre-flight script

| Check | Result |
|---|---|
| `bash -n scripts/preflight.sh` | PASS |
| jq intersection logic (unit-tested with sample region lists) | PASS |
| Full run against a real non-student subscription (Pay-As-You-Go Dev/Test) | PASS — correctly reported "no allowed-regions policy → all regions allowed", computed 33 candidate regions (allowed ∩ Flex ∩ ContainerApps ∩ AI ∩ core), probed `az cognitiveservices usage list` per region (gpt-4o-mini GlobalStandard quota, e.g. swedencentral 2000 K TPM), printed `RECOMMENDED LOCATION: swedencentral` |
| Defensive behavior | PASS — when run against an inaccessible student subscription it printed the MANUAL fallback steps instead of crashing |

Note: the two "Azure for Students" subscriptions visible in this CLI session were not
API-accessible (SubscriptionNotFound), so the student-policy path could only be tested
via the graceful-fallback branch. The manual instructions in `scripts/README.md` remain
the source of truth for students.

## Python code

| Check | Result |
|---|---|
| Upload app unit tests | `pytest src/upload-app/tests` — **6 passed** (health, index form, upload stores blob w/ mocked BlobServiceClient, 401 missing/wrong token, 413 oversize, empty-file 400) |
| Function unit tests | `pytest src/image-analysis-function/tests` — **4 passed** (Cosmos document structure incl. id + /filename partition key + analysis JSON; Foundry call shape with image as base64 data URL; Cosmos id sanitization for nested blob names) |
| Package versions | all pins in `requirements*.txt` verified against PyPI on 2026-11-14 (azure-ai-projects 2.11.0, azure-functions 2.4.0, azurefunctions-extensions-bindings-blob 1.1.2, fastapi 0.162.7, ...) |
| YAML/JSON configs | workflows, host.json, local.settings.example.json, devcontainer.json all parse |

## GitHub Copilot code reviews (PR #1, 4 rounds, one per implementation phase)

Copilot reviewed the PR after each phase push. Findings were fixed in follow-up commits on the
same branch and the review threads resolved:

| Round | Phase | Findings | Fix commit |
|---|---|---|---|
| 1 | infrastructure + preflight | 11 (missing `dependsOn: [rg]`, Cosmos sqlRoleDefinition id + `/dbs/…` scope, plaintext workspace key, ACR pull identity, Event Grid endpoint, queue-data role, preflight unknown-state/union/quota/retry issues) | `0d2e5ff` |
| 2 | function code | 5 new + 2 previously missed (blob webhook endpoint vs azurefunction, nested-deployment name, jq substring membership, nested blob names as Cosmos ids, local managedidentity) | `d54d627` |
| 3 | upload app + workflows + devcontainer | 7 (docker-cli package, placeholder image port, image reset on infra redeploy, policy response shapes, anonymous uploads, unbounded upload size, deployer RBAC role) | `6dc950d` |
| 4 | docs (this README/validation) | see PR #1 review thread | — |

Notable verified-against-docs decision: an Event-Grid-sourced **blob** trigger is fed by a **webhook**
endpoint (`/runtime/webhooks/blobs?functionName=Host.Functions.<fn>&code=<blobs_extension key>`),
not an `azurefunction` endpoint (that is only for EventGrid-*trigger* functions) — per Microsoft Learn.

## Independent review by Claude Code (2026-11-14, after merge)

Claude Code 2.1.325 reviewed the merged `main` with the same priorities (functional correctness +
end-to-end deployability on a student subscription; no security/style nitpicks). Findings and fixes:

| Finding | Verdict | Fix |
|---|---|---|
| `@secure()` output not retrievable (`az deployment sub show --query …value` returns empty) → README step 7 token command broken | CONFIRMED empirically on a scratch deployment (`outputs.tokOut` = `{"type":"SecureString"}` with no value) | token now passed explicitly as `@secure()` param in README step 4; read-back via `az containerapp secret show`; secure output removed |
| `az acr build` (ACR Tasks) fails on Azure for Students with `TasksOperationsNotAllowed` and needs Standard/Premium SKU | CONFIRMED via Microsoft Q&A/Learn | README step 6 + `containerapp-deploy.yml` now use local `docker build` + `docker push` with `az acr login --expose-token` (works on Basic with RBAC, no admin user) |
| missing `containerAppName` / `acrName` deployment outputs used by README/workflows | confirmed | outputs added to `main.bicep` |
| global name collisions / invalid chars (umlauts) from rgName-derived suffix | confirmed risk | `nameSuffix` is now `take(uniqueString(subscription().subscriptionId, rgName), 16)` — hex-only, per-subscription |
| Cosmos output binding `create_if_not_exists=True` can 403 with Entra-only database-scope RBAC | plausible, fixed defensively | `create_if_not_exists=False` (Bicep creates db+container) |
| hard-coded `$APP.azurewebsites.net` webhook host | fixed | `az functionapp show --query defaultHostName` in workflow + README |
| `blobs_extension` key may lag after publish; subscription update may fail | hardened | retry loop + empty-key guard + update-or-delete-recreate in `function-deploy.yml` / README |
| project-scoped model deployment `accounts/projects/deployments@2025-06-01` not in Learn reference pages | NOT changed — server-side what-if RP preflight rejects the account-level form and accepts the project-scoped form (verified earlier); kept as "needs manual check" for the first real student deploy |

## Not validated here (needs Azure / Docker daemon)

* `docker build src/upload-app` — Docker daemon was not running in this environment; the
  image is built in CI via `az acr build` (containerapp-deploy.yml).
* `func azure functionapp publish --build local` — Azure Functions Core Tools not installed
  here; exercised in the devcontainer / function-deploy.yml.
* Real end-to-end deployment to a student subscription (no accessible student subscription
  in this environment) — this is what students do; see README step 3 (pre-flight) and 4–7.

## Live end-to-end test (2026-11-14, private PAYG subscription, region swedencentral)

A full deploy + e2e run was performed against a real subscription (`rg-clc3-e2etest2`,
deployment `clc3-e2e17` → **exit 0, all modules Succeeded**). Findings that changed code/docs:

| # | Finding (verified live) | Fix |
|---|---|---|
| E1 | Invalid/old bicep API versions rejected by the RPs | storage family → `2025-06-01` (incl. `managementPolicies`), DocumentDB → `2025-04-15`, EventGrid systemTopics → `2025-02-15`, ACR → `2025-11-01` |
| E2 | Cosmos container child path was misnamed `sqlDatabases/sqlContainers` | corrected to `sqlDatabases/containers@2025-04-15` |
| E3 | Project-scoped model deployment `accounts/projects/deployments@2025-06-01` rejected at runtime (`UnsupportedAction`) | switched to **account-level** `accounts/deployments@2025-06-01` — the earlier what-if preflight result was misleading; the project routes SDK calls to account-level deployments |
| E4 | Parallel child writes on the CS account (project + deployment) fail with `RequestConflict` | `dependsOn: [project]` on the model deployment serializes the writes |
| E5 | `gpt-4o-mini` (2024-07-18) is **Deprecating** — new deployments rejected (`ServiceModelDeprecating`) | all defaults switched to **gpt-5-mini / 2025-08-07** (GA, GlobalStandard, quota OK in swedencentral) |
| E6 | gpt-5 family rejects `max_tokens` (`Unsupported parameter … use max_completion_tokens`) and non-default `temperature` → function failed with HTTP 400 | `function_app.py` now uses `max_completion_tokens=800`, no `temperature` |
| E7 | Wrong built-in role GUIDs in `rbac.bicep`: Storage Queue Data Contributor (`…7f855e888dfd` → `…5f855dd0fb88`) and Monitoring Metrics Publisher (`…055b5` → `…055eb`) caused `RoleDefinitionDoesNotExist` | GUIDs corrected (verified against `az role definition list`); note `53ca6127-…` ("Azure AI User" → now "Foundry User") is correct |
| E8 | macOS: `docker build` without `--platform` pushes an arm64 image; ACA amd64 nodes then fail with `ImagePullBackOff` / "no matching manifest" | README step 6 now uses `docker build --platform linux/amd64` |
| E9 | macOS: `func … publish --build local` packages macOS wheels into `.python_packages` → Linux host fails with `invalid ELF header`, loads 0 functions | README step 5 documents the fix: pre-build `.python_packages` with `pip install --platform manylinux2014_x86_64 --python-version 3.13 --abi cp313 --only-binary=:all:` (also match local Python minor version 3.13) |
| E10 | `az functionapp show --query defaultHostName` returns empty in some CLI versions | use `--query properties.defaultHostName` |
| E11 | Soft-deleted Cognitive Services account blocks recreate (`FlagMustBeSetForRestore`) | purge with `az cognitiveservices account purge --name <n> --location <loc> -g <rg>` (the `-g` flag is required) |
| E12 | Placeholder image must be pullable; `mcr.microsoft.com/azuredocs/containerapps-helloworld:latest` works | default `uploadAppImage` = that MCR image; revision is unhealthy until the real image is pushed, which is fine |

**E2E result (all green):** infra deployment Succeeded → `func publish` → Event Grid webhook
subscription `sub-<func>-AnalyzeImage` (BlobCreated, subject prefix `…/imageanalysis/blobs/`)
→ `curl -H "X-Upload-Token: …" -F file=@test2.jpeg https://<fqdn>/upload` → **200** (blob
`test2.jpeg` in container `imageanalysis`) → Event Grid delivered → `AnalyzeImage` executed
(**Succeeded**, 10.6 s) → Cosmos DB `ImageAnalysis/results` contains document `id=test2.jpeg`
with the gpt-5-mini JSON analysis (caption/tags/objects/colors) written via the Cosmos output
binding with managed identity.

## CI token-auth validation (2026-11-14)

* **FH OOe tenant blocks app registration for students** (probe run by the professor with a student
  account `p61219@fhooe.at`): `az ad app create` → "Directory permission is needed for the current user
  to register the application … Insufficient privileges". Conclusion: no service-principal auth for
  students → workflows authenticate with the student's az CLI token store stored as repo secret
  `AZURE_CLI_TOKENS` (set by `scripts/preflight.sh` step 6 via `gh`).
* **Token-store injection works on a clean environment** (simulated runner): copying
  `~/.azure/msal_token_cache.json` + `azureProfile.json` into a fresh `AZURE_CONFIG_DIR` makes
  `az account show`, `az group list` and `az account get-access-token` (refresh path) all succeed.
  Note: current az CLI versions store tokens in `msal_token_cache.json` (not `accessTokens.json`);
  preflight bundles whichever exist.

## CI token-auth live test (2026-11-14, PAYG sub, swedencentral, repo juergenbr/clc3-ci-test)

Full pipeline validated live end to end: preflight step 6 set secrets/variables on a fresh private
fork → push to `main` triggered `infra-deploy` (token login via `AZURE_CLI_TOKENS` worked on the
runner) → `containerapp-deploy` and `function-deploy` (dispatched manually) both green →
`curl -H "X-Upload-Token: …" -F file=@test.jpeg https://<fqdn>/upload` → 200 → Event Grid →
`AnalyzeImage` executed (Succeeded) → Cosmos `ImageAnalysis/results` contains `id=test.jpeg`
with the model's JSON analysis (caption/tags/objects/colors).

Findings fixed along the way (all committed on `feature/ci-token-auth`):

* **C1 — ACA chicken-and-egg (critical):** the container app declared the ACR in
  `configuration.registries` with `identity: 'system'` at creation time, so the platform tried to
  mint an ACR pull token during first revision provisioning — but AcrPull for the app identity is
  only granted by `rbac.bicep`, which depends on `containerApp.outputs.principalId` and therefore
  runs AFTER the containerapp module. Result: revision provisioning looped until
  "Operation expired" (~20 min) and the whole deployment failed (ACA system log:
  `FetchingKeyVaultSecretFailed`). Fix: the app is created WITHOUT a registry entry (public MCR
  placeholder needs no auth); `containerapp-deploy.yml` runs
  `az containerapp registry set --server <acr> --identity system` (note: `az containerapp update`
  has NO `--registry-server/--registry-identity` flags in CLI 2.92) before updating the image.
* **C2 — GITHUB_TOKEN cannot write repo variables on a fresh repo:** `gh variable set` from CI
  failed with HTTP 403 on `actions/variables` even with `permissions: actions: write` in the
  workflow and `default_workflow_permissions=write` set at repo level. Fix: CI no longer writes
  repo variables at all — the deploy workflows resolve resource names from the ARM deployment
  outputs (`az deployment sub show --query properties.outputs`), which they can do because they
  already authenticate to Azure with the student token. Workflows only need `contents: read`.
* **C3 — `func azure functionapp publish` on the runner:** "Can't determine project language
  from files" → pass `--python` explicitly.
* First `AnalyzeImage` execution after deploy can fail once (host/queue warm-up, "404 queue does
  not exist"); the Event Grid retry policy redelivers and the retry succeeds — expected behavior,
  documented for students.
