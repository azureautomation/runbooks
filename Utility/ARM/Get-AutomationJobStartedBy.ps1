<#
.SYNOPSIS 
    This sample automation runbook finds who started jobs in an Automation account

.DESCRIPTION
    This sample automation runbook finds who started jobs in an Automation account
    You need to update the Azure modules to the latest for the Automation account and then
    import AzureRM.Insights from the module gallery.

.PARAMETER AutomationResourceGroupName
    Required. Resource group the automation account is in.

.PARAMETER AutomationAccountName
    Required. Name of the Automation account

.PARAMETER StartTime
    Optioinal. Defaults to the last 24 hours

.Example
    .\Get-AutomationJobStartedBy -AutomationResourceGroupName contosogroup -AutomationAccountName contoso

.Example
    .\Get-AutomationJobStartedBy -AutomationResourceGroupName contosogroup -AutomationAccountName contoso -StartTime (Get-Date).AddDays(-7)

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: March 1st 2018
#>

param(
    [Parameter(Mandatory=$true)]
    $AutomationResourceGroupName,

    [Parameter(Mandatory=$true)]
    $AutomationAccountName,

    [Parameter(Mandatory=$false)]
    $StartTime = $null

)
# Authenticate with Azure.
$ServicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
Add-AzureRmAccount `
    -ServicePrincipal `
    -TenantId $ServicePrincipalConnection.TenantId `
    -ApplicationId $ServicePrincipalConnection.ApplicationId `
    -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint | Write-Verbose

Select-AzureRmSubscription -SubscriptionId $ServicePrincipalConnection.SubscriptionID | Write-Verbose

# Set default window to search jobs to 24 hours if a value is not passed in.
if ($StartTime -eq $null)
{
    $StartTime = (Get-Date).AddDays(-1)
}
else 
{
    $StartTime = Get-Date $StartTime    
}

# Get list of jobs in the resource group
$JobAcvitityLogs = Get-AzureRmLog -ResourceGroupName $AutomationResourceGroupName -StartTime $StartTime `
                                | Where-Object {$_.Authorization.Action -eq "Microsoft.Automation/automationAccounts/jobs/write"}

$JobInfo = @{}
foreach ($log in $JobAcvitityLogs)
{
    # Get job resource
    $JobResource = Get-AzureRmResource -ResourceId $log.ResourceId

    if ($JobInfo[$JobResource.Properties.jobId] -eq $null)
    { 
        # Get runbook
        $Runbook = Get-AzureRmAutomationJob -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName `
                                            -Id $JobResource.Properties.jobId

        # Add job information to hash table
        $JobInfo.Add($JobResource.Properties.jobId, @($Runbook.RunbookName,$Log.Caller, $Runbook.CreationTime))
    }
}

# Print out job information sorted by runbook name
$JobInfo.GetEnumerator() | Sort-Object {$_.Value}
