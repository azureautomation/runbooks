<#
.SYNOPSIS 
    Finds the amount in seconds that each published runbook ran for over a period of time. This runbook must be run from the
    Azure Automation Service.

.DESCRIPTION
    Finds the amount in seconds that each published runbook ran over a period of time. It returns a hashtable of the runbook name
    and job time in seconds.
    This runbook must be run from the Azure Automation Service.


.PARAMETER RunbookName
    Optional. The name of the runbook to calculate the time ran. If not specified, all runbooks are calculated in the automation account.

.PARAMETER StartTime
    Optional. The start time on when to calculate the time ran from. If not specified, jobs over the last 90 days are used.
   
.EXAMPLE
   .\Get-RunbookTime.ps1 -RunbookName Finance

.EXAMPLE
    .\Get-RunbookTime.ps1 -StartTime "10/10/2016"

.EXAMPLE
    .\Get-RunbookTime.ps1 -RunbookName Finance -StartTime "10/10/2016"

.NOTES
    AUTHOR: Azure Automation Team
    LASTEDIT: October 11th, 2016  
#>

Param(
[Parameter(Mandatory=$false)]
[String] $RunbookName,

[Parameter(Mandatory=$false)]
[DateTime] $StartTime
)

# Authenticate to Azure so we can upload the runbooks
$RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection" 
    
Add-AzureRmAccount `
    -ServicePrincipal `
    -TenantId $RunAsConnection.TenantId `
    -ApplicationId $RunAsConnection.ApplicationId `
    -CertificateThumbprint $RunAsConnection.CertificateThumbprint | Write-Verbose

Select-AzureRmSubscription -SubscriptionId $RunAsConnection.SubscriptionID  | Write-Verbose 


# Find the automation account and resource group that this job is running in
$AutomationResource = Get-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts
foreach ($Automation in $AutomationResource)
{
    $Job = Get-AzureRmAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue

    if (!([string]::IsNullOrEmpty($Job)))
    {
        $AutomationAccount = $Job.AutomationAccountName
        $AutomationResourceGroup = $Job.ResourceGroupName
        break;
    }
}

if ([string]::IsNullOrEmpty($RunbookName))
{
    $Runbooks = Get-AzureRmAutomationRunbook -ResourceGroupName $AutomationResourceGroup -AutomationAccountName $AutomationAccount
}
else
{
    $Runbooks = Get-AzureRmAutomationRunbook -ResourceGroupName $AutomationResourceGroup -AutomationAccountName $AutomationAccount -Name $RunbookName
}

$JobTimePerRunbook = @{}
foreach ($Runbook in $Runbooks)
{

    $TotalTime = 0
    if ([string]::IsNullOrEmpty($StartTime))
    {
        $Jobs =  Get-AzureRmAutomationJob -ResourceGroupName $AutomationResourceGroup -AutomationAccountName $AutomationAccount -RunbookName $Runbook.Name
    }
    else
    {
        $Jobs =  Get-AzureRmAutomationJob -ResourceGroupName $AutomationResourceGroup -AutomationAccountName $AutomationAccount -RunbookName $Runbook.Name -StartTime $StartTime
    }

    foreach ($Job in $Jobs)
    {
       $TotalTime = $TotalTime + ($Job.EndTime -$Job.StartTime).Seconds
    } 
    $JobTimePerRunbook.Add($Runbook.Name,$TotalTime)
}
# Return sorted list based on number of seconds used
$JobTimePerRunbook.GetEnumerator() | Sort-Object {$_.Value} -Descending
