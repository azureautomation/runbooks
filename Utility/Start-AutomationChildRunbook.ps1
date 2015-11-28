
<#PSScriptInfo

.VERSION 1.0

.GUID a119dd78-7857-4c5d-9f53-3beb7a61a5f5

.AUTHOR elcooper_msft

.COMPANYNAME 

.COPYRIGHT 

.TAGS AzureAutomation OMS Utility

.LICENSEURI 

.PROJECTURI 

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES


#>

#Requires -Module Azure

<# 

.DESCRIPTION 
	This runbook starts an Azure Automation runbook job and either returns the job id or waits for the job
    to complete and returns the job output. 
#> 
Param()


<#
.SYNOPSIS 
     Starts an Azure Automation runbook job and either returns the job id or waits for the job
     to complete and returns the job output

.DESCRIPTION
    This runbook starts a child runbook when called from a parent runbook.

    Requirements:
       1. Azure Org Id credential asset in the Automation account of this runbook 
          (see http://aka.ms/runbookauthor/authentication for information)

.PARAMETER ChildRunbookName
    The name of the runbook to start.

.PARAMETER ChildRunbookInputParams
    A hashtable whose keys are names of parameters for the child runbook, with corresponding values.

.PARAMETER AzureOrgIdCredential
    A credential containing an Org Id username / password with access to this Azure subscription.
	If invoking this runbook inline from within another runbook, pass a PSCredential for this parameter.
	If starting this runbook using Start-AzureAutomationRunbook, or via the Azure portal UI, pass as a 
    string the name of an Azure Automation PSCredential asset instead. Azure Automation will automatically 
    grab the asset with	that name and pass it into the runbook.
    
.PARAMETER AzureSubscriptionName
    The name of the Azure subscription to connect to.

.PARAMETER AutomationAccountName
    The name of the Azure Automation account that the runbook to start exists in.

.PARAMETER WaitForJobCompletion
    Boolean value.  If true, wait for the runbook job to finish.  If false, don't wait
    and return the job id.  Default is false.

.PARAMETER ReturnJobOutput
    Boolean value.  If true, the runbook job output is returned as a string.  Both this parameter
    and WaitForJobCompletion must be true to get job output.  Default is false.

.PARAMETER JobPollingIntervalInSeconds
    An integer that sets the time in seconds to wait between each poll of the child job to 
    determine if the job has finished.  Default is 10 seconds.  This is used only when 
    WaitForJobCompletion is true.

.PARAMETER JobPollingTimeoutInSeconds
    An integer that sets the maximum time in seconds to poll the child job.  
    If this time limit is exceeded, a timeout exception will be thrown.
    Default is 600 seconds (10 minutes).  This is used only when WaitForJobCompletion is true.

.EXAMPLE
    Start-AutomationChildRunbook `
        -ChildRunbookName "Update-VM" `
        -ChildRunbookInputParams @{'VMName'='VM204';'Retries'=3} `
        -AzureOrgIdCredential $cred
        -AzureSubscriptionName "Visual Studio Ultimate with MSDN"
        -AutomationAccountName "Contoso IT Automation Production" `
        -WaitForJobCompletion $true `
        -ReturnJobOutput $true `
        -JobPollingIntervalInSeconds 20 `
        -JobPollingTimeoutInSeconds 120

.NOTES
    AUTHOR: System Center Automation Team
    LASTEDIT: January 9, 2015
    CHANGES:
        January 9, 2015 - Use Azure Org Id credential to authenticate (rather than Azure certificate)
#>

workflow Start-AutomationChildRunbook
{
    [OutputType([object])]
    
    param (
        [Parameter(Mandatory=$true)]
        [string] 
        $ChildRunbookName,
        
        [Parameter(Mandatory=$false)]
        [hashtable] 
        $ChildRunbookInputParams,
        
   		[parameter(Mandatory=$true)]
        [PSCredential]
        $AzureOrgIdCredential,
        
        [Parameter(Mandatory=$true)]
        [string] 
        $AzureSubscriptionName,

        [Parameter(Mandatory=$true)]
        [string] 
        $AutomationAccountName,
        
        [Parameter(Mandatory=$false)]
        [boolean] 
        $WaitForJobCompletion = $false,
        
        [Parameter(Mandatory=$false)]
        [boolean] 
        $ReturnJobOutput = $false,
        
        [Parameter(Mandatory=$false)]
        [int] 
        $JobPollingIntervalInSeconds = 10,
        
        [Parameter(Mandatory=$false)]
        [int] 
        $JobPollingTimeoutInSeconds = 600
    )

   # Determine if parameter values are incompatible
   if(!$WaitForJobCompletion -and $ReturnJobOutput) {
       $msg = "The parameters WaitForJobCompletion and ReturnJobOutput must both "
       $msg += "be true if you want job output returned."
       throw ($msg)
   }
   
    # Connect to Azure so that this runbook can call the Azure cmdlets
    Add-AzureAccount -Credential $AzureOrgIdCredential | Write-Verbose

    # Select the Azure subscription we will be working against
    Select-AzureSubscription -SubscriptionName $AzureSubscriptionName | Write-Verbose

    # Assure not null for this param
    if ($ChildRunbookInputParams -eq $null) { $ChildRunbookInputParams = @{} }

    # Start the child runbook and get the job returned
    $job = Start-AzureAutomationRunbook `
                -Name $ChildRunbookName `
                -Parameters $ChildRunbookInputParams `
                -AutomationAccountName $AutomationAccountName `
                -ErrorAction "Stop"
    
    # Determine if there is a job and if the job output is wanted or not
    if ($job -eq $null) {
        # No job was created, so throw an exception
        throw ("No job was created for runbook: $ChildRunbookName.")
    }
    else {
        # There is a job
        
        # Log the started runbook’s job id for tracking
        Write-Verbose "Started runbook: $ChildRunbookName. Job Id: $job.Id"
        
        if (-not $WaitForJobCompletion) {
            # Don't wait for the job to finish, just return the job id
            Write-Output $job.Id
        }
        else {
            # Monitor the job until finish or timeout limit has been reached
            $maxDateTimeout = InlineScript{(Get-Date).AddSeconds($using:JobPollingTimeoutInSeconds)}
            
            $doLoop = $true
            
            while($doLoop) {
                Start-Sleep -s $JobPollingIntervalInSeconds
                
                $job = Get-AzureAutomationJob `
                    -Id $job.Id `
                    -AutomationAccountName $AutomationAccountName
                
                if ($maxDateTimeout -lt (Get-Date)) {
                    # timeout limit reached so exception
                    $msg = "The job for runbook $ChildRunbookName did not "
                    $msg += "complete within the timeout limit of "
                    $msg += "$JobPollingTimeoutInSeconds seconds, so polling "
                    $msg += "for job completion was halted. The job will "
                    $msg += "continue running, but no job output will be returned."
                    throw ($msg)
                }
                
                $doLoop = (($job.Status -notmatch "Completed") `
                          -and ($job.Status -notmatch "Failed") `
                          -and ($job.Status -notmatch "Suspended") `
                          -and ($job.Status -notmatch "Stopped"))
            }
            
            if ($job.Status -match "Completed") {
                if ($ReturnJobOutput) {
                    # Output
                    $jobout = Get-AzureAutomationJobOutput `
                                    -Id $job.Id `
                                    -AutomationAccountName $AutomationAccountName `
                                    -Stream Output
                    if ($jobout) {Write-Output $jobout.Text}
                    
                    # Error
                    $jobout = Get-AzureAutomationJobOutput `
                                    -Id $job.Id `
                                    -AutomationAccountName $AutomationAccountName `
                                    -Stream Error
                    if ($jobout) {Write-Error $jobout.Text}
                    
                    # Warning
                    $jobout = Get-AzureAutomationJobOutput `
                                    -Id $job.Id `
                                    -AutomationAccountName $AutomationAccountName `
                                    -Stream Warning
                    if ($jobout) {Write-Warning $jobout.Text}
                    
                    # Verbose
                    $jobout = Get-AzureAutomationJobOutput `
                                    -Id $job.Id `
                                    -AutomationAccountName $AutomationAccountName `
                                    -Stream Verbose
                    if ($jobout) {Write-Verbose $jobout.Text}
                }
                else {
                    # Return the job id
                    Write-Output $job.Id
                }
            }
            else {
                # The job did not complete successfully, so throw an exception
                $msg = "The child runbook job did not complete successfully."
                $msg += "  Job Status: " + $job.Status + "."
                $msg += "  Runbook: " + $ChildRunbookName + "."
                $msg += "  Job Id: " + $job.Id + "."
                $msg += "  Job Exception: " + $job.Exception
                throw ($msg)
            }
        }
    }
}