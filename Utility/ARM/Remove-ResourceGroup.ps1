<#  
.SYNOPSIS  
  Connects to Azure and removes resource groups that match the name filter 
  
.DESCRIPTION  
  This runbook connects to Azure and removes resource groups with names that have substrings that match the name filter.
  All of the resources in each resource group are also removed.
  An important option is to run in preview mode to see which resource groups and resources will be removed without actually removing them.
  The Azure subscription that is assumed is the subscription that contains the Automation account that is running this runbook.
  The runbook will NOT remove the resource group that contains the Automation account that is running this runbook.
  
  REQUIRED AUTOMATION ASSETS 
     An Automation connection asset that contains the Azure service principal, by default named AzureRunAsConnection. 
  
.PARAMETER NameFilter  
  Required  
  Allows you to specify a name filter to limit the resource groups that you will remove. 
  Pass multiple name filters through a comma separated list.      
  The filter is not case sensitive and will match any resource group that contains the string.    
  
.PARAMETER PreviewMode  
  Optional, with default of $true (preview mode is on by default).  
  Execute the runbook to see which resource groups would be deleted but take no action.
  Run the runbook in preview mode first to see which resource groups would be removed.

.NOTES
   AUTHOR: Azure Automation Team 
   LASTEDIT: 2016-9-19
#>

# Returns strings with status messages  
[OutputType([String])] 
 
param ( 
	[parameter(Mandatory = $true)] 
	[string] $NameFilter, 
	 
	[parameter(Mandatory = $false)] 
	[bool] $PreviewMode = $true 
) 

$ErrorActionPreference = "Stop"
 
# Connect to Azure with RunAs account
$conn = Get-AutomationConnection -Name "AzureRunAsConnection" 
$null = Add-AzureRmAccount `
  -ServicePrincipal `
  -TenantId $conn.TenantId `
  -ApplicationId $conn.ApplicationId `
  -CertificateThumbprint $conn.CertificateThumbprint

# Use the subscription that this Automation account is in
$null = Select-AzureRmSubscription -SubscriptionId $conn.SubscriptionID 

# Parse name filter list
if ($NameFilter) { 
	$nameFilterList = $NameFilter.Split(',') 
	[regex]$nameFilterRegex = '(' + (($nameFilterList | foreach {[regex]::escape($_.ToLower())}) –join "|") + ')' 
} 

# Find the resource group that this Automation job is running in so that we can protect it from being removed
if ([string]::IsNullOrEmpty($PSPrivateMetadata.JobId.Guid)) {
	throw ("This is not running from the Automation service, so could not retrieve the resource group for the Automation account in order to protect it from being removed.")
}
else {
	$AutomationResource = Get-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts -ExtensionResourceName Microsoft.Automation
	foreach ($Automation in $AutomationResource) {
		# Loop through each Automation account to find this job
	    $Job = Get-AzureRmAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
	    if (!([string]::IsNullOrEmpty($Job))) {
            $thisResourceGroupName = $Job.ResourceGroupName
            break;
	    }
	}
}

# Process the resource groups
try { 
	# Find resource groups to remove based on passed in name filter
	$groupsToRemove = Get-AzureRmResourceGroup | `
						? { $nameFilterList.Count -eq 0 -or $_.ResourceGroupName.ToLower() -match $nameFilterRegex } 

	# Assure the job resource group is not in the list
    if (!([string]::IsNullOrEmpty($thisResourceGroupName))) {
		Write-Output ("The resource group for this runbook job will not be removed.  Resource group: $thisResourceGroupName")
		$tempListOfGroups = @()
		foreach ($group in $groupsToRemove) {						 
			if ($($group.ResourceGroupName) -ne $thisResourceGroupName) {
				# Add the group to a new list
				$tempListOfGroups += $group
			}
		}
		$groupsToRemove = $tempListOfGroups
	}
	
	# No matching groups were found to remove 
	if ($groupsToRemove.Count -eq 0) { 
		Write-Output "No matching resource groups found." 
	} 
	# Matching groups were found to remove 
	else 
	{ 
		# In preview mode, so report what would be removed, but take no action.
		if ($PreviewMode -eq $true) { 
			Write-Output "Preview Mode: The following resource groups would be removed:" 
			foreach ($group in $groupsToRemove){						 
				Write-Output $($group.ResourceGroupName) 
			} 
			Write-Output "Preview Mode: The following resources would be removed:" 
			$resources = (Get-AzureRmResource | foreach {$_} | Where-Object {$groupsToRemove.ResourceGroupName.Contains($_.ResourceGroupName)}) 
			foreach ($resource in $resources) { 
				Write-Output $resource 
			} 
		} 
		# Remove the resource groups
		else { 
			Write-Output "The following resource groups will be removed:" 
			foreach ($group in $groupsToRemove){						 
				Write-Output $($group.ResourceGroupName) 
			} 
			Write-Output "The following resources will be removed:" 
			$resources = (Get-AzureRmResource | foreach {$_} | Where-Object {$groupsToRemove.ResourceGroupName.Contains($_.ResourceGroupName)}) 
			foreach ($resource in $resources) { 
				Write-Output $resource 
			} 
			# Here is where the remove actions happen
			foreach ($resourceGroup in $groupsToRemove) { 
				Write-Output "Starting to remove resource group: $($resourceGroup.ResourceGroupName) ..." 
				Remove-AzureRmResourceGroup -Name $($resourceGroup.ResourceGroupName) -Force 
				if ((Get-AzureRmResourceGroup -Name $($resourceGroup.ResourceGroupName) -ErrorAction SilentlyContinue) -eq $null) { 
					Write-Output "...successfully removed resource group: $($resourceGroup.ResourceGroupName)" 
				}				 
			} 
		} 
		Write-Output "Completed." 
	} 
} 
catch { 
	$errorMessage = $_ 
} 
if ($errorMessage) { 
	Write-Error $errorMessage 
} 
