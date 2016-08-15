
<#PSScriptInfo

.VERSION 1.2

.GUID 9e5dbf19-475a-425c-80d0-271240f8d235

.AUTHOR AzureAutomationTeam

.COMPANYNAME Microsoft

.COPYRIGHT 

.TAGS AzureAutomation OMS Utility

.LICENSEURI 

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Set-RunbookLock.ps1

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES


#>

#Requires -Module AzureRm.Profile
#Requires -Module AzureRm.Automation


<#
.SYNOPSIS
    Allows only one instance of a runbook job to run at any one time.

.DESCRIPTION
    This runbook ensures that only one instance of a runbook is running at
    any one time. It is meant to be called from another runbook as an inline runbook, 
    not started asynchronously through the web service.

.PARAMETER AutomationAccountName
    The name of the Automation account where this runbook is started from


.PARAMETER ResourceGroupName
    The name of the resource group the Automation account is located in

.PARAMETER ServicePrincipalConnectionName
    A connection asset containing the information for the Run As Account.  To learn more about run as accounts see http://aka.ms/runasaccount.

.PARAMETER Lock
    A boolean value of true will make this job wait if another job is already running for this runbook.
	If set to false it unlocks the next job so it can run.

.EXAMPLE
    Set-RunbookLock -AutomationAccountName "FinanceTeam"  -Lock $True -ResourceGroupName "FinanceResourceGroup" 
 
	  
.NOTES
    AUTHOR: System Center Automation Team
    LASTEDIT: August 12, 2016 
#>
workflow Set-RunbookLock
{
    Param ( 
        [Parameter(Mandatory=$true)]
        [String] $AutomationAccountName,
        
        [Parameter(Mandatory=$false)]
        [String] $ServicePrincipalConnectionName = 'AzureRunAsConnection',
        
        [Parameter(Mandatory=$true)]
        [Boolean] $Lock,

        [Parameter(Mandatory=$true)]
        [String] $ResourceGroupName
    )

    $ServicePrincipalConnection = Get-AutomationConnection -Name $ServicePrincipalConnectionName   
    if (!$ServicePrincipalConnection) 
    {
        $ErrorString = 
@"
        Service principal connection $ServicePrincipalConnectionName not found.  Make sure you have created it in Assets. 
        See http://aka.ms/runasaccount to learn more about creating Run As accounts. 
"@
        throw $ErrorString
    }  	
    
    # Get the automation job id for this runbook job
    $AutomationJobID = $PSPrivateMetaData.JobId.Guid
             
    Add-AzureRmAccount `
            -ServicePrincipal `
            -TenantId $ServicePrincipalConnection.TenantId `
            -ApplicationId $ServicePrincipalConnection.ApplicationId `
            -CertificateThumbprint $ServicePrincipalConnection.Certificate | Write-Verbose

               
    # Get the information for this job so we can retrieve the Runbook Id
    $CurrentJob = Get-AzureRmAutomationJob -AutomationAccountName $AutomationAccountName -Id $AutomationJobID -ResourceGroupName $ResourceGroupName
            
    
    if ($Lock)
    {

        $AllActiveJobs = Get-AzureRmAutomationJob -AutomationAccountName $AutomationAccountName `
                    -ResourceGroupName $ResourceGroupName `
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
            $OldestSuspendedJob = Get-AzureRmAutomationJob -AutomationAccountName $AutomationAccountName `
            -ResourceGroupName $ResourceGroupName `
            -RunbookId $CurrentJob.RunbookId | Where -FilterScript {$_.Status -eq "Suspended"} | Sort-Object -Property CreationTime  | Select-Object -First 1   
           
            if ($OldestSuspendedJob)
            {
                Write-Verbose ("Resuming the next suspended job: " + $OldestSuspendedJob.Id)
                Resume-AzureRmAutomationJob -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Id $OldestSuspendedJob.Id | Write-Verbose 
            }
     }
}