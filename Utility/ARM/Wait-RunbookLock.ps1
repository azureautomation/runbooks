
<#PSScriptInfo

.VERSION 1.01

.GUID 556bd161-7d40-49b8-8f12-78ee9e1550e2

.AUTHOR AzureAutomationTeam

.COMPANYNAME Microsoft

.COPYRIGHT 

.TAGS AzureAutomation OMS Utility

.LICENSEURI 

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Wait-RunbookLock.ps1

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES


#>

#Requires -Module AzureRM.Profile
#Requires -Module AzureRM.Automation

<# 

.DESCRIPTION 
 This Azure Automation runbook ensures that only one instance of a PowerShell runbook is running at
 any one time. It is meant to be called inline from another runbook at the beginning of the runbook. 

#>

<#
.SYNOPSIS
    Allows only a certain amount of runbook jobs to run at any one time.

.DESCRIPTION
    This runbook ensures that only one instance of a runbook is running at
    any one time. It is meant to be called from another runbook at the beginning of the runbook. 

.PARAMETER ResourceGroup
    The name of the resource group for this automation accoun

.PARAMETER AutomationAccountName
    The name of the Automation account where this runbook is started from

.PARAMETER AzureConnectionAssetName
   Optional with default of "AzureRunAsConnection".
   The name of an Automation connection asset that contains an Azure AD service principal with authorization for the subscription. 
   To use an asset with a different name you can pass the asset name as a runbook input parameter or change
   the default value for this input parameter.

   If you selected "Create Azure Run As Account" when creating the automation account running this runbook, you will already
   have a connection asset with the default name ("AzureRunAsConnection") set up. If not, you can create a connection asset / Azure AD
   service principal by following the directions here: https://azure.microsoft.com/en-us/documentation/articles/automation-sec-configure-azure-runas-account

.PARAMETER NoOfInstances
    The number of concurrent jobs to allow. Will default to 1 if not provided. Optional Parameter.

.EXAMPLE
 
    .\Wait-RunbookLock.ps1 -ResourceGroup 'Finance' -AutomationAccountName 'FinanceTeam'
	  
.NOTES
    AUTHOR: System Center Automation Team
    LASTEDIT: April 3rd, 2016
#>

Param ( 
    [Parameter(Mandatory=$true)]
    [String] $ResourceGroup,

    [Parameter(Mandatory=$true)]
    [String] $AutomationAccountName,
        
    [Parameter(Mandatory=$false)] 
    [String]  $AzureConnectionAssetName = "AzureRunAsConnection",

    [Parameter(Mandatory=$false)]
    [Int] $NoOfInstances = 1
)

# Connect to Azure using service principal auth
$ServicePrincipalConnection = Get-AutomationConnection -Name $AzureConnectionAssetName    
if ($ServicePrincipalConnection -eq $null)
{
    throw "Could not retrieve '$AzureConnectionAssetName' credential asset. Check that you created this first in the Automation service."
}
    
# Get the automation job id for this runbook job
$AutomationJobID = $PSPrivateMetaData.JobId.Guid
Write-Verbose ("This Job is " + $AutomationJobID)
Write-Verbose ("Number of instances allowed is " + $NoOfInstances)
             
Login-AzureRMAccount `
        -ServicePrincipal `
        -TenantId $ServicePrincipalConnection.TenantId `
        -ApplicationId $ServicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint | Write-Verbose 

Select-AzureRmSubscription -SubscriptionId $ServicePrincipalConnection.SubscriptionID  | Write-Verbose 
               
# Get the information for this job so we can retrieve the runbook name
$CurrentJob = Get-AzureRMAutomationJob -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -Id $AutomationJobID
       
# Get all active jobs for this runbook
$AllActiveJobs = Get-AzureRMAutomationJob -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName `
            -RunbookName $CurrentJob.RunbookName | Where {($_.Status -eq "Running") `
                                                    -or ($_.Status -eq "Starting") `
                                                    -or ($_.Status -eq "Queued")}  

$OldestJob = $AllActiveJobs | Sort-Object -Property CreationTime  | Select-Object -First 1    
# If this job is not the oldest created job we will wait until the existing jobs complete or the number of jobs is less than NoOfInstances
While (($AutomationJobID -ne $OldestJob.JobId) -and ($AllActiveJobs.Count -ge $NoOfInstances))
{
    Write-Verbose "Waiting as there are currently running jobs for this runbook already. Sleeping 30 seconds..."
    Sleep 30
    $AllActiveJobs = Get-AzureRMAutomationJob -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName `
                        -RunbookName $CurrentJob.RunbookName | Where {($_.Status -eq "Running")} 
    $OldestJob = $AllActiveJobs | Sort-Object -Property CreationTime  | Select-Object -First 1
    Write-Verbose("Oldest Job is " + $OldestJob.JobId)
    Write-Verbose ("Number of current jobs running is " + $AllActiveJobs.Count)
} 
Write-Verbose "Job can continue..."  


