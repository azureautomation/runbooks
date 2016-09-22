
<#PSScriptInfo

.VERSION 1.01

.GUID a119dd78-7857-4c5d-9f53-3beb7a61a5f5

.AUTHOR AzureAutomationTeam

.COMPANYNAME Microsoft

.COPYRIGHT 

.TAGS AzureAutomation OMS Utility

.LICENSEURI 

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/Utility/ASM/Start-AutomationChildRunbook.ps1

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

.PARAMETER ServicePrincipalConnectionName
    A connection asset containing the information for the Run As Account.  
    To learn more about run as accounts see http://aka.ms/runasaccount.
 
.PARAMETER ResourceGroupName
    The name of the resource group the Automation account is located in

.PARAMETER AutomationAccountName
    The name of the Azure Automation account that the runbook to start exists in.

.PARAMETER WaitForJobCompletion
    Boolean value.  If true, wait for the runbook job to finish.  If false, don't wait
    and return the job id.  Default is false.

.PARAMETER ReturnJobOutput
    Boolean value.  If true, the runbook job output is returned as a string.  Both this parameter
    and WaitForJobCompletion must be true to get job output.  Default is false.


.PARAMETER JobPollingTimeoutInSeconds
    An integer that sets the maximum time in seconds to poll the child job.  
    If this time limit is exceeded, a timeout exception will be thrown.
    Default is 600 seconds (10 minutes).  This is used only when WaitForJobCompletion is true.

.EXAMPLE
    Start-AutomationChildRunbook `
        -ChildRunbookName "Update-VM" `
        -ChildRunbookInputParams @{'VMName'='VM204';'Retries'=3} `
        -ResourceGroupName "ContosoItResourceGroup"
        -AutomationAccountName "ContosoITAutomationProduction" `
        -WaitForJobCompletion $true `
        -ReturnJobOutput $true `
        -JobPollingTimeoutInSeconds 120

.NOTES
    AUTHOR: System Center Automation Team
    LASTEDIT: August 15, 2016
    CHANGES:
        January 9, 2015 - Use Azure Org Id credential to authenticate (rather than Azure certificate)
        August 15, 2016 - Use ARM cmdlets and new wait flag to wait for job output
#>

[OutputType([object])]
    
param (
    [Parameter(Mandatory=$true)]
    [string] 
    $ChildRunbookName,
        
    [Parameter(Mandatory=$false)]
    [hashtable] 
    $ChildRunbookInputParams,
        
   	[parameter(Mandatory=$false)]
    [String]
    $ServicePrincipalConnectionName = 'AzureRunAsConnection',
        
    [Parameter(Mandatory=$true)]
    [string] 
    $ResourceGroupName,

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
    $JobPollingTimeoutInSeconds = 600
)

# Determine if parameter values are incompatible
if(!$WaitForJobCompletion -and $ReturnJobOutput) {
    $msg = "The parameters WaitForJobCompletion and ReturnJobOutput must both "
    $msg += "be true if you want job output returned."
    throw ($msg)
}
   
# Connect to Azure so that this runbook can call the Azure cmdlets
$ServicePrincipalConnection = Get-AutomationConnection -Name $ServicePrincipalConnectionName   
if (!$ServicePrincipalConnection) 
{
    $ErrorString = @"
    Service principal connection $ServicePrincipalConnectionName not found.  Make sure you have created it in Assets. 
    See http://aka.ms/runasaccount to learn more about creating Run As accounts. 
"@
    throw $ErrorString
} 
Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $ServicePrincipalConnection.TenantId `
        -ApplicationId $ServicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $ServicePrincipalConnection.Certificate | Write-Verbose

# Assure job parameters are not null
if ($ChildRunbookInputParams -eq $null) { $ChildRunbookInputParams = @{} }

# Start the child runbook 
if (-not $WaitForJobCompletion) {
    $job = Start-AzureRmAutomationRunbook `
                -Name $ChildRunbookName `
                -Parameters $ChildRunbookInputParams `
                -AutomationAccountName $AutomationAccountName `
                -ResourceGroupName $ResourceGroupName `
                -ErrorAction "Stop" 
} else {
    $job = Start-AzureRmAutomationRunbook `
                -Name $ChildRunbookName `
                -Parameters $ChildRunbookInputParams `
                -AutomationAccountName $AutomationAccountName `
                -ResourceGroupName $ResourceGroupName `
                -ErrorAction "Stop" `
                -Wait `
                -MaxWaitSeconds $JobPollingTimeoutInSeconds
}

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
        if ($job.Status -match "Completed") {
            if ($ReturnJobOutput) {
                # Output
                $jobout = Get-AzureRmAutomationJobOutput `
                                -Id $job.Id `
                                -AutomationAccountName $AutomationAccountName `
                                -ResourceGroupName $ResourceGroupName `
                                -Stream Output
                if ($jobout) {Write-Output $jobout.Text}
                    
                # Error
                $jobout = Get-AzureRmAutomationJobOutput `
                                -Id $job.Id `
                                -AutomationAccountName $AutomationAccountName `
                                -ResourceGroupName $ResourceGroupName `
                                -Stream Error
                if ($jobout) {Write-Error $jobout.Text}
                    
                # Warning
                $jobout = Get-AzureRmAutomationJobOutput `
                                -Id $job.Id `
                                -AutomationAccountName $AutomationAccountName `
                                -ResourceGroupName $ResourceGroupName `
                                -Stream Warning
                if ($jobout) {Write-Warning $jobout.Text}
                    
                # Verbose
                $jobout = Get-AzureRmAutomationJobOutput `
                                -Id $job.Id `
                                -AutomationAccountName $AutomationAccountName `
                                -ResourceGroupName $ResourceGroupName `
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
