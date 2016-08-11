<#
.SYNOPSIS 
    Copies a file from an Azure VM. 

.DESCRIPTION
    This runbook copies a remote file from a Windows Azure virtual machine.
    Connect-AzureVM must be imported and published in order for this runbook to work. The Connect-AzureVM
	runbook sets up the connection to the virtual machine where the remote file is copied from.  

	When using this runbook, be aware that the memory and disk space size of the processes running your
	runbooks is limited. Because of this, we recommened only using runbooks to transfer small files. 
	All Automation Integration Module assets in your account are loaded into your processes,
	so be aware that the more Integration Modules you have in your system, the smaller the free space in
	your processes will be. To ensure maximum disk space in your processes, make sure to clean up any local
	files a runbook transfers or creates in the process before the runbook completes.

.PARAMETER AzureSubscriptionName
    Name of the Azure subscription to connect to
    
.PARAMETER AzureOrgIdCredential
    A credential containing an Org Id username / password with access to this Azure subscription.

	If invoking this runbook inline from within another runbook, pass a PSCredential for this parameter.

	If starting this runbook using Start-AzureAutomationRunbook, or via the Azure portal UI, pass as a string the
	name of an Azure Automation PSCredential asset instead. Azure Automation will automatically grab the asset with
	that name and pass it into the runbook.
    
.PARAMETER ServiceName
    Name of the cloud service where the VM is located.

.PARAMETER VMName    
    Name of the virtual machine that you want to connect to.  

.PARAMETER VMCredentialName
    Name of a PowerShell credential asset that is stored in the Automation service.
    This credential should contain a username and password with access to the virtual machine.
 
.PARAMETER LocalPath
    The local path where the item should be copied to.

.PARAMETER RemotePath
    The remote path to the item to copy to the local machine.

.EXAMPLE
    Copy-ItemFromAzureVM -AzureSubscriptionName "Visual Studio Ultimate with MSDN" -ServiceName "myService" -VMName "myVM" -VMCredentialName "myVMCred" -LocalPath ".\myFileCopy.txt" -RemotePath "C:\Users\username\myFile.txt" -AzureOrgIdCredential $cred

.NOTES
    AUTHOR: System Center Automation Team
    LASTEDIT: Aug 14, 2014 
#>
workflow Copy-ItemFromAzureVM {
    param
    (
        [parameter(Mandatory=$true)]
        [String]
        $AzureSubscriptionName,

		[parameter(Mandatory=$true)]
        [PSCredential]
        $AzureOrgIdCredential,
        
        [parameter(Mandatory=$true)]
        [String]
        $ServiceName,
        
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
    $Uri = Connect-AzureVM -AzureSubscriptionName $AzureSubscriptionName -AzureOrgIdCredential $AzureOrgIdCredential –ServiceName $ServiceName –VMName $VMName

    # Get the file contents from the Azure VM
    $Content = Inlinescript {
        Invoke-Command -ScriptBlock {
            Get-Content –Path $args[0] –Encoding Byte
        } -ArgumentList $using:RemotePath -ConnectionUri $using:Uri -Credential $using:Credential
    }

    # Store the file contents locally
    $Content | Set-Content –Path $LocalPath -Encoding Byte
}
