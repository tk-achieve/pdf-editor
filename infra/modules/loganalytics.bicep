// ---------------------------------------------------------------------------
// Log Analytics Workspace
// Receives container logs and platform metrics for audit / HIPAA evidence.
// ---------------------------------------------------------------------------
@description('Name prefix for the workspace.')
param name string

@description('Azure region.')
param location string

@description('Retention in days (90 minimum for HIPAA audit trail).')
@minValue(90)
@maxValue(730)
param retentionDays int = 90

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${name}-law'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
@description('Full resource ID of the workspace.')
output workspaceId string = workspace.id

@description('Customer ID used by Container Apps environment log config.')
output customerId string = workspace.properties.customerId

@description('Shared key for Container Apps environment log config.')
@secure()
output sharedKey string = workspace.listKeys().primarySharedKey
