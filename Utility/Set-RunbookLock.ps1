
<#PSScriptInfo

.VERSION 1.1

.GUID 9e5dbf19-475a-425c-80d0-271240f8d235

.AUTHOR Azure-Automation-Team

.COMPANYNAME Microsoft

.COPYRIGHT 

.TAGS AzureAutomation OMS Utility

.LICENSEURI 

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/Utility/Set-RunbookLock.ps1

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES


#>

#Requires -Module Azure

<# 

.DESCRIPTION 
	This Azure Automation runbook ensures that only one instance of a PowerShell Workflow runbook is running at
    any one time by suspending and resuming jobs.  It is meant to be called from another runbook as an inline runbook, 
    not started asynchronously through the web service. 

#> 
Param()


<#
.SYNOPSIS
    Allows only one instance of a runbook job to run at any one time.

.DESCRIPTION
    This runbook ensures that only one instance of a runbook is running at
    any one time. It is meant to be called from another runbook as an inline runbook, 
    not started asynchronously through the web service.

.PARAMETER AutomationAccountName
    The name of the Automation account where this runbook is started from

.PARAMETER AzureOrgIdCredential
    A credential setting containing an Org Id username / password with access to this Azure subscription 

.PARAMETER SubscriptionName
    The name of the Azure subscription

.PARAMETER Lock
    A boolean value of true will make this job wait if another job is already running for this runbook.
	If set to false it unlocks the next job so it can run.

.EXAMPLE
    Set-RunbookLock -AutomationAccountName "FinanceTeam" -AzureOrgIdCredential 'AD-UserName' -Lock $True
 
    Set-RunbookLock -AutomationAccountName "FinanceTeam" -AzureOrgIdCredential 'AD-UserName' -Lock $True -SubscriptionName 'Visual Studio Ultimate with MSDN' 
	  
.NOTES
    AUTHOR: System Center Automation Team
    LASTEDIT: Dec 18, 2014 
#>
workflow Set-RunbookLock
{
    Param ( 
        [Parameter(Mandatory=$true)]
        [String] $AutomationAccountName,
        
        [Parameter(Mandatory=$true)]
        [String] $AzureOrgIdCredential,
        
        [Parameter(Mandatory=$true)]
        [Boolean] $Lock,

        [Parameter(Mandatory=$false)]
        [String] $SubscriptionName
    )

    $AzureCred = Get-AutomationPSCredential -Name $AzureOrgIdCredential
	if ($AzureCred -eq $null)
    {
        throw "Could not retrieve '$AzureOrgIdCredential' credential asset. Check that you created this first in the Automation service."
    }
    
    # Get the automation job id for this runbook job
    $AutomationJobID = $PSPrivateMetaData.JobId.Guid
             
    Add-AzureAccount -Credential $AzureCred | Write-Verbose 
    If ($SubscriptionName -ne $Null)
    {
       Select-AzureSubscription -SubscriptionName $SubscriptionName | Write-Verbose 
    }
               
    # Get the information for this job so we can retrieve the Runbook Id
    $CurrentJob = Get-AzureAutomationJob -AutomationAccountName $AutomationAccountName -Id $AutomationJobID
            
    
    if ($Lock)
    {

        $AllActiveJobs = Get-AzureAutomationJob -AutomationAccountName $AutomationAccountName `
                    -RunbookId $CurrentJob.RunbookId | Where -FilterScript {($_.Status -eq "Running") `
                                                            -or ($_.Status -eq "Starting") `
                                                            -or ($_.Status -eq "Queued")} 

        # Can't persist PS Credentials currently so setting to null
        $AzureCred = $null

        # If there are any active jobs for this runbook, suspend this job. If this is the only job
        # running then just continue
        If ($AllActiveJobs.Count -gt 1)
        {
            # In order to prevent a race condition (although still possible if two jobs were created at the 
            # exact same time), let this job continue if it is the oldest created running job
            $OldestJob = $AllActiveJobs | Sort-Object -Property CreationTime  | Select-Object -First 1
     
            # If this job is not the oldest created job we will suspend it and let the oldest one go through.
            # When the oldest job completes it will call Set-RunbookLock to make sure the next-oldest job for this runbook is resumed.
            if ($AutomationJobID -ne $OldestJob.ID)
            {
                Write-Verbose "Suspending runbook job as there are currently running jobs for this runbook already"
                Suspend-Workflow
                Write-Verbose "Job is resumed"
            }   
        }

    }   
    Else
    {
            # Get the next oldest suspended job if there is one for this Runbook Id
            $OldestSuspendedJob = Get-AzureAutomationJob -AutomationAccountName $AutomationAccountName `
            -RunbookId $CurrentJob.RunbookId | Where -FilterScript {$_.Status -eq "Suspended"} | Sort-Object -Property CreationTime  | Select-Object -First 1   
           
            if ($OldestSuspendedJob)
            {
                Write-Verbose ("Resuming the next suspended job: " + $OldestSuspendedJob.Id)
                Resume-AzureAutomationJob -AutomationAccountName $AutomationAccountName -Id $OldestSuspendedJob.Id | Write-Verbose 
            }
     }
}