<#
.SYNOPSIS 
    This automation runbook starts all Azure virtual machines that are running in a subscription, resource group or single VM.
    If a tag is added to the VM, then only those VMs will be started if the TagName parameter is passed in.

.DESCRIPTION
    This automation runbook starts all Azure virtual machines that are running in a subscription, resource group or single VM.
    If a tag is added to the VM, then only those VMs will be started if the TagName parameter is passed in.
    This runbook is designed to be run from the Azure automation service.

.PARAMETER VMResourceGroup
    Optional. The name of the resource group the VMs are contained in. If not specified, all VMs in the subscription are started.

.PARAMETER VM
    Optional. The name of the VM. If not specified, all VMs in the resource group are started.

.PARAMETER TagName
    Optional. The name of the Tag to look for. If specified, only VMs with this tag will be started.

.EXAMPLE
    Start-AzureVM -VMResourceGroup Contoso -VM Marketing

.EXAMPLE
    Start-AzureVM -VMResourceGroup Contoso -TagName "DevMachines"

.EXAMPLE
    Start-AzureVM

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: June 12th, 2018
#>
Param
(
    [Parameter(Mandatory=$false)]
    $VMResourceGroupName,

    [Parameter(Mandatory=$false)]
    $VMName,

    [Parameter(Mandatory=$false)]
    $TagName = $null
) 
$RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection"

Add-AzureRmAccount `
    -ServicePrincipal `
    -TenantId $RunAsConnection.TenantId `
    -ApplicationId $RunAsConnection.ApplicationId `
    -CertificateThumbprint $RunAsConnection.CertificateThumbprint | Write-Verbose

# Set subscription to work against
$SubscriptionContext = Set-AzureRmContext -SubscriptionId $RunAsConnection.SubscriptionId 

# Script block to start a VM
$StartVMScriptBlock = {
    Param($VMResourceGroupName, $VMName) 
    Write-Output ("Starting VM " + $VMName + " in resource group " + $VMResourceGroupName)
    Start-AzureRmVM -ResourceGroupName $VMResourceGroupName -Name $VMName | Write-Verbose
}

$MAX_JOBS = 50
$VMJobs = @()

# Check for VM without resource group specified
if  ($VMName -ne $null -and $VMResourceGroupName -eq $null)
{
    throw "Resource group must not be empty if a VM is specified"
}

# Get all the VMs in the subscription
if  ($VMResourceGroupName -ne $null -and $VMName -ne $null)
{
    $VMs = Get-AzureRMVM -ResourceGroupName $VMResourceGroupName -Name $VMName
}
elseif ($VMResourceGroupName -ne $null)
{
    $VMs = Get-AzureRMVM -ResourceGroupName $VMResourceGroupName
}
else
{
    $VMs = Get-AzureRMVM
}

# Check if VM has the specified tag on it and filter to those.
If ($TagName -ne $null)
{
    $VMs = $VMs | Where-Object {$_.Tags.Keys -eq $TagName}
}

# Start a thread job for each VM
foreach ($VirtualMachine in $VMs)
{
    $VM = Get-AzureRmVM -ResourceGroupName $VirtualMachine.ResourceGroupName -Name $VirtualMachine.Name -Status
    if ($VM.Statuses.Code[1] -eq 'PowerState/deallocated')
    {
        # Process up to MAX_JOBS at a time so as to not overwhelm the host
        $VMJob = Start-ThreadJob -ScriptBlock $StartVMScriptBlock -ArgumentList $VM.ResourceGroupName, $VM.Name -ThrottleLimit $MAX_JOBS
        $VMJobs+=$VMJob
    }
}

# Write out the job status
foreach ($Job in $VMJobs)
{
        Wait-Job -id $Job.Id | Write-Verbose
        if ($Job.Error.Count -gt 0)
        {
            Write-Error -Message $Job.Error.Exception
        }
        else 
        {
            Write-Output $Job.Output[0]
        }
}

