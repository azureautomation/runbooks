
<#PSScriptInfo

.VERSION 1.0

.GUID 1a505183-5f4e-4de2-964e-c6514c351841

.AUTHOR Azure-Automation-Team

.COMPANYNAME Microsoft

.COPYRIGHT 

.TAGS AzureAutomation OMS Utility

.LICENSEURI 

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/Utility/Manage-MonitorRunbook.ps1

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES


#>

#Requires -Module Azure

<# 

.DESCRIPTION 
    This Azure Automation runbook is designed to run on scheduled intervals and resume any monitor runbooks
    that have a specific tag that are suspended 

#> 
Param()


<#
.SYNOPSIS 
    Utility runbook to control monitor runbooks to run at specific intervals

.DESCRIPTION
    This runbook is designed to run on scheduled intervals and resume any monitor runbooks
    that have a specific tag that are suspended

.PARAMETER AccountName
    Name of the Azure automation account name
    
.PARAMETER AzureCredentialSetting
    A credential asset name containing an Org Id username / password with access to this Azure subscription.

.PARAMETER Tag
    Value of the tag for monitor runbooks in the service that should be resumed. Only this specific tag should be set on monitor runbooks
	to avoid other runbooks from getting resumed if they are suspended. 
    
.PARAMETER SubscriptionName
    The name of the Azure subscription. This is an optional parameter as the default subscription will be used if not supplied.

.EXAMPLE
    Manage-MonitorRunbook -AccountName "Finance" -AzureCredentialSetting 'FinanceOrgID' -Tag "Monitor" -SubscriptionName "Visual Studio Ultimate with MSDN"

#>
workflow Manage-MonitorRunbook
{
    Param ( 
        [Parameter(Mandatory=$true)]
        [String] $AccountName,
        
        [Parameter(Mandatory=$true)]
        [String] $AzureCredentialSetting,
        
        [Parameter(Mandatory=$true)]
        [String] $Tag,
        
        [Parameter(Mandatory=$false)]
        [String] $SubscriptionName
    )
    
    $AzureCred = Get-AutomationPSCredential -Name $AzureCredentialSetting
    if ($AzureCred -eq $null)
    {
        throw "Could not retrieve '$AzureCredentialSetting' credential asset. Check that you created this first in the Automation service."
    }

    # Set the Azure subscription to use
    Add-AzureAccount -Credential $AzureCred | Write-Verbose
    
    # Select the specific subscription if it was passed in, otherwise the default will be used  
    if ($SubscriptionName -ne $Null)
    {
      Select-AzureSubscription -SubscriptionName $SubscriptionName | Write-Verbose 
    }
   
    # Get the list of runbooks that have the specified tag
    $MonitorRunbooks = Get-AzureAutomationRunbook -AutomationAccountName $AccountName | where -FilterScript {$_.Tags -match $Tag}
    
    foreach ($Runbook in $MonitorRunbooks)
    {
        Write-Verbose ("Checking " + $Runbook.Name + " for suspended jobs to resume")
        # Get the next suspended job if there is one for this Runbook Id
        $SuspendedJobs = Get-AzureAutomationJob -AutomationAccountName $AccountName `
						-RunbookName $Runbook.Name | Where -FilterScript {$_.Status -eq "Suspended"}
        
       if ($SuspendedJobs.Count -gt 1)
        {
            Write-Error ("There are multiple jobs for " + $Runbook.Name + " running. This shouldn't happen for monitor runbooks")
            # Select the oldest job and resume that one
            $SuspendedJobs = $SuspendedJobs | Sort-Object -Property CreationTime  | Select-Object -First 1
        }
        
        if ($SuspendedJobs)
        {    
			Write-Verbose ("Resuming the next suspended job: " + $SuspendedJobs.Id)
            Resume-AzureAutomationJob -AutomationAccountName $AccountName -Id $SuspendedJobs.Id   
        }
    }
}