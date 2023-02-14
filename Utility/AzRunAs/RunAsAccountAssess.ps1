<#
.SYNOPSIS
    This script is used to check which automation accounts have run as account configured.
.DESCRIPTION
    This script will assess automation account which has configured RunAs accounts.
    Prerequisites: 
    1. .NET framework 4.7.2 or later installed.
    2. Windows PowerShell version 5.1(64-bit) or later installed and run with Administrator permissions.
    3. Azure Az PowerShell module latest version installed, having minimum version Az.Accounts (2.5.4)`, `Az.Resources (4.4.0)` & `Az.Automation (1.7.1)` cmdlets
    4. You need the following permissions on the Azure user account:
        a. ‘Reader’ access on the Azure subscription that has the Azure Automation account.
    Examples to run :
        1) To assess automation runas accounts in all subscriptions - Ex: .\RunAsAccountAssess.ps1 
        2) To assess automation runas accounts in set of subscriptions - Ex: .\RunAsAccountAssess.ps1 - SubscriptionIds subId1,subId2
.PARAMETER SubscriptionIds
    [Optional] Assess all the Automation run as accounts from the input subscriptions.
.PARAMETER Env
    [Optional] Cloud environment name. 'AzureCloud' by default.
.PARAMETER Verbose
    [Optional] Enable verbose logging
.EXAMPLE
    PS> .\RunAsAccountAssess.ps1 -SubscriptionIds subId1,subId2
.AUTHOR Microsoft
.VERSION 1.0
#>

#Requires -Modules @{ ModuleName="Az.Accounts"; ModuleVersion="2.5.4" },@{ ModuleName="Az.Resources"; ModuleVersion="4.4.0" },@{ ModuleName="Az.Automation"; ModuleVersion="1.7.1" }
#Requires -PSEdition Desktop
#Requires -RunAsAdministrator

[CmdletBinding()]
Param(
    [string[]]
    $SubscriptionIds,

    [ValidateSet("AzureCloud", "AzureUSGovernment", "AzureChinaCloud")]
    [Parameter(Mandatory = $false, HelpMessage = "Cloud environment name. 'AzureCloud' by default")]
    [string]
    $Env = "AzureCloud"
)

function Show-Description {
    Write-Warning ""
    Write-Warning "The script can be used to run at a time on set of subscriptions." 
    Write-Warning ""

    Write-Warning "Prerequisites:"
    Write-Warning "1. .NET framework 4.7.2 or later installed."
    Write-Warning "2. Windows PowerShell version 5.1(64-bit) or later installed and run with Administrator permissions."
    Write-Warning "3. Azure Az PowerShell module latest version installed, having minimum version Az.Accounts (2.5.4)`, `Az.Resources (4.4.0)` & `Az.Automation (1.7.1)` cmdlets"
    Write-Warning "4. You need the following permissions on the Azure user account:"
    Write-Warning "    a. Reader access on the Azure subscription that has the Azure Automation account, and"

    Write-Warning "Example to run :"
    Write-Warning "    To assess run as accounts in set of subscriptions - Ex: .\AutomationAssess.ps1 - SubscriptionIds subId1,subId2"
}

class AutomationAccount {
    [string] $Name
    [string] $ResourceId
    [string] $Region
    [string] $ResourceGroup
    [string] $SubscriptionId
    [string] $RunAsAppId
    [DateTimeOffset] $RunAsConnectionCreationTime
    [bool] $UsesThirdParytCert
    [string] $Thumbprint
    [bool] $IsExpireCert
}

$RunAsAutomationAccounts = New-Object System.Collections.ArrayList

