// ---------------------------------------------------------------------------
// main.bicep – Stirling PDF on Azure Container Apps
//
// Deploys:
//   • Log Analytics Workspace (audit logging)
//   • Azure Container Registry (image storage)
//   • Key Vault (Entra secret)
//   • Virtual Network (network isolation)
//   • Container App with Entra ID Easy Auth (Stirling PDF)
//
// Usage:
//   az deployment group create \
//     --resource-group rg-pdf-editor-prod \
//     --template-file infra/main.bicep \
//     --parameters infra/main.bicepparam
// ---------------------------------------------------------------------------

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Short name prefix used across all resource names (3–12 chars, lowercase alphanumeric).')
@minLength(3)
@maxLength(12)
param appName string = 'pdfeditor'

@description('Entra ID app registration client ID used for Easy Auth.')
param entraClientId string

@description('Entra ID app registration client secret.')
@secure()
param entraClientSecret string

@description('Azure AD tenant ID (your company tenant).')
param tenantId string = tenant().tenantId

@description('Display name shown inside the Stirling PDF UI.')
param companyDisplayName string = 'PDF Editor'

@description('Docker image tag to deploy initially (CI/CD will update this on every push).')
param imageTag string = 'latest'

@description('Minimum replica count. Set to 1 for always-on (recommended for HIPAA).')
@minValue(0)
@maxValue(10)
param minReplicas int = 1

@description('Maximum replica count.')
@minValue(1)
@maxValue(10)
param maxReplicas int = 3

@description('Log retention in days (minimum 90 for HIPAA).')
@minValue(90)
@maxValue(730)
param logRetentionDays int = 90

// ACR name must be globally unique, alphanumeric only
var acrName = '${replace(appName, '-', '')}acr${uniqueString(resourceGroup().id)}'

// Key Vault name: 3-24 chars, globally unique
var kvName = '${appName}-kv-${uniqueString(resourceGroup().id)}'

// ---------------------------------------------------------------------------
// Log Analytics Workspace
// ---------------------------------------------------------------------------
module logAnalytics 'modules/loganalytics.bicep' = {
  name: 'loganalytics'
  params: {
    name: appName
    location: location
    retentionDays: logRetentionDays
  }
}

// ---------------------------------------------------------------------------
// Virtual Network
// Must be deployed before Container App module (infraSubnetId dependency)
// ---------------------------------------------------------------------------
module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    name: appName
    location: location
  }
}

// ---------------------------------------------------------------------------
// Container App (including managed identity)
// Deploy early enough so we can pass managedIdentityPrincipalId to ACR & KV.
// Bicep handles the dependency graph; ACR/KV role assignments run in parallel.
// ---------------------------------------------------------------------------
module containerApp 'modules/containerapp.bicep' = {
  name: 'containerapp'
  params: {
    name: appName
    location: location
    acrLoginServer: acr.outputs.loginServer
    imageTag: imageTag
    logAnalyticsCustomerId: logAnalytics.outputs.customerId
    logAnalyticsSharedKey: logAnalytics.outputs.sharedKey
    infraSubnetId: network.outputs.infraSubnetId
    entraClientId: entraClientId
    tenantId: tenantId
    kvEntraSecretUri: keyVault.outputs.entraSecretUri
    companyDisplayName: companyDisplayName
    minReplicas: minReplicas
    maxReplicas: maxReplicas
  }
}

// ---------------------------------------------------------------------------
// Azure Container Registry
// Role assignment (AcrPull) uses managedIdentityPrincipalId from containerApp
// ---------------------------------------------------------------------------
module acr 'modules/acr.bicep' = {
  name: 'acr'
  params: {
    name: acrName
    location: location
    managedIdentityPrincipalId: containerApp.outputs.managedIdentityPrincipalId
  }
}

// ---------------------------------------------------------------------------
// Key Vault
// Role assignment (KV Secrets User) uses managedIdentityPrincipalId
// ---------------------------------------------------------------------------
module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    name: kvName
    location: location
    tenantId: tenantId
    managedIdentityPrincipalId: containerApp.outputs.managedIdentityPrincipalId
    entraClientSecret: entraClientSecret
  }
}

// ---------------------------------------------------------------------------
// Outputs  (used by CI/CD pipeline and post-deployment configuration)
// ---------------------------------------------------------------------------

@description('Default URL of the Container App (before custom domain).')
output containerAppUrl string = containerApp.outputs.defaultUrl

@description('Name of the Container App (for CI/CD deploy step).')
output containerAppName string = containerApp.outputs.containerAppName

@description('ACR login server (for CI/CD push step).')
output acrLoginServer string = acr.outputs.loginServer

@description('ACR resource name (for CI/CD az acr login).')
output acrName string = acrName

@description('Key Vault URI.')
output keyVaultUri string = keyVault.outputs.keyVaultUri

@description('Log Analytics workspace resource ID.')
output logAnalyticsWorkspaceId string = logAnalytics.outputs.workspaceId

@description('''
FQDN of the Container Apps Environment default domain.
Use this as the CNAME target when configuring your custom domain.
''')
output containerAppFqdn string = containerApp.outputs.fqdn
