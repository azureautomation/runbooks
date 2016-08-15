<#PSScriptInfo

.VERSION 1.01

.GUID 803969d1-8f13-482b-8345-6b5b503dff25

.AUTHOR AzureAutomationTeam

.COMPANYNAME Microsoft

.COPYRIGHT 

.TAGS AzureAutomation OMS VirtualMachines Utility 

.LICENSEURI 

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Copy-ItemFromAzureRmVM.ps1 

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS Connect-AzureVM

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES


#>

#Requires -Module AzureRM.Profile
#Requires -Module AzureRm.Compute
#Requires -Module AzureRm.Network
#Requires -Module Azure.Storage
#Requires -Module AzureRm.Storage
#Requires -Module AzureRm.Resources

<#
.SYNOPSIS 
    Copies a file from an Azure ARM VM to the Azure Automation host.  
    

.DESCRIPTION
    This runbook copies a remote file from a Windows Azure virtual machine and targets an ARM (Azure v2) VM to the Azure 
	Automation host. 
    Connect-AzureVM script must be imported and published in order for this runbook to work. The Connect-AzureVM
	runbook sets up the connection to the virtual machine where the remote file is copied from.  

	When using this runbook, be aware that the memory and disk space size of the processes running your
	runbooks is limited. Because of this, we recommened only using runbooks to transfer small files. 
	All Automation Integration Module assets in your account are loaded into your processes,
	so be aware that the more Integration Modules you have in your system, the smaller the free space in
	your processes will be. To ensure maximum disk space in your processes, make sure to clean up any local
	files a runbook transfers or creates in the process before the runbook completes.

    Use https://gallery.technet.microsoft.com/scriptcenter/Copy-and-Item-from-an-c283405d for ASM VMs (Classic VMs). 

.PARAMETER ServicePrincipalConnectionName
    The name of the service principal connection object.  For more detail see:  
    https://azure.microsoft.com/en-us/documentation/articles/automation-sec-configure-azure-runas-account/  

.PARAMETER ResourceGroupName
    Name of the Resource Group where the VM is located.

.PARAMETER VMName    
    Name of the virtual machine that you want to connect to.  

.PARAMETER VMCredentialName
    Name of a PowerShell credential asset that is stored in the Automation service.
    This credential should contain a username and password with access to the virtual machine.
 
.PARAMETER LocalPath
    The local path where the item should be copied to.  This path is on the Auotmation host. 

.PARAMETER RemotePath
    The remote path to the item to copy.  This path is on the Virtual Machine.  

.EXAMPLE
    Copy-ItemFromAzureRmVM  -ResourceGroup "myResourceGroup" -VMName "myVM" -VMCredentialName "myVMCred" -LocalPath ".\myFileCopy.txt" -RemotePath "C:\Users\username\myFile.txt"


.NOTES
    AUTHOR: AzureAutomationTeam
    LASTEDIT: August 10, 2016 
#>

param(

    [parameter(Mandatory=$false)]
    [String]$ServicePrincipalConnectionName = "AzureRunAsConnection",
	
	[Parameter(Mandatory=$true)] 
	[String]$ResourceGroupName,
	
	[Parameter(Mandatory=$true)] 
	[String]$VMName,

	[Parameter(Mandatory=$true)] 
	[String]$VMCredentialName,
        
    [parameter(Mandatory=$true)]
    [String]
    $LocalPath,
        
    [parameter(Mandatory=$true)]
    [String]
    $RemotePath  	
)

$VMCredential =  Get-AutomationPSCredential -Name $VMCredentialName 

if ($VMCredential -eq $null)
{
    throw "Could not retrieve '$VMCredentialName' credential asset. Check that you created this asset in the Automation service."
}  
   
$IpAddress = .\Connect-AzureVM.ps1 -ServicePrincipalConnectionName $ServicePrincipalConnectionName -VMName $VMName  -ResourceGroupName $ResourceGroupName
if ($IpAddress -eq $null) 
{
    throw "IP address could not be found." 
}

Write-Verbose -Message "The IP Address is $IpAddress. Remoting to VM $VMName..."
    
#Retrieve the content from the VM    
$SessionOptions = New-PSSessionOption -SkipCACheck -SkipCNCheck                
$Content = Invoke-Command -ComputerName $IpAddress -Credential $VMCredential -UseSSL -SessionOption $SessionOptions -ArgumentList $RemotePath -ScriptBlock { 
    Get-Content –Path $args[0] –Encoding Byte
}

# Store the file contents locally. 
$Content | Set-Content –Path $LocalPath -Encoding Byte

# TODO: Insert your own code here to copy the file out of the Automation runbook host to the end destination


