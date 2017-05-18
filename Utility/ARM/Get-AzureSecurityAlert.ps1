<#
.SYNOPSIS 
    This sample automation runbook collects statuses and alerts counts from Azure Security center.

.DESCRIPTION
    This sample automation runbook collects statuses and alerts counts from Azure Security center.

    It authenticates using the service princpal that is created for the RunAs account and will therefore
    only run in the Azure Automation service unless you are using the Azure Automation ISE Add-on locally.

.PARAMETER SubscriptionId
    Optional. The subscription id where Azure Security Center is available.
    If one is not specified, the subscription id where the automation account exists will be used.

.Example
    .\Get-AzureSecurityAlert.ps1
 
.NOTES
    AUTHOR: Automation Team
    LASTEDIT: May 18th, 2017 
#>

Param
(
    [Parameter(Mandatory=$False)]
    [String] $SubscriptionId
) 

# Stop on errors
$ErrorActionPreference = 'stop'

# Azure management uri
$ResourceAppIdURI = "https://management.core.windows.net/"

# Login uri for Azure AD
$LoginURI = "https://login.windows.net/"

# Find the Azure AD client library on the computer
$PathToADLibrary = Get-ChildItem -Recurse ($env:SystemDrive + "\") -Include "Microsoft.IdentityModel.Clients.ActiveDirectory.dll" -ErrorAction SilentlyContinue | select -Property FullName -First 1
Add-Type -Path $PathToADLibrary.FullName

# Get RunAsConnection
$RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
$Certifcate = Get-AutomationCertificate -Name "AzureRunAsCertificate"

# Get default subscription if one is not passed in.
if ([string]::IsNullOrEmpty($SubscriptionId))
{
    $SubscriptionId = $RunAsConnection.SubscriptionId
}

# Set up authentication using service principal client certificate
$Authority = $LoginURI + $RunAsConnection.TenantId
$AuthContext = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext" -ArgumentList $Authority
$ClientCertificate = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.ClientAssertionCertificate" -ArgumentList $RunAsConnection.ApplicationId, $Certifcate
$AuthResult = $AuthContext.AcquireToken($ResourceAppIdURI, $ClientCertificate)

# Set up header with authorization token
$AuthToken = $AuthResult.CreateAuthorizationHeader()
$RequestHeader = @{
  "Content-Type" = "application/json";
  "Authorization" = "$AuthToken"
}

# Get security statuses
$AzureAPIVersion = "2015-06-01-preview"
$URI = “https://management.azure.com/subscriptions/$SubscriptionId/providers/microsoft.Security/securityStatuses?api-version=$AzureAPIVersion"
$Response = Invoke-RestMethod -Uri $URI -Method GET -Headers $requestHeader
Write-Output("Number of Security Center statuses:")
$Response.value.Count

# Get security alerts
$URI = “https://management.azure.com/subscriptions/$SubscriptionId/providers/microsoft.Security/alerts?api-version=$AzureAPIVersion"
$Response = Invoke-RestMethod -Uri $URI -Method GET -Headers $requestHeader
Write-Output("Number of Security Center alerts:")
$Response.value.Count
 
