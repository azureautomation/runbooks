<#
.SYNOPSIS 
    This automation runbook stops all Azure virtual machines that are running in a subscription

.DESCRIPTION
    This automation runbook stops all Azure virtual machines that are running in a subscription. It will
    process all VMs in parallel by creating a runbook in the automation service that stops a single virtual
    machine and then calls this runbook from this parent runboook. This runbook is designed to be run from
    the Azure automation service.

.PARAMETER VMResourceGroup
    Optional. The name of the resource group the VMs are contained in. If not specified, all VMs in the subscription are stopped.

.PARAMETER VM
    Optional. The name of the VM. If not specified, all VMs in the resource group are stopped.

.PARAMETER MaxAutomationJobs
    Optional. This represents the number of automation jobs to shut down virtual machines in parallel. The automation service
    currently has a limit of 200 concurrent running jobs per account and the default for this runbook is set to 190.

.EXAMPLE
    Stop-AzureRMARMVMInParallel -VMResourceGroup Contoso -VM Marketing1

.EXAMPLE
    Stop-AzureRMARMVMInParallel -VMResourceGroup Contoso 

.EXAMPLE
    Stop-AzureRMARMVMInParallel

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: April 30th, 2017 
#>
Param
(
    [Parameter(Mandatory=$false)]
    $VMResourceGroup,

    [Parameter(Mandatory=$false)]
    $VM,

    [Parameter(Mandatory=$false)]
    $MaxAutomationJobs = 190
) 

# This is the runbook that will process work in parallel in the automation service.
$RunbookName = "Process-ParallelRunbook"
$ProcessRunbook = @'
param (
[Parameter(Mandatory=$true)]
$VM
)
$ErrorActionPreference = 'stop'

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

Stop-AzureRMVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Force | Write-Verbose
Get-AzureRMVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Status | Select Name -ExpandProperty Statuses

'@

# Function to return the Automation account information that this job is running in.
Function WhoAmI
{
    $AutomationResource = Find-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts

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
    $StopRunbookById = Get-AzureRmAutomationRunbook -ResourceGroupName $AccountInfo.ResourceGroupName -AutomationAccountName $AccountInfo.AutomationAccountName -Name $RunbookName -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($StopRunbookById))
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
        $AzureVMs = Get-AzureRMVM -ResourceGroupName $VMResourceGroup -Name $VM
    }
    elseif (!([string]::IsNullOrEmpty($VMResourceGroup)))
    {
        $AzureVMs = Get-AzureRMVM -ResourceGroupName $VMResourceGroup
    }
    else
    {
        $AzureVMs = Get-AzureRMVM
    }

    # Process the list of VMs using the automation service and collect jobs used
    $Jobs = @()
    foreach ($VM in $AzureVMs)
    {
        # Get all active jobs for this account
        $AllActiveJobs = Get-AzureRMAutomationJob -ResourceGroupName $AccountInfo.ResourceGroupName -AutomationAccountName $AccountInfo.AutomationAccountName `
                        | Where {($_.Status -eq "Running")  `
                    -or ($_.Status -eq "Starting") `
                    -or ($_.Status -eq "New")}  

        While ($AllActiveJobs.Count -ge $MaxAutomationJobs)
        {
            Write-Verbose "Waiting as there are currently greater than $NoOfInstances jobs. Sleeping 30 seconds..."
            Sleep 30
            $AllActiveJobs = Get-AzureRMAutomationJob -ResourceGroupName $AccountInfo.ResourceGroupName -AutomationAccountName $AccountInfo.AutomationAccountName `
                         | Where {($_.Status -eq "Running") `
                        -or ($_.Status -eq "Starting") `
                        -or ($_.Status -eq "New")}
                  
            Write-Verbose ("Number of current jobs running is " + $AllActiveJobs.Count)
        } 

        # Process VMs that are started
        $VMStatus = Get-AzureRMVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Status
        if ($VMStatus.Statuses[1].Code -eq "PowerState/running")
        {
            $RunbookNameParams = @{}
            $RunbookNameParams.Add("VM",$VM)
            $Job = Start-AzureRmAutomationRunbook -ResourceGroupName $AccountInfo.ResourceGroupName -AutomationAccountName $AccountInfo.AutomationAccountName -Name $RunbookName -Parameters $RunbookNameParams
            $Jobs+=$Job
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




