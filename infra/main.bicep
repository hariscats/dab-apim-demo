targetScope = 'resourceGroup'

// ── Parameters ─────────────────────────────────────────────────────────────
param envName string
param location string = resourceGroup().location
param mysqlAdminLogin string
@secure()
param mysqlAdminPassword string
param apimPublisherEmail string = 'admin@contoso.com'
param apimPublisherName string = 'Contoso'

// ── Variables ───────────────────────────────────────────────────────────────
var lawName         = 'law-${envName}'
var mysqlServerName = 'mysql-${envName}'
var mysqlDbName     = 'productsdb'
var acrName         = replace('acr${envName}', '-', '')
var caeEnvName      = 'cae-${envName}'
var containerAppName = 'ca-dab-${envName}'
var apimName        = 'apim-${envName}'

// ═══════════════════════════════════════════════════════════════════════════
// TIER 0 – no dependencies
// ═══════════════════════════════════════════════════════════════════════════

// 1. Log Analytics Workspace
resource law 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: lawName
  location: location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

// 2. MySQL Flexible Server
resource mysqlServer 'Microsoft.DBforMySQL/flexibleServers@2023-06-30' = {
  name: mysqlServerName
  location: location
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    administratorLogin: mysqlAdminLogin
    administratorLoginPassword: mysqlAdminPassword
    version: '8.0.21'
    storage: {
      storageSizeGB: 20
      iops: 396
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// 3. Azure Container Registry
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TIER 1 – depends on Tier 0
// ═══════════════════════════════════════════════════════════════════════════

// 4. MySQL Database
resource mysqlDb 'Microsoft.DBforMySQL/flexibleServers/databases@2023-06-30' = {
  parent: mysqlServer
  name: mysqlDbName
  properties: {
    charset: 'utf8mb4'
    collation: 'utf8mb4_unicode_ci'
  }
}

// 5. MySQL Firewall – allow Azure services
resource mysqlFirewallAllowAzure 'Microsoft.DBforMySQL/flexibleServers/firewallRules@2023-06-30' = {
  parent: mysqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// 6. Container Apps Managed Environment (Consumption)
resource cae 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: caeEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TIER 2 – depends on Tier 1
// ═══════════════════════════════════════════════════════════════════════════

// 7. API Management (Developer tier)
resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: apimName
  location: location
  sku: {
    name: 'Developer'
    capacity: 1
  }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
  }
}

// 8. Container App – DAB
var acrCredentials = acr.listCredentials()
var connectionString = 'Server=${mysqlServer.properties.fullyQualifiedDomainName};Database=${mysqlDbName};Uid=${mysqlAdminLogin};Pwd=${mysqlAdminPassword};SslMode=Required;'

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: location
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 5000
        transport: 'auto'
      }
      registries: [
        {
          server: acr.properties.loginServer
          username: acrCredentials.username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        {
          name: 'db-connection-string'
          value: connectionString
        }
        {
          name: 'acr-password'
          value: acrCredentials.passwords[0].value
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'dab'
          image: 'mcr.microsoft.com/azure-databases/data-api-builder:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'DATABASE_CONNECTION_STRING'
              secretRef: 'db-connection-string'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TIER 3 – depends on Container App FQDN
// ═══════════════════════════════════════════════════════════════════════════

// 9. APIM Logger – Azure Monitor / Log Analytics
resource apimLogger 'Microsoft.ApiManagement/service/loggers@2023-05-01-preview' = {
  parent: apim
  name: 'law-logger'
  properties: {
    loggerType: 'azureMonitor'
    description: 'Log Analytics workspace logger'
    isBuffered: true
    resourceId: law.id
  }
}

// 10. APIM Diagnostic – azuremonitor
resource apimDiagnostic 'Microsoft.ApiManagement/service/diagnostics@2023-05-01-preview' = {
  parent: apim
  name: 'azuremonitor'
  properties: {
    loggerId: apimLogger.id
    alwaysLog: 'allErrors'
    sampling: {
      percentage: 100
      samplingType: 'fixed'
    }
    logClientIp: true
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
  }
}

// 11. APIM Backend – DAB Container App
resource dabBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = {
  parent: apim
  name: 'dab-backend'
  properties: {
    url: 'https://${containerApp.properties.configuration.ingress.fqdn}'
    protocol: 'http'
    description: 'DAB Container App backend'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// 12. APIM API – products
resource productsApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'products-api'
  properties: {
    displayName: 'Products API'
    description: 'REST API for the products table via Data API Builder'
    path: 'api'
    protocols: [
      'https'
    ]
    subscriptionRequired: true
    serviceUrl: 'https://${containerApp.properties.configuration.ingress.fqdn}'
  }
}

// 13. APIM Operation – GET /products
resource getProductsOperation 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: productsApi
  name: 'get-products'
  properties: {
    displayName: 'Get Products'
    method: 'GET'
    urlTemplate: '/products'
    description: 'Retrieve all products from the database'
  }
}

// 14. APIM API Policy – set backend
resource productsApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  parent: productsApi
  name: 'policy'
  properties: {
    format: 'xml'
    value: '''<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="dab-backend" />
  </inbound>
  <backend>
    <forward-request />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>'''
  }
}

// 15. APIM Subscription – scoped to products-api
resource dabSubscription 'Microsoft.ApiManagement/service/subscriptions@2023-05-01-preview' = {
  parent: apim
  name: 'dab-subscription'
  properties: {
    displayName: 'DAB Products Subscription'
    scope: productsApi.id
    state: 'active'
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Outputs
// ═══════════════════════════════════════════════════════════════════════════

output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
output apimGatewayUrl string = apim.properties.gatewayUrl
output acrLoginServer string = acr.properties.loginServer
output mysqlServerFqdn string = mysqlServer.properties.fullyQualifiedDomainName
output mysqlDbName string = mysqlDbName
output mysqlServerName string = mysqlServerName
output apimName string = apimName
