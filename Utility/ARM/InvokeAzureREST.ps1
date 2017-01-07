 <#
.SYNOPSIS 
    This sample automation runbook shows how to authenticate to Azure Resource Manager and perfom REST calls
    using the Azure automation RunAs connection.

.DESCRIPTION
    This sample automation runbook shows how to authenticate to Azure Resource Manager and perfom REST calls
    using the Azure automation RunAs connection.

    It authenticates using the service princpal that is created for the RunAs account and then starts a new 
    automation runbook job for Write-HelloWorld.ps1. You should create this runbook and publish before running
    this sample.

.PARAMETER ResourceGroupName
    Required. The name of the Azure Resource Group containing the Automation account.

.PARAMETER AutomationAccountName
    Required. The name of the Automation account that the Write-HelloWorld runbook is published in.

.PARAMETER SubscriptionId
    Optional. The subscription id that the resource group and automation account are in.
    If one is not specified, the subscription id that the Invoke-AzureREST runbook is in will be used.

.PARAMETER ModulePath
    Optional. The root module path of where the AzureRM.Automation module exists. The default is c:\modules
    as this is where it is in the automation container service.

.PARAMETER Timeout
    Optional. How long to wait for the job to complete before exiting. Default is 20 minutes.

.Example
    Create a Write-HelloWorld.ps1 and publish to Azure Automation service.
    Param(
        $Country
    )
    Write-Output ("Hello from " + $Country)

    and then call
    .\Invoke-AzureREST.ps1 -AutomationAccount ContosoAccount -ResourceGroup Contoso
 
.NOTES
    AUTHOR: Automation Team
    LASTEDIT: January 6th, 2017 
#>

Param
(
    [Parameter(Mandatory=$True)]
    [String] $AutomationAccount,

    [Parameter(Mandatory=$True)]
    [String] $ResourceGroup,

    [Parameter(Mandatory=$False)]
    [String] $SubscriptionId,

    [Parameter(Mandatory=$False)]
    [String] $ModulePath = "C:\Modules", # Default path to modules in the automation service container

    [Parameter(Mandatory=$false)]
    [int] $Timeout=1200 # 20 minutes
) 

# Stop on errors
$ErrorActionPreference = 'stop'
# Azure management uri
$ResourceAppIdURI = "https://management.core.windows.net/"

# Login uri for Azure AD
$LoginURI = "https://login.windows.net/"

# Find AzureRM.Automation module and load the Azure AD client library
$PathToAutomationModule = Get-ChildItem (Join-Path $ModulePath AzureRM.Automation) -Recurse
Add-Type -Path (Join-Path $PathToAutomationModule "Microsoft.IdentityModel.Clients.ActiveDirectory.dll")

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
 
# Create a runbook job
$JobId = [GUID]::NewGuid().ToString()
$URI =  “https://management.azure.com/subscriptions/$SubscriptionId/"`
     +"resourceGroups/$($ResourceGroup)/providers/Microsoft.Automation/"`
     +"automationAccounts/$AutomationAccount/jobs/$($JobId)?api-version=2015-10-31"
 
# Runbook and parameters
$Body = @"
        {
           "properties":{
           "runbook":{
               "name":"Write-HelloWorld"
           },
           "parameters":{
                "Country":"USA"
           }
          }
       }
"@

# Start runbook job
$Response = Invoke-RestMethod -Uri $URI -Method Put -body $body -Headers $requestHeader

# Wait for job to complete 
$Loop = $true
$TimeoutLoop = 0
While ($Loop -and $TimeoutLoop -lt ($Timeout/10) ) {
    Sleep 10
    $TimeoutLoop++
    $Job = Invoke-RestMethod -Uri $URI -Method GET -Headers $RequestHeader
    $Status = $job.properties.provisioningState
    write-output ("Provisioning State is " + $Status)
    $Loop = (($Status -ne "Succeeded") -and ($Status -ne "Failed") -and ($Status -ne "Suspended") -and ($Status -ne "Stopped"))
}
 

# Print output from the job
$URI  = "https://management.azure.com/subscriptions/$SubscriptionId/"`
      +"resourceGroups/$ResourceGroup/providers/Microsoft.Automation/"`
      +"automationAccounts/$AutomationAccount/jobs/$JobId/"`
      +"streams?$filter=properties/streamType%20eq%20'Output'&api-version=2015-10-31"
       
$Response = Invoke-RestMethod -Uri $URI -Method GET -Headers $requestHeader
 
$Response.value.properties.summary  
