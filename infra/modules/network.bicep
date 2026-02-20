// ---------------------------------------------------------------------------
// Virtual Network
// Provides network isolation for the Container Apps Environment.
// The infrastructure subnet must be delegated to Microsoft.App/environments
// and sized /23 or larger (Azure requirement for Container Apps VNet injection).
// ---------------------------------------------------------------------------
@description('Name prefix for VNet resources.')
param name string

@description('Azure region.')
param location string

// ---------------------------------------------------------------------------
// VNet: 10.0.0.0/16
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: '${name}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      // -----------------------------------------------------------------------
      // Infrastructure subnet (/23 = 512 addresses)
      // Hosts the Container Apps Environment control plane and workload pods.
      // Azure requires this subnet to be dedicated (no other resources).
      // -----------------------------------------------------------------------
      {
        name: 'infrastructure'
        properties: {
          addressPrefix: '10.0.0.0/23'
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.KeyVault'
              locations: [location]
            }
          ]
        }
      }
      // -----------------------------------------------------------------------
      // Private-endpoints subnet (/27 = 32 addresses)
      // Reserved for future private endpoint attachments (ACR, Key Vault, etc.).
      // -----------------------------------------------------------------------
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: '10.0.2.0/27'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
@description('Full resource ID of the VNet.')
output vnetId string = vnet.id

@description('Resource ID of the infrastructure subnet (for Container Apps Environment).')
output infraSubnetId string = vnet.properties.subnets[0].id

@description('Resource ID of the private-endpoints subnet.')
output privateEndpointsSubnetId string = vnet.properties.subnets[1].id
