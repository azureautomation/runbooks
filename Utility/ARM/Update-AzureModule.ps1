<#
.SYNOPSIS 
    This Azure Automation runbook imports the latest version of the Azure modules from the PowerShell Gallery.

.DESCRIPTION
    This Azure Automation runbook imports the latest version of the Azure modules from the PowerShell Gallery.
    It requires that this runbook be run from the automation service and that the RunAs account is enabled on the 
    automation account.
    You could put this runbook on a schedule so that it updates the modules each month or call through a webhook
    as needed.

.PARAMETER AutomationResourceGroup
    Required. The name of the Azure Resource Group containing the Automation account.

.PARAMETER AutomationAccountName
    Required. The name of the Automation account.

.PARAMETER ModuleVersionOverrides
    Optional. A PowerShell HashTable or a JSON dictionary which contains module version overrides. Please be
    careful of version incompatibility between modules when overriding module versions.

      
.EXAMPLE
    Update-AzureModule -AutomationResourceGroup contoso -AutomationAccountName contosoaccount

.EXAMPLE
    Update-AzureModule -AutomationResourceGroup contoso -AutomationAccountName contosoaccount -ModuleVersionOverrides @{'Azure'="4.0.2"; 'Azure.Storage'="3.0.2"; 'AzureRM.Profile'="3.0.1"; 'AzureRM.Automation'="3.0.1"; 'AzureRM.Compute'="3.0.1"; 'AzureRM.Resources' = "4.0.1"; 'AzureRM.Sql' = "3.0.1"; 'AzureRM.Storage'="3.0.2"}

.EXAMPLE
    Update-AzureModule -AutomationResourceGroup contoso -AutomationAccountName contosoaccount -ModuleVersionOverrides '{"Azure" : "4.0.2", "AzureRM.Sql" : "3.0.1", "AzureRM.Automation" : "3.0.1", "Azure.Storage" : "3.0.2", "AzureRM.Resources" : "4.0.1", "AzureRM.Storage" : "3.0.2", "AzureRM.Compute" : "3.0.1", "AzureRM.Profile" : "3.0.1"}'


.NOTES
    AUTHOR: Automation Team
    LASTEDIT: Feb 17th, 2017 
#>
Param
(
    [Parameter(Mandatory=$True)]
    [String] $AutomationResourceGroup,

    [Parameter(Mandatory=$True)]
    [String] $AutomationAccount,

    [Parameter(Mandatory=$False)]
    [object] $ModuleVersionOverrides
    )

$versionOverrides = ""
# Try to parse module version overrides
if ($ModuleVersionOverrides) {
    if ($ModuleVersionOverrides.GetType() -eq [HashTable]) {
        $versionOverrides = ConvertTo-Json $ModuleVersionOverrides
    } elseif ($ModuleVersionOverrides.GetType() -eq [String]) {
        # Verify that the ModuleVersionOverrides can be deserialized
        try{
            $temp = ConvertFrom-Json $ModuleVersionOverrides -ErrorAction Stop
        }
        catch [System.ArgumentException] {
            $ex = $_ 
            # rethrow intended
            throw "The value of the parameter ModuleVersionOverrides is not a valid JSON string: ", $ex
        }
        $versionOverrides = $ModuleVersionOverrides
    } else {
        $ex = [System.ArgumentException]::new("The value of the parameter ModuleVersionOverrides should be a PowerShell HashTable or a JSON string")
        throw $ex
    }
}

try
{
    # Azure management uri
    $ResourceAppIdURI = "https://management.core.windows.net/"

    # Path to modules in automation container
    $ModulePath = "C:\Modules"

    # Login uri for Azure AD
    $LoginURI = "https://login.windows.net/"

    # Find AzureRM.Automation module and load the Azure AD client library
    $PathToAutomationModule = Get-ChildItem (Join-Path $ModulePath AzureRM.Automation) -Recurse
    Add-Type -Path (Join-Path $PathToAutomationModule "Microsoft.IdentityModel.Clients.ActiveDirectory.dll")

    # Get RunAsConnection
    $RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
    $Certifcate = Get-AutomationCertificate -Name "AzureRunAsCertificate"
    $SubscriptionId = $RunAsConnection.SubscriptionId


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
         +"resourceGroups/$($AutomationResourceGroup)/providers/Microsoft.Automation/"`
         +"automationAccounts/$AutomationAccount/jobs/$($JobId)?api-version=2015-10-31"
 
    # Runbook and parameters
    if($versionOverrides){
        $Body = @"
            {
               "properties":{
               "runbook":{
                   "name":"Update-AutomationAzureModulesForAccount"
               },
               "parameters":{
                    "ResourceGroupName":"$AutomationResourceGroup",
                    "AutomationAccountName":"$AutomationAccount",
                    "ModuleVersionOverrides":"$versionOverrides"
               }
              }
           }
"@
    } else {
        $Body = @"
            {
               "properties":{
               "runbook":{
                   "name":"Update-AutomationAzureModulesForAccount"
               },
               "parameters":{
                    "ResourceGroupName":"$AutomationResourceGroup",
                    "AutomationAccountName":"$AutomationAccount"
               }
              }
           }
"@
    }

    # Start runbook job
    Invoke-RestMethod -Uri $URI -Method Put -body $body -Headers $requestHeader        

}
catch 
{
        throw $_.Exception
} 
