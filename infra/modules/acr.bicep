// ---------------------------------------------------------------------------
// Azure Container Registry
// Stores the company-built Stirling PDF image.
// The managed identity is granted AcrPull so no stored credentials are needed.
// ---------------------------------------------------------------------------
@description('Name of the ACR (must be globally unique, alphanumeric only).')
param name string

@description('Azure region.')
param location string

@description('Principal ID of the managed identity that will pull images.')
param managedIdentityPrincipalId string

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false          // Never use admin creds; use managed identity
    publicNetworkAccess: 'Enabled'   // CI/CD runners need push access
    zoneRedundancy: 'Disabled'
  }
}

// ---------------------------------------------------------------------------
// Role: AcrPull → managed identity
// Built-in role definition ID: 7f951dda-4ed3-4680-a7ca-43fe172d538d
// ---------------------------------------------------------------------------
var acrPullRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d'
)

resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, managedIdentityPrincipalId, acrPullRoleDefinitionId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: managedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
@description('ACR login server (e.g. myacr.azurecr.io).')
output loginServer string = acr.properties.loginServer

@description('Full resource ID of the ACR.')
output acrId string = acr.id
