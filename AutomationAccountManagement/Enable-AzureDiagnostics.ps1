
<#PSScriptInfo

.VERSION 1.1

.GUID 1ce8af29-11c2-4b5a-9548-d6bb359c5bf8

.AUTHOR AzureAutomationTeam

.COMPANYNAME Microsoft

.COPYRIGHT 

.TAGS AzureAutomation OMS LogAnalytics 

.LICENSEURI 

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/AutomationAccountManagement/Enable-AzureDiagnostics.ps1

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES

VERSION 1.1
EDIT BY JENNY HUNTER

#>
#Requires -Module AzureRM.Insights
#Requires -Module AzureRM.OperationalInsights
#Requires -Module AzureRM.Automation
#Requires -Module AzureRM.Storage 
#Requires -Module AzureRM.Resources 
#Requires -Module AzureRM.profile 

<# 

.SYNOPSIS 
    Configures Azure Diagnostics and Log Analytics to receive Azure Automation logs from the specified account. 
    This script is intended to be run locally and will not work in Azure Automation as it requires user input.  


.DESCRIPTION 
    This script configures Azure Diagnostics and Log Analytics to receive Azure Automation logs containing job status and job streams. 
    The logs will be sent from the specified Automation account to a generated storage account and OMS workspace.  

    This script should run locally (outside of Azure Automation) and requires you to interactively authenticate to your Azure account.  
    To use this script in Azure Automation, use a run-as account or an Automation credential to authenticate and remove all references to Read-Host.  
    See https://azure.microsoft.com/en-us/documentation/articles/automation-sec-configure-azure-runas-account/ for more information on authentication to Azure.  
    

.PARAMETER AutomationAccountName
    The name of your Automation account.

.PARAMETER LogAnalyticsWorkspaceName    
    The name of the Log Analytics workspace that you want to send you Automation logs to.   


.NOTES
    AUTHOR: AzureAutomationTeam
    LASTEDIT: August 3, 2016 

#>

Param
(

    [Parameter(Mandatory=$true)]
    [String] $AutomationAccountName,

    [Parameter(Mandatory=$true)]
    [String] $LogAnalyticsWorkspaceName
)

#Validates that the Automation & Log Analytics resource is not null and that the correct account/workspace is being used
function Validate-Resource([string] $Name, [object] $Resource) 
{

    If ($Resource -eq $null)
    {
        throw "$Name not found."
    }
    ElseIf ($Resource.Count -gt 1) 
    {
       If ($Resource.ResourceType -eq "Microsoft.OperationalInsights/workspaces")
       {
            $RG = Read-Host -Prompt "Resource Group needed to identify Log Analytics workspace $Name.`  Type the Resource Group for this workspace"
            $Resource = Get-AzureRmOperationalInsightsWorkspace -Name $Name -ResourceGroupName $RG
            if ($Workspace -eq $null) 
            {
                throw "Workspace $Name in Resource Group $RG was not found. " 
            }
       }
       ElseIf($Resource.ResourceType -eq "Microsoft.Automation/automationAccounts")
       {
            $RG = Read-Host -Prompt "Resource Group needed to identify Automation account $Name.`  Type the Resource Group for this account"
            $Resource = Get-AzureRMAutomationAccount -Name $Name -ResourceGroupName $RG
            if ($Resource -eq $null) 
            {
                throw "Account $Name in Resource Group $RG was not found." 
            }
       }
    }
    return $Resource
}

$ErrorActionPreference = 'stop'

#Authenticate to your Azure account 
Add-AzureRMAccount | Write-Verbose

# Find the Log Analytics workspace to configure
$Resource = Get-AzureRmResource -ResourceType "Microsoft.OperationalInsights/workspaces" -Name $LogAnalyticsWorkspaceName 
$LogAnalyticsResource = Validate-Resource -Name $LogAnalyticsWorkspaceName -Resource $Resource

# Find the Automation account to use 
$Resource = Get-AzureRmResource -Name $AutomationAccountName -ResourceType Microsoft.Automation/AutomationAccounts
$AutomationResource = Validate-Resource -Name $AutomationAccountName -Resource $Resource

# Make sure name of Storage account follows Storage naming rules
$StorageAccountName = ($AutomationAccountName.ToLower() + "omsstorage") -creplace '[^a-z0-9 ]',''
If($StorageAccountName.Length -gt 23) { $StorageAccountName = $StorageAccountName.substring(0,23) }

# Check if storage account exists & create it if it does not
Try {
    $StorageAccount = Get-AzureRMStorageAccount -StorageAccountName $StorageAccountName -ResourceGroupName $AutomationResource.ResourceGroupName 
}
Catch 
{
    Write-Verbose "Creating storage account $StorageAccountName for OMS logs."
    $StorageAccount = New-AzureRMStorageAccount -StorageAccountName $StorageAccountName -Location $AutomationResource.Location -ResourceGroupName $AutomationResource.ResourceGroupName -Type Standard_LRS
}


# Enable diagnostics on the automation account to send logs to the storage account
Set-AzureRmDiagnosticSetting -ResourceId $AutomationResource.ResourceId -StorageAccountId $StorageAccount.Id -Enabled $true -RetentionEnabled $true -RetentionInDays 180

# Enable the Automation Log Analytics solution
Set-AzureRmOperationalInsightsIntelligencePack -ResourceGroupName $LogAnalyticsResource.ResourceGroupName -WorkspaceName $LogAnalyticsResource.Name -Intelligencepackname AzureAutomation -Enabled $true 


