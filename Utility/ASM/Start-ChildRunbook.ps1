<#
.SYNOPSIS 
     Starts an Azure Automation runbook job and either returns the job id or waits for the job
     to complete and returns the job output

.DESCRIPTION
    This runbook starts a child runbook when called from a parent runbook.

.PARAMETER ChildRunbookName
    The name of the runbook to start.

.PARAMETER ChildRunbookInputParams
    A hashtable with the names of parameters of the runbook to start as keys and values for 
    these parameters as values

.PARAMETER AzureSubscriptionName
    Name of the Azure subscription to connect to
    
.PARAMETER AzureOrgIdCredential
    A credential containing an Org Id username / password with access to this Azure subscription.

	If invoking this runbook inline from within another runbook, pass a PSCredential for this parameter.

	If starting this runbook using Start-AzureAutomationRunbook, or via the Azure portal UI, pass as a string the
	name of an Azure Automation PSCredential asset instead. Azure Automation will automatically grab the asset with
	that name and pass it into the runbook.

.PARAMETER AutomationAccountName
    The name of the Azure Automation account that the runbook to start exists in.

.PARAMETER WaitForJobCompletion
    Boolean value.  If True, wait for the runbook job to finish.  If false, don't wait
    and return the job id.

.PARAMETER ReturnJobOutput
    Boolean value.  If True, the runbook job output is returned as a string.  Both this parameter
    and WaitForJobCompletion must be True to get job output.

.PARAMETER JobPollingIntervalInSeconds
    An integer that sets the time in seconds to wait between each poll of the child job to 
    determine if the job has finished.  Default is 10 seconds.  This is used when WaitForJobCompletion 
    is True.

.PARAMETER JobPollingTimeoutInSeconds
    An integer that sets the maximum time in seconds to poll the child job.  
    If this time limit is exceeded, an exception will be thrown.
    Default is 600 seconds (10 minutes).  This is used when WaitForJobCompletion is True.

.EXAMPLE
    Start-ChildRunbook `
        -ChildRunbookName "Update-VM" `
        -ChildRunbookInputParams @{'VMName'='VM204';'Retries'=3} `
        -AzureSubscriptionName "Visual Studio Ultimate with MSDN" `
		-AzureOrgIdCredential $cred `
        -AutomationAccountName "Contoso IT Automation Production" `
        -WaitForJobCompletion $true `
        -ReturnJobOutput $true `
        -JobPollingIntervalInSeconds 20 `
        -JobPollingTimeoutInSeconds 120

.NOTES
    AUTHOR: System Center Automation Team
    LASTEDIT: Aug 14, 2014
#>

workflow Start-ChildRunbook
{
    [OutputType([object])]
    
    param (
        [Parameter(Mandatory=$true)]
        [string] 
        $ChildRunbookName,
        
        [Parameter(Mandatory=$false)]
        [hashtable] 
        $ChildRunbookInputParams,
        
        [Parameter(Mandatory=$true)]
        [String]
        $AzureSubscriptionName,

		[Parameter(Mandatory=$true)]
        [PSCredential]
        $AzureOrgIdCredential,

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
   if(!$WaitForJobCompletion -and $ReturnJobOutput)
   {
       throw ("The parameters WaitForJobCompletion and ReturnJobOutput must both be true if you want job output returned.")
   }
   
    # Connect to Azure so that this runbook can call the Azure cmdlets
    Add-AzureAccount -Credential $AzureOrgIdCredential

	# Select the Azure subscription we will be working against
    Select-AzureSubscription -SubscriptionName $AzureSubscriptionName

    InlineScript
    {
        # Convert the parameters in the Workflow scope into parameters in InlineScript scope
        $AutomationAccountName = $using:AutomationAccountName
        $ChildRunbookInputParams = $using:ChildRunbookInputParams
        $ChildRunbookName = $using:ChildRunbookName
        $JobPollingIntervalInSeconds = $using:JobPollingIntervalInSeconds
        $JobPollingTimeoutInSeconds = $using:JobPollingTimeoutInSeconds
        $ReturnJobOutput = $using:ReturnJobOutput
        $WaitForJobCompletion = $using:WaitForJobCompletion
    
        if ($ChildRunbookInputParams -eq $null) { $ChildRunbookInputParams = @{} }
    
        # Start the child runbook and get the job returned
        $job = Start-AzureAutomationRunbook `
                    -Name $ChildRunbookName `
                    -Parameters $ChildRunbookInputParams `
                    -AutomationAccountName $AutomationAccountName `
                    -ErrorAction "Stop"
        
        # Determine if there is a job and if the job output is wanted or not
        if ($job -eq $null)
        {
            # No job was created, so throw an exception
            throw ("No job was created for runbook: $ChildRunbookName.")
        }
        else
        {
            # There is a job
            
            # Log the started runbook’s job id for tracking
            Write-Verbose -Message "Started runbook: $ChildRunbookName. Job Id: $job.Id"
            
            if ($WaitForJobCompletion -eq $false)
            {
                # Don't wait for the job to finish, just return the job id
                Write-Output $job.Id
            }
            elseif ($WaitForJobCompletion -eq $true)
            {
                # Monitor the job until it finishes or the timeout limit has been reached
                $maxDate = (Get-Date).AddSeconds($JobPollingTimeoutInSeconds)
                
                $doLoop = $true
                
                while($doLoop) {
                    Start-Sleep -s $JobPollingIntervalInSeconds
                    
                    $job = Get-AzureAutomationJob `
                        -Id $job.Id `
                        -AutomationAccountName $AutomationAccountName
                        
                    $status = $job.Status
                    
                    $noTimeout = ($maxDate -ge (Get-Date))
                    
                    if ($noTimeout -eq $false) { 
                        throw ("The job for runbook $ChildRunbookName did not complete within the timeout limit of $JobPollingTimeoutInSeconds seconds, so polling for job completion was halted. The job will continue running, but no job output will be returned.")
                    }
                    
                    $doLoop = (($status -ne "Completed") -and ($status -ne "Failed") `
                              -and ($status -ne "Suspended") -and ($status -ne "Stopped") `
                              -and $noTimeout)
                }
                
                if ($job.Status -eq "Completed")
                {
                    if ($ReturnJobOutput)
                    {
                        # Get the output from job
                        $jobout = Get-AzureAutomationJobOutput `
                            -Id $job.Id `
                            -Stream Output `
                            -AutomationAccountName $AutomationAccountName
                    
                        # Return the output string
                        Write-Output $jobout.Text
                    }
                    else
                    {
                        # Return the job id
                        Write-Output $job.Id
                    }
                }
                else
                {
                    # The job did not complete successfully, so throw an exception
                    $msg = "The child runbook job did not complete successfully."
                    $msg += "  Job Status: $job.Status.  Runbook: $ChildRunbookName.  Job Id: $job.Id."
                    $msg += "  Job Exception: $job.Exception"
                    throw ($msg)
                }
            }
        }
    }
}