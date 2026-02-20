# Stirling PDF – Azure HIPAA Deployment

Self-hosted [Stirling PDF](https://github.com/Stirling-Tools/Stirling-PDF) running on **Azure Container Apps**, accessible only to company employees via **Microsoft Entra ID (Azure AD) authentication**. No PDF data ever leaves your Azure tenant.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Company Azure Tenant                                                   │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  Resource Group: rg-pdf-editor-prod                              │  │
│  │                                                                  │  │
│  │  ┌──────────────┐    ┌──────────────────────────────────────┐   │  │
│  │  │  GitHub       │    │  VNet: 10.0.0.0/16                   │   │  │
│  │  │  Actions      │    │                                      │   │  │
│  │  │  CI/CD        │    │  ┌────────────────────────────────┐  │   │  │
│  │  │               │    │  │  Infrastructure Subnet /23     │  │   │  │
│  │  │  Build image  │    │  │  Container Apps Environment    │  │   │  │
│  │  │  Push to ACR ─┼────┼─►│                                │  │   │  │
│  │  │  Deploy to CA │    │  │  ┌──────────────────────────┐  │  │   │  │
│  │  └──────────────┘    │  │  │  Container App            │  │  │   │  │
│  │                      │  │  │  stirling-pdf:sha-abc1234 │  │  │   │  │
│  │  ┌──────────────┐    │  │  │                          │  │  │   │  │
│  │  │  ACR          │    │  │  │  Easy Auth (Entra ID)    │  │  │   │  │
│  │  │  (image store)│◄───┼──┼──┤  • Unauthenticated →    │  │  │   │  │
│  │  └──────────────┘    │  │  │    Microsoft login page  │  │  │   │  │
│  │                      │  │  │  • Authenticated →        │  │  │   │  │
│  │  ┌──────────────┐    │  │  │    Stirling PDF UI       │  │  │   │  │
│  │  │  Key Vault    │◄───┼──┼──┤                          │  │  │   │  │
│  │  │  (Entra secret│    │  │  │  Managed Identity        │  │  │   │  │
│  │  │  at rest)     │    │  │  │  (AcrPull + KV access)   │  │  │   │  │
│  │  └──────────────┘    │  │  └──────────────────────────┘  │  │   │  │
│  │                      │  └────────────────────────────────┘  │   │  │
│  │  ┌──────────────┐    └──────────────────────────────────────┘   │  │
│  │  │  Log Analytics│                                               │  │
│  │  │  Workspace    │◄──── Container + platform logs (90-day ret.) │  │
│  │  └──────────────┘                                               │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  Entra ID ──────────────────────────────────────────────────────────►  │
│  (authenticates employees via their work accounts)                      │
└─────────────────────────────────────────────────────────────────────────┘
```

**Data-flow guarantee:** Stirling PDF processes files entirely in-memory within the container. No uploaded documents are written to disk or transmitted outside the Azure tenant. TLS 1.2+ is enforced end-to-end by Azure Container Apps.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Azure subscription | Owner or Contributor + User Access Administrator on the target resource group |
| Azure CLI ≥ 2.61 | `az upgrade` to update |
| Bicep CLI ≥ 0.28 | Bundled with Azure CLI; `az bicep upgrade` to update |
| Entra ID (Azure AD) | Global Admin or Application Admin role in your tenant |
| DNS access | Ability to create a CNAME record on your domain |
| GitHub repository | Forked from or cloned to your org with Actions enabled |

---

## Step-by-Step Deployment

### 1 – Create the Entra ID App Registration

This gives Easy Auth an identity to validate employee logins against.

```bash
# Sign in with an account that has Application Admin or higher
az login

TENANT_ID=$(az account show --query tenantId -o tsv)

# Create the registration
APP_ID=$(az ad app create \
  --display-name "Stirling PDF" \
  --sign-in-audience AzureADMyOrg \
  --web-redirect-uris "https://pdf.yourdomain.com/.auth/login/aad/callback" \
                      "https://<containerapp-fqdn>/.auth/login/aad/callback" \
  --query appId -o tsv)

echo "Client ID: $APP_ID"

# Create a client secret (valid 2 years; rotate before expiry)
CLIENT_SECRET=$(az ad app credential reset \
  --id "$APP_ID" \
  --years 2 \
  --query password -o tsv)

echo "Client Secret: $CLIENT_SECRET"   # Save this – you will not see it again
```

> **Tip:** You can also create the App Registration in the Azure Portal under **Entra ID > App registrations > New registration**.

### 2 – Create the Resource Group

```bash
LOCATION="uksouth"          # Change to your preferred region
RG="rg-pdf-editor-prod"

az group create --name "$RG" --location "$LOCATION"
```

### 3 – Edit the Parameter File

Open `infra/main.bicepparam` and fill in:

```
param location           = 'uksouth'          # match step 2
param appName            = 'pdfeditor'        # short prefix, lowercase
param entraClientId      = '<APP_ID>'         # from step 1
param tenantId           = '<TENANT_ID>'      # from step 1
param companyDisplayName = 'Acme PDF Editor'  # shown in the UI
```

### 4 – Deploy the Infrastructure

```bash
az deployment group create \
  --resource-group "$RG" \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam \
  --parameters entraClientSecret="$CLIENT_SECRET"
```

Capture the outputs:

```bash
az deployment group show \
  --resource-group "$RG" \
  --name main \
  --query properties.outputs \
  --output yaml
```

Note the following output values:
- `acrLoginServer` → e.g. `pdfeditoracrXXX.azurecr.io`
- `acrName` → e.g. `pdfeditoracrXXX`
- `containerAppName` → e.g. `pdfeditor`
- `containerAppFqdn` → the CNAME target for your custom domain

### 5 – Configure GitHub Actions

In your GitHub repository, go to **Settings > Secrets and variables > Actions**.

#### Secrets (sensitive values)
| Name | Value |
|---|---|
| `AZURE_CLIENT_ID` | Client ID of a **federated credential** service principal (see below) |
| `AZURE_TENANT_ID` | Your Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Your Azure subscription ID |

#### Variables (non-sensitive)
| Name | Value |
|---|---|
| `ACR_LOGIN_SERVER` | From deployment output `acrLoginServer` |
| `ACR_NAME` | From deployment output `acrName` |
| `CONTAINER_APP_NAME` | From deployment output `containerAppName` |
| `RESOURCE_GROUP` | `rg-pdf-editor-prod` |

#### Create a federated-credential service principal (OIDC – no stored secret)

```bash
SP_NAME="sp-pdf-editor-github"

# Create a service principal
SP=$(az ad sp create-for-rbac --name "$SP_NAME" --skip-assignment --output json)
SP_CLIENT_ID=$(echo "$SP" | jq -r .appId)
SP_OBJECT_ID=$(az ad sp show --id "$SP_CLIENT_ID" --query id -o tsv)

# Grant Contributor on the resource group
az role assignment create \
  --assignee "$SP_OBJECT_ID" \
  --role "Contributor" \
  --scope "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/$RG"

# Also grant ACR push rights
ACR_ID=$(az acr show --name "$ACR_NAME" --resource-group "$RG" --query id -o tsv)
az role assignment create \
  --assignee "$SP_OBJECT_ID" \
  --role "AcrPush" \
  --scope "$ACR_ID"

# Add a federated credential for the main branch
az ad app federated-credential create \
  --id "$SP_CLIENT_ID" \
  --parameters '{
    "name": "github-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:<YOUR_GITHUB_ORG>/<YOUR_REPO>:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'

echo "Add to GitHub Secrets → AZURE_CLIENT_ID: $SP_CLIENT_ID"
```

### 6 – Push to main to Trigger the First Build

```bash
git add .
git commit -m "chore: initial deployment configuration"
git push origin main
```

The Actions workflow will:
1. Build the Docker image from `Dockerfile`
2. Push it to ACR with tag `sha-<short-sha>` and `latest`
3. Update the Container App to use the new image

### 7 – Configure the Custom Domain

Once the Container App is running:

```bash
# Get the auto-assigned FQDN (CNAME target)
az containerapp show \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RG" \
  --query "properties.configuration.ingress.fqdn" -o tsv
```

1. Create a **CNAME** record in your DNS: `pdf.yourdomain.com` → `<above FQDN>`
2. In the Azure Portal, go to the Container App > **Custom domains > Add**
3. Enter `pdf.yourdomain.com` and follow the TXT/CNAME validation steps
4. Azure automatically provisions and renews a **managed TLS certificate** (Let's Encrypt)

> Alternatively, bind your own certificate (e.g. from a corporate CA) in the same blade.

### 8 – Update the Entra ID Redirect URI

After the custom domain is live, add the callback URI to your App Registration:

```bash
az ad app update \
  --id "$APP_ID" \
  --web-redirect-uris \
    "https://pdf.yourdomain.com/.auth/login/aad/callback" \
    "https://<containerapp-fqdn>/.auth/login/aad/callback"
```

---

## Entra ID Authentication – How It Works

Easy Auth (Azure's built-in authentication middleware) intercepts every request **before** it reaches the Stirling PDF container.

| Scenario | Behaviour |
|---|---|
| Not logged in | Redirected to `login.microsoftonline.com` |
| Logged in with a personal Microsoft account | Rejected (only your tenant is allowed) |
| Logged in with a company account | Token validated, request forwarded to app |
| Token expired | Automatically refreshed via silent OIDC flow |

### Restricting to specific groups or users (optional)

By default any user in your tenant can log in. To restrict to specific groups:

1. In the Portal, go to **Entra ID > Enterprise applications > Stirling PDF**
2. Under **Properties**, set **Assignment required** to **Yes**
3. Under **Users and groups**, add the groups or users that should have access

---

## HIPAA Compliance Notes

This deployment is designed to support HIPAA technical safeguard requirements. You remain responsible for your full HIPAA compliance programme (BAA with Microsoft, policies, training, etc.).

### Encryption

| Layer | Implementation |
|---|---|
| **In transit** | TLS 1.2+ enforced by Azure Container Apps ingress; internal VNet traffic is encrypted |
| **At rest** | Azure Storage (volumes, logs) uses AES-256 encryption managed by Microsoft |
| **Secrets** | Client secret stored in Azure Key Vault (HSM-backed); never in environment variables |

### Access Control (§164.312(a))

- Authentication: Microsoft Entra ID with MFA enforced by your Conditional Access policies
- Authorisation: only company-tenant accounts can log in; optionally restrict further to groups
- No shared credentials; each employee logs in with their own work account
- Managed Identity for service-to-service access (ACR, Key Vault) – no stored passwords

### Audit Logging (§164.312(b))

- Container stdout/stderr streamed to **Log Analytics Workspace** (90-day minimum retention)
- Azure platform logs (container lifecycle, scaling, auth events) also captured
- Query example:

```kusto
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(7d)
| project TimeGenerated, ContainerName_s, Log_s
| order by TimeGenerated desc
```

### Data Residency (§164.312(e))

- All resources deployed to a single Azure region within your tenant
- No third-party integrations or telemetry endpoints in the container configuration
- Stirling PDF processes PDFs **in-memory only** – no files are persisted to disk or transmitted externally

### No Data Egress

- VNet egress can be further locked down with an **Azure Firewall** or **NSG rules** on the infrastructure subnet
- Consider enabling **Microsoft Defender for Containers** for runtime threat detection

### Business Associate Agreement

Ensure you have an active **BAA with Microsoft** (available via the Microsoft Trust Center) before processing ePHI. BAA covers Azure services used in this deployment.

### Recommended Hardening (not included to keep initial setup simple)

| Improvement | How |
|---|---|
| Private ACR & Key Vault endpoints | Add `Microsoft.Network/privateEndpoints` resources to the `private-endpoints` subnet |
| Outbound firewall | Deploy Azure Firewall in a hub VNet; route Container App egress through it |
| DDoS protection | Enable Azure DDoS Standard on the VNet |
| Conditional Access | Require MFA and compliant devices in Entra ID CA policies |
| Defender for Containers | Enable via Microsoft Defender for Cloud |
| Image scanning | Enable **ACR vulnerability assessment** (Defender for Containers) |

---

## Repository Structure

```
├── Dockerfile                     # Builds the company image from the official Stirling PDF image
├── docker-compose.yml             # Local development / smoke-test stack
├── .env.example                   # Copy to .env for local dev
├── .gitignore
├── infra/
│   ├── main.bicep                 # Root Bicep orchestrator
│   ├── main.bicepparam            # Deployment parameters (edit before deploying)
│   └── modules/
│       ├── acr.bicep              # Azure Container Registry + AcrPull role
│       ├── containerapp.bicep     # Managed identity, Container Apps Env, Container App, Easy Auth
│       ├── keyvault.bicep         # Key Vault + Entra secret + KV Secrets User role
│       ├── loganalytics.bicep     # Log Analytics workspace
│       └── network.bicep          # VNet with infrastructure and private-endpoints subnets
└── .github/
    └── workflows/
        └── deploy.yml             # CI/CD: build → push to ACR → deploy to Container App
```

---

## Troubleshooting

**Container App shows "Application Error" after deploy**
- Check logs: `az containerapp logs show --name <name> --resource-group <rg> --follow`
- Stirling PDF takes ~60 s to start; the startup probe allows up to 120 s

**Authentication loop / 401 after login**
- Verify the redirect URI in your App Registration matches exactly (including the `/.auth/login/aad/callback` suffix)
- Confirm `entraClientId` and `tenantId` match your App Registration

**CI/CD push fails with "unauthorized"**
- Confirm the GitHub service principal has the `AcrPush` role on the ACR resource
- Ensure the federated credential subject matches your branch/repo exactly

**Custom domain shows certificate error**
- TLS provisioning can take up to 10 minutes after domain binding
- Confirm the CNAME is resolving correctly before adding the domain in Azure Portal
