<#PSScriptInfo

.VERSION 1.0

.GUID 6f24a778-a8f8-43ff-9b74-721bc21bf571

.AUTHOR AzureAutomationTeam

.COMPANYNAME Microsoft

.COPYRIGHT 

.TAGS AzureAutomation OMS VirtualMachines Utility

.LICENSEURI 

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/Utility/Stop-AzureV2VMs.ps1

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES

#>

#Requires -Module AzureRM.Profile
#Requires -Module AzureRM.Compute

<#
.SYNOPSIS
  Connects to Azure and stops of all VMs in the specified Azure subscription or resource group

.DESCRIPTION
  This runbook connects to Azure and stops all VMs in an Azure subscription or resource group.  
  You can attach a schedule to this runbook to run it at a specific time. Note that this runbook does not stop
  Azure classic VMs. Use https://gallery.technet.microsoft.com/scriptcenter/Stop-Azure-Classic-VMs-7a4ae43e for that.

.PARAMETER AzureConnectionAssetName
   Optional with default of "AzureRunAsConnection".
   The name of an Automation connection asset that contains an Azure AD service principal with authorization for the subscription
   you want to stop VMs in. To use an asset with a different name you can pass the asset name as a runbook input parameter or change
   the default value for this input parameter.

   If you selected "Create Azure Run As Account" when creating the automation account running this runbook, you will already
   have a connection asset with the default name ("AzureRunAsConnection") set up. If not, you can create a connection asset / Azure AD
   service principal by following the directions here: https://azure.microsoft.com/en-us/documentation/articles/automation-sec-configure-azure-runas-account

.PARAMETER ResourceGroupName
   Optional
   Allows you to specify the resource group containing the VMs to stop.  
   If this parameter is included, only VMs in the specified resource group will be stopped, otherwise all VMs in the subscription will be stopped.  

.NOTES
   AUTHOR: Azure Automation Team 
   LASTEDIT: April 2, 2016
#>

# Returns strings with status messages
[OutputType([String])]

param (
    [Parameter(Mandatory=$false)] 
    [String]  $AzureConnectionAssetName = "AzureRunAsConnection",

    [Parameter(Mandatory=$false)] 
    [String] $ResourceGroupName
)

try {
    # Connect to Azure using service principal auth
    $ServicePrincipalConnection = Get-AutomationConnection -Name $AzureConnectionAssetName         

    Write-Output "Logging in to Azure..."

    $Null = Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $ServicePrincipalConnection.TenantId `
        -ApplicationId $ServicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint 
}
catch {
    if(!$ServicePrincipalConnection) {
        throw "Connection $AzureConnectionAssetName not found."
    }
    else {
        throw $_.Exception
    }
}

# If there is a specific resource group, then get all VMs in the resource group,
# otherwise get all VMs in the subscription.
if ($ResourceGroupName) { 
	$VMs = Get-AzureRmVM -ResourceGroupName $ResourceGroupName
}
else { 
	$VMs = Get-AzureRmVM
}

# Stop each of the VMs
foreach ($VM in $VMs) {
	$StopRtn = $VM | Stop-AzureRmVM -Force -ErrorAction Continue

	if ($StopRtn.Status -ne "Succeeded") {
		# The VM failed to stop, so send notice
        Write-Output ($VM.Name + " failed to stop")
        Write-Error ($VM.Name + " failed to stop. Error was:") -ErrorAction Continue
		Write-Error (ConvertTo-Json $StopRtn) -ErrorAction Continue
	}
	else {
		# The VM stopped, so send notice
		Write-Output ($VM.Name + " has been stopped")
	}
}
