
<#PSScriptInfo

.VERSION 1.01

.GUID 12473dcf-0dc2-4413-aaa9-d0c9eae642fa

.AUTHOR AzureAutomationTeam

.COMPANYNAME Microsoft Corporation

.COPYRIGHT 

.TAGS AzureAutomation OMS VirtualMachines Utility

.LICENSEURI 

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Copy-ItemToAzureVM.ps1

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
#Requires -Module AzureRm.Resources

<#
.SYNOPSIS 
    Copies a file to an Azure VM.

.DESCRIPTION
    This runbook copies a local file to an ARM virtual machine.
    Connect-AzureVM must be imported and published in order for this runbook to work. The Connect-AzureVM
	runbook sets up the connection to the virtual machine where the local file will be copied to.  

	When using this runbook, be aware that the memory and disk space size of the processes running your
	runbooks is limited. Because of this, we recommened only using runbooks to transfer small files.
	All Automation Integration Module assets in your account are loaded into your processes,
	so be aware that the more Integration Modules you have in your system, the smaller the free space in
	your processes will be. To ensure maximum disk space in your processes, make sure to clean up any local
	files a runbook transfers or creates in the process before the runbook completes.

.PARAMETER ServicePrincipalConnectionName
    The name of the service principal connection object.  For more detail see:  
    https://azure.microsoft.com/en-us/documentation/articles/automation-sec-configure-azure-runas-account/  

.PARAMETER ResourceGroupName
    Name of the Resource Group where the VM is located.

.PARAMETER VMName    
    Name of the virtual machine that you want to connect to.  

.PARAMETER VMCredentialName
    Name of a PowerShell credential asset that is stored in the Automation service.
    This credential should have access to the virtual machine.
 
.PARAMETER LocalPath
    The local path to the item to copy to the Azure virtual machine.

.PARAMETER RemotePath
    The remote path on the Azure virtual machine where the item should be copied to.

.EXAMPLE
    Copy-ItemToAzureVM -ResourceGroupName "myRG" -VMName "myVM" -VMCredentialName "myVMCred" -LocalPath ".\myFile.txt" -RemotePath "C:\Users\username\myFileCopy.txt" 

.NOTES
    AUTHOR: System Center Automation Team
    LASTEDIT: Aug 11, 2016  
#>
param
(
    [parameter(Mandatory=$false)]
    [String]$ServicePrincipalConnectionName = "AzureRunAsConnection",
	
	[Parameter(Mandatory=$true)] 
	[String]$ResourceGroupName,
        
    [parameter(Mandatory=$true)]
    [String]
    $VMName,  
        
    [parameter(Mandatory=$true)]
    [String]
    $VMCredentialName,
        
    [parameter(Mandatory=$true)]
    [String]
    $LocalPath,
        
    [parameter(Mandatory=$true)]
    [String]
    $RemotePath  
)

# Get credentials to Azure VM
$Credential = Get-AutomationPSCredential -Name $VMCredentialName    

if ($Credential -eq $null)
{
    throw "Could not retrieve '$VMCredentialName' credential asset. Check that you created this asset in the Automation service."
}     
    
# Set up the Azure VM connection by calling the Connect-AzureVM runbook. You should call this runbook after
# every CheckPoint-WorkFlow in your runbook to ensure that the connection to the Azure VM is restablished if this runbook
# gets interrupted and starts from the last checkpoint.
$IpAddress = .\Connect-AzureVM.ps1 -ServicePrincipalConnectionName $ServicePrincipalConnectionName -VMName $VMName  -ResourceGroupName $ResourceGroupName
if ($IpAddress -eq $null) 
{
    throw "IP address could not be found." 
}

# Store the file contents on the Azure VM
$ConfigurationName = "HighDataLimits"

$SessionOptions = New-PSSessionOption -SkipCACheck -SkipCNCheck    

# Enable larger data to be sent
Invoke-Command -ScriptBlock {
    $ConfigurationName = $args[0]
    $Session = Get-PSSessionConfiguration -Name $ConfigurationName
            
    if(!$Session) {
        Write-Verbose "Large data sending is not allowed. Creating PSSessionConfiguration $ConfigurationName"

        Register-PSSessionConfiguration -Name $ConfigurationName -MaximumReceivedDataSizePerCommandMB 500 -MaximumReceivedObjectSizeMB 500 -Force | Out-Null
    }
} -ArgumentList $ConfigurationName -ComputerName $IpAddress -Credential $Credential -UseSSL -SessionOption $SessionOptions -ErrorAction SilentlyContinue     
        
# Get the file contents locally
$Content = Get-Content –Path $LocalPath –Encoding Byte

Write-Verbose ("Retrieved local content from $LocalPath")
        
Invoke-Command -ScriptBlock {

    param($Content, $RemotePath)			
	$Content | Set-Content –Path $RemotePath -Encoding Byte

} -ArgumentList $Content, $RemotePath -ComputerName $IpAddress -Credential $Credential -UseSSL -SessionOption $SessionOptions -ConfigurationName $ConfigurationName

Write-Verbose ("Wrote content from $LocalPath to $VMName at $RemotePath")
