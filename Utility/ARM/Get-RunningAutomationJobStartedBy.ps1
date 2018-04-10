<#
.SYNOPSIS 
    This sample automation runbook finds the current job that is running started by information.
    This runbook must be run from the Automation service since it finds the current job at runtime.

.DESCRIPTION
    This sample automation runbook finds the current job that is running started by information
    This runbook must be run from the Automation service since it finds the current job at runtime.
    You need to update the Azure modules to the latest for the Automation account and then
    import AzureRM.Insights from the module gallery.

.PARAMETER AutomationResourceGroupName
    Required. Resource group the automation account is in.

.Example
    .\Get-RunningAutomationJobStartedBy -AutomationResourceGroupName contosogroup

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: March 1st 2018
#>
param(
    [Parameter(Mandatory=$true)]
    $AutomationResourceGroupName
)
# Authenticate with Azure.
$ServicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
Add-AzureRmAccount `
    -ServicePrincipal `
    -TenantId $ServicePrincipalConnection.TenantId `
    -ApplicationId $ServicePrincipalConnection.ApplicationId `
    -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint | Write-Verbose

Select-AzureRmSubscription -SubscriptionId $ServicePrincipalConnection.SubscriptionID | Write-Verbose

# Get the current job that is running...
$AutomationJobId = $PSPrivateMetadata.JobId.Guid

# Get jobs created in last 3 hours
$StartTime = (Get-Date).AddHours(-3)
# Loop here for a max of 60 seconds in order for the activity log to show up.
$JobInfo = @{}
$TimeoutLoop = 0
While ($JobInfo.Count -eq 0 -and $TimeoutLoop -lt 6 ) {
    $TimeoutLoop++
    $JobAcvitityLogs = Get-AzureRmLog -ResourceGroupName $AutomationResourceGroupName -StartTime $StartTime `
    | Where-Object {$_.Authorization.Action -eq "Microsoft.Automation/automationAccounts/jobs/write"}

    # Find caller for job
    foreach ($Log in $JobAcvitityLogs)
    {
        # Get job resource
        $JobResource = Get-AzureRmResource -ResourceId $Log.ResourceId

        if ($JobResource.Properties.jobId -eq $AutomationJobId)
        { 
            if ($JobInfo[$JobResource.Properties.jobId] -eq $null)
            {
                $JobInfo.Add($JobResource.Properties.jobId,$log.Caller)
            }
            break
        }
    }
    # If we didn't find the running job in activity log, sleep and try again.
    if ($JobInfo.Count -eq 0) 
    {
        Start-Sleep 10
    }
}

Write-Output $JobInfo

