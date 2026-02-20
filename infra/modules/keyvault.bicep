// ---------------------------------------------------------------------------
// Azure Key Vault
// Stores the Entra ID app-registration client secret used by Easy Auth.
// The managed identity is granted Key Vault Secrets User so the Container App
// can retrieve secrets at runtime without any stored credentials.
// ---------------------------------------------------------------------------
@description('Name of the Key Vault (globally unique, 3–24 chars).')
param name string

@description('Azure region.')
param location string

@description('Azure AD tenant ID (used to scope the vault).')
param tenantId string

@description('Principal ID of the managed identity that will read secrets.')
param managedIdentityPrincipalId string

@description('Entra ID app registration client secret value.')
@secure()
param entraClientSecret string

// ---------------------------------------------------------------------------
// Key Vault
// ---------------------------------------------------------------------------
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenantId
    enableRbacAuthorization: true    // Use RBAC, not legacy access policies
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'   // Container Apps VNet egress needs access;
    // Optionally lock down to specific IPs or add a private endpoint.
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

// ---------------------------------------------------------------------------
// Secret: Entra client secret
// ---------------------------------------------------------------------------
resource entraSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'entra-client-secret'
  properties: {
    value: entraClientSecret
    attributes: {
      enabled: true
    }
  }
}

// ---------------------------------------------------------------------------
// Role: Key Vault Secrets User → managed identity
// Built-in role definition ID: 4633458b-17de-408a-b874-0445c86b69e6
// ---------------------------------------------------------------------------
var kvSecretsUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)

resource kvSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, managedIdentityPrincipalId, kvSecretsUserRoleId)
  scope: kv
  properties: {
    roleDefinitionId: kvSecretsUserRoleId
    principalId: managedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
@description('Base URI of the Key Vault.')
output keyVaultUri string = kv.properties.vaultUri

@description('Full URI of the Entra client secret (used in Container App secret ref).')
output entraSecretUri string = entraSecret.properties.secretUri
