// ---------------------------------------------------------------------------
// Container App – Stirling PDF
// Deploys:
//   • User-assigned managed identity (used for ACR pull + KV secret access)
//   • Container Apps Environment (VNet-integrated, external ingress)
//   • Container App (Stirling PDF with Entra ID Easy Auth)
//   • authConfig resource enabling Microsoft/Entra ID authentication
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
@description('Base name for all resources.')
param name string

@description('Azure region.')
param location string

@description('ACR login server (e.g. myacr.azurecr.io).')
param acrLoginServer string

@description('Image tag to deploy (e.g. sha-abc1234 or latest).')
param imageTag string = 'latest'

@description('Log Analytics workspace customer ID.')
param logAnalyticsCustomerId string

@description('Log Analytics workspace shared key.')
@secure()
param logAnalyticsSharedKey string

@description('Resource ID of the infrastructure subnet for the Container Apps Environment.')
param infraSubnetId string

@description('Entra ID app registration client ID (for Easy Auth).')
param entraClientId string

@description('Azure AD tenant ID.')
param tenantId string

@description('Full URI of the Key Vault secret holding the Entra client secret.')
param kvEntraSecretUri string

@description('Company / app display name shown in the Stirling PDF UI.')
param companyDisplayName string = 'PDF Editor'

@description('Minimum replica count (1 ensures always-on; 0 enables scale-to-zero).')
@minValue(0)
@maxValue(10)
param minReplicas int = 1

@description('Maximum replica count.')
@minValue(1)
@maxValue(10)
param maxReplicas int = 3

// ---------------------------------------------------------------------------
// User-Assigned Managed Identity
// Grants the container permission to pull from ACR and read KV secrets
// without storing any credentials.
// ---------------------------------------------------------------------------
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${name}-id'
  location: location
}

// ---------------------------------------------------------------------------
// Container Apps Environment (VNet-integrated, external ingress)
// ---------------------------------------------------------------------------
resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${name}-env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: infraSubnetId
      internal: false          // External: gives a public FQDN for custom-domain binding
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Container App
// ---------------------------------------------------------------------------
resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: environment.id
    workloadProfileName: 'Consumption'

    configuration: {
      // ----- Ingress --------------------------------------------------------
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
        allowInsecure: false        // Force HTTPS
        traffic: [
          {
            weight: 100
            latestRevision: true
          }
        ]
      }

      // ----- Registry (pull via managed identity – no stored creds) ---------
      registries: [
        {
          server: acrLoginServer
          identity: managedIdentity.id
        }
      ]

      // ----- Secrets (Key Vault references) ----------------------------------
      secrets: [
        {
          name: 'microsoft-auth-secret'          // Referenced by authConfig below
          keyVaultUrl: kvEntraSecretUri
          identity: managedIdentity.id
        }
      ]
    }

    template: {
      containers: [
        {
          name: 'stirling-pdf'
          image: '${acrLoginServer}/stirling-pdf:${imageTag}'
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          env: [
            // ---- Security (Easy Auth handles authn; disable built-in UI) ----
            { name: 'DOCKER_ENABLE_SECURITY', value: 'false' }

            // ---- Branding ---------------------------------------------------
            { name: 'APP_HOME_NAME', value: companyDisplayName }
            { name: 'APP_HOME_DESCRIPTION', value: 'Internal PDF editing tool' }
            { name: 'APP_NAVBAR_NAME', value: companyDisplayName }

            // ---- Localisation -----------------------------------------------
            { name: 'APP_LOCALE', value: 'en_GB' }
            { name: 'LANGS', value: 'en_GB' }

            // ---- Features ---------------------------------------------------
            { name: 'INSTALL_BOOK_AND_ADVANCED_HTML_OPS', value: 'false' }
            { name: 'DISABLE_ADDITIONAL_FEATURES', value: 'true' }
          ]

          // ---- Health probes -----------------------------------------------
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/actuator/health'
                port: 8080
              }
              initialDelaySeconds: 60
              periodSeconds: 30
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/actuator/health'
                port: 8080
              }
              initialDelaySeconds: 30
              periodSeconds: 10
              failureThreshold: 3
            }
            {
              type: 'Startup'
              httpGet: {
                path: '/actuator/health'
                port: 8080
              }
              initialDelaySeconds: 10
              periodSeconds: 10
              failureThreshold: 12    // Allow up to 120 s startup
            }
          ]
        }
      ]

      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: '20'
              }
            }
          }
        ]
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Entra ID (Easy Auth) configuration
// Redirects unauthenticated requests to the Microsoft login page.
// Only users in the tenant can log in.
// ---------------------------------------------------------------------------
resource authConfig 'Microsoft.App/containerApps/authConfigs@2024-03-01' = {
  parent: containerApp
  name: 'current'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      redirectToProvider: 'azureactivedirectory'
      unauthenticatedClientAction: 'RedirectToLoginPage'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        isAutoProvisioned: false
        registration: {
          clientId: entraClientId
          clientSecretSettingName: 'microsoft-auth-secret'   // Maps to the Container App secret above
          openIdIssuer: 'https://sts.windows.net/${tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            'api://${entraClientId}'
          ]
        }
      }
    }
    login: {
      preserveUrlFragmentsForLogins: false
      tokenStore: {
        enabled: true
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
@description('FQDN assigned by Azure to the Container App (before custom domain).')
output fqdn string = containerApp.properties.configuration.ingress.fqdn

@description('Default URL of the Container App.')
output defaultUrl string = 'https://${containerApp.properties.configuration.ingress.fqdn}'

@description('Name of the Container App (used by CI/CD deploy step).')
output containerAppName string = containerApp.name

@description('Resource ID of the Container Apps Environment.')
output environmentId string = environment.id

@description('Resource ID of the managed identity.')
output managedIdentityId string = managedIdentity.id

@description('Principal ID of the managed identity (for role assignments).')
output managedIdentityPrincipalId string = managedIdentity.properties.principalId
