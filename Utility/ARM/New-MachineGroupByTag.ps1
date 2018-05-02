#Requires -Module @{ModuleName = 'AzureRM.Profile'; ModuleVersion = '4.6.0';}

#Requires -Module @{ModuleName = 'AzureRM.OperationalInsights'; ModuleVersion = '4.3.2';}

<#

.SYNOPSIS 

    This sample Azure Automation runbook creates a Log Analytics machine group based off of an Azure VM tag.


.DESCRIPTION

    This sample runbook creates Log Analytics machine groups based off anAzure VM tag and Update management Log Analytics data.
    
    The major steps of the script are outlined below: 

    1) Connect to the Azure account
    2) Set the subscription context
    3) Return the list of Azure VM resource IDs for the provided tag
    4) Generate the query for the Log Analytics group creation
    5) Remove the saved search if it already exists
    6) Create the machine group (saved search) 


.PARAMETER WorkspaceName

    Mandatory. The name of the OMS Workspace to be referenced.


.PARAMETER ResourceGroupName

    Mandatory. The name of the resource group to be referenced for the OMS workspace. 


.PARAMETER VmSubscriptionId

    Mandatory. A string containing the SubscriptionID of the VMs to be queried.  


.PARAMETER OmsSubscriptionId

    Optional. A string containing the SubscriptionID of the OMS workspace to be used. If no value is provided,
    
    it defaults to the VmSubscriptionId 


.PARAMETER VmTagValue

    Mandatory. The value of the Azure VM tag that you wish to define the machine group.


.EXAMPLE

    New-MachineGroupByTag -WorkspaceName "ContosoWorkspace" -ResourceGroupName "ContosoResources" -VmSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -VmTagKey "webservers"


.NOTES

    AUTHOR: Jenny Hunter, Azure Automation Team

    LASTEDIT: April 25, 2018

    EDITBY: Jenny Hunter

#>

Param (
# OMS Workspace
[Parameter(Mandatory=$true)]
[String] $WorkspaceName,

[Parameter(Mandatory=$true)]
[String] $ResourceGroupName,

# Azure Subscription
[Parameter(Mandatory=$true)]
[String] $VmSubscriptionId,

[Parameter(Mandatory=$false)]
[String] $OmsSubscriptionId,

# Azure Tag
[Parameter(Mandatory=$true)]
[String] $VmTagValue

)

# Stop the runbook if any errors occur
$ErrorActionPreference = "Stop"

# Connect to the current Azure account using an Automation account
$Conn = Get-AutomationConnection -Name AzureRunAsConnection 
$null = Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationID $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint

# Select the VM subscription
$null = Select-AzureRmSubscription -SubscriptionId $VmSubscriptionId

# Return group of VM ids that have the given tag
$VmIds = (Get-AzureRmVm -WarningAction SilentlyContinue)| Where-Object {$_.Tags.Values.Contains($VmTagValue)} | Select-Object Id

# Parse the VM resource ids into the appropriate format for the LA query
$VmIdQueryList = ($VmIds.Id | ForEach-Object {"tolower('$_')"}) -join "," 

# Define queries
$GroupQuery = "Heartbeat | where Solutions contains 'updates' and tolower(ResourceId) in ($VmIdQueryList) | distinct Computer"

# Set the workspace subscription if needed
if ($OmsSubscriptionId) {
    null = Select-AzureRmSubscription -SubscriptionId $OmsSubsciptionId
    Write-Output "Subscription context changed to $OmsSubscriptionId for accessing the workspace"
} else {
    $OmsSubsciptionId = $VmSubscriptionId
}

# Define saved search computer group properties
$SavedSearchId = "updategroup" + $VmTagValue.ToLower()
$DisplayName = "Machine group with tag $VmTagValue"
$ResourceId = "subscriptions/$OmsSubsciptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/savedSearches/$SavedSearchId"
$FunctionAlias = "updategroup" + $VmTagValue.ToLower()

# Remove the saved search computer group if it already exists
try {
   $null = Remove-AzureRmOperationalInsightsSavedSearch -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -SavedSearchId $SavedSearchId 
} catch {
    Write-Output "No previous version of $SavedSearchId was found."
}

# Create the Saved Search group
$GroupProperties = [PSCustomObject]@{
    Category="UpdateMachineGroup"
    DisplayName=$DisplayName
    Query=$GroupQuery
    Version="1"
    FunctionAlias=$FunctionAlias
    ComputerGroup=$true
    Tags = @([PSCustomObject]@{Name="Group";Value="Computer"})
}

$SavedSearchResource = New-AzureRmResource -ResourceId $ResourceId -Properties $GroupProperties -ApiVersion "2017-03-15-preview" -Force
Write-Output "Saved search machine group resource created with a resource Id of " $SavedSearchResource.ResourceId