<#PSScriptInfo
.VERSION 1.0
.GUID 598866a9-17ba-4e25-a817-084cecd533b6
.AUTHOR Azure Automation Team
.COMPANYNAME Microsoft
.COPYRIGHT 
.TAGS Azure Automation 
.LICENSEURI 
.PROJECTURI 
.ICONURI 
.EXTERNALMODULEDEPENDENCIES 
.REQUIREDSCRIPTS 
.EXTERNALSCRIPTDEPENDENCIES 
.RELEASENOTES
#>
<#  
.SYNOPSIS  
  Finds and returns the Automation job associated with the runbook that is running this script. 
  
.DESCRIPTION  
  This runbook, when called inline from a parent runbook, will find the job associated with the parent runbook and return the job object.
  This runbook assumes that the parent runbook has authenticated with Azure.

.EXAMPLE
  .\Get-ThisAutomationJob.ps1

.NOTES
   AUTHOR: Azure Automation Team 
   LASTEDIT: 2016-10-10
#>  

# Returns a job object
[OutputType ("Microsoft.Azure.Commands.Automation.Model.Job")]

$AutomationResource = Find-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts
foreach ($Automation in $AutomationResource) 
{
	# Loop through each Automation account to find this job
    $Job = Get-AzureRmAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
    if ($Job) 
    {
		$Job
        break
    }
}
