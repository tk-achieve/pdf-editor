// ---------------------------------------------------------------------------
// main.bicepparam – Deployment parameters for Stirling PDF on Azure
//
// Fill in every value marked <REPLACE_ME> before deploying.
// Sensitive values (entraClientSecret) should be passed via:
//   --parameters entraClientSecret=$SECRET
// or stored in a secure pipeline variable – never commit them here.
// ---------------------------------------------------------------------------

using './main.bicep'

// Azure region to deploy into (must support Azure Container Apps)
param location = 'uksouth'

// Short lowercase alphanumeric prefix for resource names (3–12 chars)
param appName = 'pdfeditor'

// -----------------------------------------------------------------------------
// Entra ID (Azure AD) – create an App Registration first (see README)
// -----------------------------------------------------------------------------

// Application (client) ID from your App Registration
param entraClientId = '<REPLACE_ME: app-registration-client-id>'

// Client secret value – PASS VIA CLI FLAG, do not hard-code here:
//   --parameters entraClientSecret="<value>"
// param entraClientSecret = ''   ← intentionally omitted; must be supplied at deploy time

// Your Azure AD tenant ID (visible in Entra ID > Overview)
param tenantId = '<REPLACE_ME: your-tenant-id>'

// -----------------------------------------------------------------------------
// Branding
// -----------------------------------------------------------------------------
param companyDisplayName = 'Acme PDF Editor'

// -----------------------------------------------------------------------------
// Scale & resilience
// -----------------------------------------------------------------------------
// Keep at 1 for always-on (recommended for HIPAA – avoids cold-start gaps)
param minReplicas = 1
param maxReplicas = 3

// -----------------------------------------------------------------------------
// Compliance
// -----------------------------------------------------------------------------
// 90-day minimum for HIPAA audit trail; increase if your policy requires more
param logRetentionDays = 90

// Initial image tag; CI/CD will keep this updated on every push
param imageTag = 'latest'