function Assess-Accounts {
    Write-Output ""
    Write-Output "================================================="
    Write-Output "Started Assessing Automation accounts..."
    Write-Output "================================================="

    # Get all automation accounts accessible to current user
    $queryPayload = @{
        query = 'resources | where type == "microsoft.automation/automationaccounts"'
        subscriptions = $SubscriptionIds
        options = @{
        '$top' = 10000
        '$skip' = 0
        '$skipToken' = ""
        'resultFormat' = "table"
        }
    }
    $payload = $queryPayload | ConvertTo-Json

    $resp = Invoke-AzRestMethod -Path "/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01" -Method POST -Payload $payload
    $resp = $resp.Content | ConvertFrom-Json

    $allAccounts = New-Object System.Collections.ArrayList
    $defaultDate = (Get-Date 01-01-1970)
    foreach ($row in $resp.data.rows)
    {
        $a = [AutomationAccount]@{
            ResourceId = $row[0]
            Name = $row[1]
            Region = $row[5]
            ResourceGroup = $row[6]
            SubscriptionId = $row[7]
            RunAsAppId = ""
            RunAsConnectionCreationTime = $defaultDate
            UsesThirdParytCert = $false
            Thumbprint= ""
            IsExpireCert = $false
        }
        Write-Debug "$($a.Name), $($a.Region), $($a.ResourceGroup), $($a.SubscriptionId)"

        $allAccounts.Add($a) > $null
    }

    Assess-AccountsBySubscriptionGroup $allAccounts
    Write-Output ""
    Write-Output "==================================================="
    Write-Output "Completed Assessing Automation accounts..."
    Write-Output "==================================================="  
    Write-Output ""  
}

function Assess-AccountsBySubscriptionGroup {
    param ($accounts)

    # Group by subscription ID
    $accountsGroup = $accounts | Group-Object { $_.SubscriptionId }

    foreach ($item in $accountsGroup) {
        Write-Output ""
        Write-Output "Procesing accounts in subscription $($item.Name): $($item.Group.Count)"
        Select-AzSubscription -SubscriptionId $item.Name > $null

        foreach ($a in $item.Group) {
            Assess-Account $a
        }
    }
}

function Assess-Account {
    param ([AutomationAccount] $account)

    Write-Verbose "Assessing account $($account.ResourceId)"
    # Get the RunAs connection
    $conn = Get-AzAutomationConnection -AutomationAccountName $account.Name -ResourceGroupName $account.ResourceGroup -Name "AzureRunAsConnection" -ErrorAction SilentlyContinue
    
    $runAsCert = Get-AzAutomationCertificate -ResourceGroupName $account.ResourceGroup -AutomationAccountName $account.Name -Name "AzureRunAsCertificate" -ErrorAction SilentlyContinue

    if ($null -ne $conn -and $conn.ConnectionTypeName -eq "AzureServicePrincipal" -and $null -ne $runAsCert) {
        $account.RunAsAppId = $conn.FieldDefinitionValues.ApplicationId
        $account.RunAsConnectionCreationTime = $conn.CreationTime
        $account.Thumbprint= $runAsCert.Thumbprint
        $reqdiff = New-TimeSpan -Days 1

        if ((($runAsCert.ExpiryTime) - (Get-Date)) -gt $reqdiff) {
            $RunAsAutomationAccounts.Add($account) > $null
            Write-Verbose "Account $($a.ResourceId) is using RunAsAccount"
        }
        else {
            Write-Verbose "Account $($a.ResourceId) has expired/near-expiry RunAs Account."
        }
    }
    else {
        Write-Verbose "Account $($a.ResourceId) is not using RunAsAccount"
    }
}

# Remove unnecessary new line characters and whitespace in url
Function Trim-Url
{
    param(
        [string]
        $Url
    )

    return $Url -replace '`n','' -replace '\s+', ''
}

function ParseResourceId {
    param (
       [string]$resourceID
   )
   $array = $resourceID.Split('/')
   $indexSubscriptionId = 0..($array.Length -1) | where {$array[$_] -ieq 'subscriptions'}
   $indexResourceGroup = 0..($array.Length -1) | where {$array[$_] -ieq 'resourcegroups'}
   $result = $array.get($indexSubscriptionId+1), $array.get($indexResourceGroup+1), $array.get($array.Length -1)
   return $result
}


# Start point for the script
Show-Description

Connect-AzAccount -Environment $Env -ErrorAction Stop > $null

Write-Output "Start Assessment for given Subscriptions."
# Assess all the given subscriptions  Azure automation accounts
Assess-Accounts
