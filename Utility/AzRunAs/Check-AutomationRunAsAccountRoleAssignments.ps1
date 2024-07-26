
<#PSScriptInfo
 
.VERSION 1.0.2
 
.GUID c383bb81-c95e-4845-bc95-428db6a36ba5
 
.AUTHOR Automation Team
 
.COMPANYNAME
 
.COPYRIGHT
 
.TAGS AzureAutomation
 
.LICENSEURI
 
.PROJECTURI
 
.ICONURI
 
.EXTERNALMODULEDEPENDENCIES
 
.REQUIREDSCRIPTS
 
.EXTERNALSCRIPTDEPENDENCIES
 
.RELEASENOTES
 
 
.PRIVATEDATA
 
#> 



<#
 
.DESCRIPTION
 If your Azure Automation accounts contain a RunAs account, it will by default have the built-in Contributor role assigned to it. You can use this script
 to check the role assignments of your Azure Automation RunAs accounts, and determine whether their role assignment is the default one, or whether it has
 been changed to a different role definition.
#> 

<#
.SYNOPSIS
 Use this script to check the permissions of your Azure Automation RunAs accounts.
 
.PREREQUISITES
 To run this script, your Powershell console has to be connected to Azure. Use Login-AzAccount to log in.
    
.USAGE
 PS C:\MyScriptFolder>$mySubs = "00000000-0000-0000-0000-000000000000", "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
 PS C:\MyScriptFolder>.\Check-AutomationRunAsAccountRoleAssignments.ps1 `
            -SubscriptionIds $mySubs
 
.PARAMETERS
    -SubscriptionIds
        This is an array of subscriptions whose role assignments you want to change. The array can contain one or more subscriptions.
 
.NOTES
    LASTEDIT: June 26, 2019
#> 
Param (
    [Parameter(Mandatory = $true)]
    [String[]] $SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [bool] $UseAzModules = $false
)

function GetRunAsAccountAADApplicationId([string] $resourceGroupName, [string] $automationAccountName) 
{  
    $connectionAssetName = "AzureRunAsConnection"

    $runasAccountConnection = Get-AzAutomationConnection `
        -Name $connectionAssetName `
        -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -ErrorAction SilentlyContinue

    $runasAccountAADAplicationId = $null
    if ($runasAccountConnection) 
    {
        [GUID]$runasAccountAADAplicationId=$runasAccountConnection.FieldDefinitionValues['ApplicationId']
        Write-Host ("A RunAs account is present, and its ApplicationId is: " + $runasAccountAADAplicationId)
    }

    return $runasAccountAADAplicationId;
}

function GetRunAsAccountRoleAssignments ([string] $subscriptionId)
{
    Select-AzSubscription -Subscription $subscriptionId | Out-Null
    $automationAccounts = Get-AzAutomationAccount

    if (!$automationAccounts) 
    {
        Write-Host ("No automation account found in subscription " + $subscriptionId) -ForegroundColor Yellow
        Return
    } 

    Write-Host ("Looking up role assignments of all automation accounts in subscription " + $subscriptionId) 

    foreach( $automationAccount in $automationAccounts)
    {
        Write-Host ("Looking up role assignment for automation account: " + $automationAccount.AutomationAccountName)
        $runasAccountAADAplicationId = GetRunAsAccountAADApplicationId `
            -resourceGroupName $AutomationAccount.ResourceGroupName `
            -automationAccountName $AutomationAccount.AutomationAccountName
        if ($runasAccountAADAplicationId) 
        { 
			$currentRoleAssignments = Get-AzRoleAssignment `
				-ServicePrincipalName $runasAccountAADAplicationId `
				-ErrorAction Stop -WarningAction SilentlyContinue | Format-Table Scope, DisplayName, RoleDefinitionName, ObjectId

            Write-Host ("The following role assignments exist in automation account: " + $automationAccount.AutomationAccountName)
            $currentRoleAssignments

        } else {
            Write-Host  ("No RunAs account was found for automation account: " + $AutomationAccount.AutomationAccountName + ".") -ForegroundColor Yellow
            Write-Host
        }       
    }
}


# Main code starts here


if ($SubscriptionIds.Count -lt 1)
{
    Write-Host "No subscription IDs were provided. Please provide at least 1 subscription ID." -ForegroundColor Yellow
    exit -1
}

# Make new role assignments for automation accounts in all provided subscriptions
foreach ($subscriptionId in $SubscriptionIds)
{
    GetRunAsAccountRoleAssignments -subscriptionId $subscriptionId
}


# Main code ends here