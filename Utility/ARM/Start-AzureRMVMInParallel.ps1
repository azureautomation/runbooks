 <#
.SYNOPSIS 
    This automation runbook starts all Azure virtual machines that are running in a subscription

.DESCRIPTION
    This automation runbook starts all Azure virtual machines that are running in a subscription. It will
    process all VMs in parallel by creating a runbook in the automation service that starts a single virtual
    machine and then calls this runbook from this parent runboook. This runbook is designed to be run from
    the Azure automation service.

.PARAMETER VMResourceGroup
    Optional. The name of the resource group the VMs are contained in. If not specified, all VMs in the subscription are started.

.PARAMETER VM
    Optional. The name of the VM. If not specified, all VMs in the resource group are started.

.PARAMETER BackOffInSeconds
    Optional. This represents the back off time in seconds when the max running jobs in met in the service. https://docs.microsoft.com/en-us/azure/azure-subscription-service-limits#automation-limits
    Default is 30 seconds

.EXAMPLE
    Start-AzureRMARMVMInParallel -VMResourceGroup Contoso -VM Marketing1

.EXAMPLE
    Start-AzureRMARMVMInParallel -VMResourceGroup Contoso 

.EXAMPLE
    Start-AzureRMARMVMInParallel

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: May 10th, 2017 
#>
Param
(
    [Parameter(Mandatory=$false)]
    $VMResourceGroup,

    [Parameter(Mandatory=$false)]
    $VM,

    [Parameter(Mandatory=$false)]
    $BackOffInSeconds = 30
) 

# This is the runbook that will process work in parallel in the automation service.
$RunbookName = "Start-ParallelRunbook"
$ProcessRunbook = @'
param (
[Parameter(Mandatory=$true)]
$VM
)

$RunAsConnection = Get-AutomationConnection -Name AzureRunAsConnection
if ($RunAsConnection -eq $null)
{
    throw "RunAs connection is not available in the automation account. Please create one first"
}
Add-AzureRmAccount `
-ServicePrincipal `
-TenantId $RunAsConnection.TenantId `
-ApplicationId $RunAsConnection.ApplicationId `
-CertificateThumbprint $RunAsConnection.CertificateThumbprint | Write-Verbose

Select-AzureRmSubscription -SubscriptionId $RunAsConnection.SubscriptionID  | Write-Verbose

Start-AzureRMVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name | Write-Verbose
Get-AzureRMVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Status | Select Name -ExpandProperty Statuses

'@

# Function to return the Automation account information that this job is running in.
Function WhoAmI
{
    $AutomationResource = Get-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts
    
    foreach ($Automation in $AutomationResource)
    {
        $Job = Get-AzureRmAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
        if (!([string]::IsNullOrEmpty($Job)))
        {
            $AutomationInformation = @{}
            $AutomationInformation.Add("SubscriptionId",$Automation.SubscriptionId)
            $AutomationInformation.Add("Location",$Automation.Location)
            $AutomationInformation.Add("ResourceGroupName",$Job.ResourceGroupName)
            $AutomationInformation.Add("AutomationAccountName",$Job.AutomationAccountName)
            $AutomationInformation.Add("RunbookName",$Job.RunbookName)
            $AutomationInformation.Add("JobId",$Job.JobId.Guid)
            $AutomationInformation
            break;
        }
    }
}

# Import the runbook to process each VM into the service if it doesn't exist.
Function Import-Runbook($AccountInfo,$RunbookName, $RunbookContent)
{
    $StartRunbookById = Get-AzureRmAutomationRunbook -ResourceGroupName $AccountInfo.ResourceGroupName -AutomationAccountName $AccountInfo.AutomationAccountName -Name $RunbookName -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($StartRunbookById))
    {
        Set-Content -Path (Join-Path $env:TEMP "$RunbookName.ps1") -Value $RunbookContent -Force | Write-Verbose
        Import-AzureRmAutomationRunbook -Path (Join-Path $env:TEMP "$RunbookName.ps1") -Name $RunbookName `
                                            -ResourceGroupName $AccountInfo.ResourceGroupName -AutomationAccountName $AccountInfo.AutomationAccountName `
                                            -Type PowerShell -Published -Force | Write-Verbose
    }
}

