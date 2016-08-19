
<#PSScriptInfo

.VERSION 1.01

.GUID 1a505183-5f4e-4de2-964e-c6514c351841

.AUTHOR AzureAutomationTeam

.COMPANYNAME Microsoft

.COPYRIGHT 

.TAGS AzureAutomation OMS Utility

.LICENSEURI 

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Manage-MonitorRunbook.ps1

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES


#>

#Requires -Module AzureRM.Profile
#Requires -Module AzureRm.Automation

<#
.SYNOPSIS 
    Utility runbook to control monitor runbooks to run at specific intervals

.DESCRIPTION
    This runbook is designed to run on scheduled intervals and resume any monitor runbooks
    that have a specific tag that are suspended

.PARAMETER AccountName
    Name of the Azure automation account name
    
.PARAMETER ServicePrincipalConnectionName
    A connection asset containing the information for the Run As Account.  To learn more about run as accounts see http://aka.ms/runasaccount.

.PARAMETER Tag
    Value of the tag for monitor runbooks in the service that should be resumed. Only this specific tag should be set on monitor runbooks
	to avoid other runbooks from getting resumed if they are suspended. 
    
.PARAMETER ResourceGroupName
    The name of the resource group the Automation account is located in.

.EXAMPLE
    Manage-MonitorRunbook -AccountName "Finance" -AzureCredentialSetting 'FinanceOrgID' -Tag "Monitor" -SubscriptionName "Visual Studio Ultimate with MSDN"

#>

Param ( 
    [Parameter(Mandatory=$true)]
    [String] $AccountName,
        
    [Parameter(Mandatory=$false)]
    [String] $ServicePrincipalConnectionName = 'AzureRunAsConnection',
        
    [Parameter(Mandatory=$true)]
    [String] $Tag,
        
    [Parameter(Mandatory=$false)]
    [String] $ResourceGroupName
)
    
$ServicePrincipalConnection = Get-AutomationConnection -Name $ServicePrincipalConnectionName   
if (!$ServicePrincipalConnection) 
{
    $ErrorString = @"
    Service principal connection AzureRunAsConnection not found.  Make sure you have created it in Assets. 
    See http://aka.ms/runasaccount to learn more about creating Run As accounts. 
"@
    throw $ErrorString
}  	

# Set the Azure subscription to use
Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $ServicePrincipalConnection.TenantId `
        -ApplicationId $ServicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $ServicePrincipalConnection.Certificate | Write-Verbose 
         
   
# Get the list of runbooks that have the specified tag
$MonitorRunbooks = Get-AzureRmAutomationRunbook -AutomationAccountName $AccountName -ResourceGroupName $ResourceGroupName | where -FilterScript {$_.Tags -match $Tag}
    
foreach ($Runbook in $MonitorRunbooks)
{
    Write-Verbose ("Checking " + $Runbook.Name + " for suspended jobs to resume")
    # Get the next suspended job if there is one for this Runbook Id
    $SuspendedJobs = Get-AzureRmAutomationJob -ResourceGroupName $ResourceGroupName -AutomationAccountName $AccountName `
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
        Resume-AzureRmAutomationJob -ResourceGroupName $ResourceGroupName -AutomationAccountName $AccountName -Id $SuspendedJobs.Id   
    }
}