# Start of main flow
try
    {
    # Authenticate to Azure
    $RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection"         

    Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $RunAsConnection.TenantId `
        -ApplicationId $RunAsConnection.ApplicationId `
        -CertificateThumbprint $RunAsConnection.CertificateThumbprint | Write-Verbose

    Select-AzureRmSubscription -SubscriptionId $RunAsConnection.SubscriptionID  | Write-Verbose 

    # Get Account information on where this job is running from
    $AccountInfo = WhoAmI

    # Import the runbook that will process work in parallel
    Import-Runbook -AccountInfo $AccountInfo -RunbookName $RunbookName -RunbookContent $ProcessRunbook

    # Get list of vms to process
    if  (!([string]::IsNullOrEmpty($VMResourceGroup)) -and !([string]::IsNullOrEmpty($VM)))
    {
        $AzureVMs = Get-AzureRMVM -ResourceGroupName $VMResourceGroup -Name $VM -Status | where {$_.Statuses.code -match "deallocated"}
    }
    elseif (!([string]::IsNullOrEmpty($VMResourceGroup)))
    {
        $AzureVMs = Get-AzureRMVM -ResourceGroupName $VMResourceGroup -Status | where {$_.PowerState -match "deallocated"}
    }
    else
    {
        $AzureVMs = Get-AzureRMVM -Status | where {$_.PowerState -match "deallocated"}
    }

    # Process the list of VMs using the automation service and collect jobs used
    $Jobs = @()

    foreach ($VM in $AzureVMs)
    {   
        # Start automation runbook to process VMs in parallel
        $RunbookNameParams = @{}
        $RunbookNameParams.Add("VM",$VM)
        # Loop here until a job was successfully submitted. Will stay in the loop until job has been submitted or an exception other than max allowed jobs is reached
        while ($true)
        {
            try 
            {
                $Job = Start-AzureRmAutomationRunbook -ResourceGroupName $AccountInfo.ResourceGroupName -AutomationAccountName $AccountInfo.AutomationAccountName -Name $RunbookName -Parameters $RunbookNameParams -ErrorAction Stop
                $Jobs+=$Job
                # Submitted job successfully, exiting while loop
                break
            }
            catch
            {
                # If we have reached the max allowed jobs, sleep backoff seconds and try again inside the while loop
                if ($_.Exception.Message -match "conflict")
                {
                    Write-Verbose ("Sleeping for 30 seconds as max allowed jobs has been reached. Will try again afterwards")
                    Sleep $BackOffInSeconds
                }
                else
                {
                    throw $_
                }
            }
        }
    }
 
    # Wait for jobs to complete, fail, or suspend (final states allowed for a runbook)
    $JobsResults = @()
    foreach ($RunningJob in $Jobs)
    {
        $ActiveJob = Get-AzureRMAutomationJob -ResourceGroupName $AccountInfo.ResourceGroupName -AutomationAccountName $AccountInfo.AutomationAccountName -Id $RunningJob.JobId
        While ($ActiveJob.Status -ne "Completed" -and $ActiveJob.Status -ne "Failed" -and $ActiveJob.Status -ne "Suspended")
        {
            Sleep 30
            $ActiveJob = Get-AzureRMAutomationJob -ResourceGroupName $AccountInfo.ResourceGroupName -AutomationAccountName $AccountInfo.AutomationAccountName -Id $RunningJob.JobId
        }
        $JobsResults+= $ActiveJob
    }


    # Print out results of the automation jobs
    foreach ($JobsResult in $JobsResults)
    {
        if ($JobsResult.Status -eq "Completed")
        {
            $Job = Get-AzureRmAutomationJobOutput  -ResourceGroupName $AccountInfo.ResourceGroupName -AutomationAccountName $AccountInfo.AutomationAccountName -Id $JobsResult.JobId -Stream Output
            foreach ($Stream in $Job)
            {
                (Get-AzureRmAutomationJobOutputRecord  -ResourceGroupName $AccountInfo.ResourceGroupName -AutomationAccountName $AccountInfo.AutomationAccountName -JobID $JobsResult.JobId -Id $Stream.StreamRecordId).Value
            }
        }
        else
        {
            $ErrorStreams = @()
            $ErrorStreams+= $JobsResult
            $Job = Get-AzureRmAutomationJobOutput  -ResourceGroupName $AccountInfo.ResourceGroupName -AutomationAccountName $AccountInfo.AutomationAccountName -Id $JobsResult.JobId -Stream Error
            foreach ($Stream in $Job)
            {
                $ErrorStreams+= (Get-AzureRmAutomationJobOutputRecord  -ResourceGroupName $AccountInfo.ResourceGroupName -AutomationAccountName $AccountInfo.AutomationAccountName -JobID $JobsResult.JobId -Id $Stream.StreamRecordId).Value
            }
            throw ($ErrorStreams.Exception)
        }
    }
}
Catch
{
    throw $_
}


