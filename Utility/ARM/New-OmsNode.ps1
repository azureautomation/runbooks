<#

.SYNOPSIS 

    This Azure/OMS Automation runbook onboards a pre-exisiting VM as an OMS node.


.DESCRIPTION

    This Azure/OMS Automation runbook onboards an existing VM as an OMS Node.  An OMS workspace will be generated
    if needed. The major steps of the script are outlined below.
    
    1) Login to an Azure account using the Automation RunAs connection
    2) Check for the AzureRm.OperationalInsights module
    3) Get reference to workspace, create new workspace if needed
    4) Optional: Enable a solution for the workspace (example used is Change Tracking)
    5) Turn on and configure the Microsoft Monitoring Agent VM extension (Note: For this step, you will need to 
    comment out the line for which OS type the VM runs - Windows or Linux.)


.PARAMETER VMName

    Mandatory. The computer name of the Azure VM to be referenced.



.PARAMETER VmResourceGroup

    Mandatory. The resource group of the VM to be referenced. If not specified, resource group of the Automation
    
    account is used.



.PARAMETER WorkspaceName

    Optional. The name of the OMS Workspace to be referenced. If not specified, a new OMS workspace 

    is created, referencing a random number in order to create a unique identifier.



.PARAMETER OmsLocation

    Optional. The region of the OMS Workspace to be referenced. If not specified, the closest valid

    region to the Automation account is chosen.



.EXAMPLE

    New-OmsNode -MachineName "ContosoVM" -VMResourceGroup "ContosoResources"


.NOTES

    AUTHOR: Jenny Hunter, Azure/OMS Automation Team


    LASTEDIT: August 7, 2017

#>

Param (
# VM
[Parameter(Mandatory=$true)]
[String] $VmName,

# VM Resource Group
[Parameter(Mandatory=$true)]
[String] $VmResourceGroup,

# OMS Workspace
[Parameter(Mandatory=$false)]
[String] $WorkspaceName = "hybridworkspace" + (Get-Random -Maximum 99999),

# OMS Region
[Parameter(Mandatory=$false)]
[String] $OmsLocation
)

# Stop the runbook if any errors occur
$ErrorActionPreference = "Stop"

# Connect to the current Azure account
Write-Output "Pulling account credentials..."

$Conn = Get-AutomationConnection -Name AzureRunAsConnection 
$null = Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationID $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint 

# Get the subscription and tenant IDs
$SubscriptionID = $Conn.SubscriptionID
$TenantID = $Conn.TenantID

# Set the active subscription
$null = Set-AzureRmContext -SubscriptionID $SubscriptionID

# Find the automation account and resource group
$AutomationResource = Find-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts

foreach ($Automation in $AutomationResource) {

    $Job = Get-AzureRmAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue

    if (!([string]::IsNullOrEmpty($Job))) {

		$ResourceGroup = $Job.ResourceGroupName
		$AutomationAccountName = $Job.AutomationAccountName

        break;

    }
}

# Check that the resource group name is valid
$null = Get-AzureRmResourceGroup -Name $ResourceGroup -ErrorAction Stop

# Check that the automation account name is valid
$AA = Get-AzureRmAutomationAccount -ResourceGroupName $ResourceGroup -Name $AutomationAccountName -ErrorAction Stop
$AALocation = $AA.Location

# Retrieve OperationalInsights cmdlets
try {
    $null = Get-Command New-AzureRmOperationalInsightsWorkspace -CommandType Cmdlet -ErrorAction Stop
} catch {
    Write-Error "Could not find AzureRm.OperationalInsights cmdlets."
}

# Create a new OMS workspace if needed
try {

    $Workspace = Get-AzureRmOperationalInsightsWorkspace -Name $WorkspaceName -ResourceGroupName $ResourceGroup  -ErrorAction Stop
    $OmsLocation = $Workspace.Location
    Write-Output "Referencing existing OMS Workspace named $WorkspaceName in region $OmsLocation..."

} catch {

    # Select an OMS workspace region based on the AA region
    if ($AALocation -match "europe") {
        $OmsLocation = "westeurope"
    } elseif ($AALocation -match "asia") {
        $OmsLocation = "southeastasia"
    } elseif ($AALocation -match "india") {
        $OmsLocation = "southeastasia"
    } elseif ($AALocation -match "australia") {
        $OmsLocation = "australiasoutheast"
    } elseif ($AALocation -match "centralus") {
        $OmsLocation = "westcentralus"
    } elseif ($AALocation -match "japan") {
        $OmsLocation = "japaneast"
    } elseif ($AALocation -match "uk") {
        $OmsLocation = "uksouth"
    } else {
        $OmsLocation = "eastus"
    }

    Write-Output "Creating new OMS Workspace named $WorkspaceName in region $OmsLocation..."
    # Create the new workspace for the given name, region, and resource group
    $Workspace = New-AzureRmOperationalInsightsWorkspace -Location $OmsLocation -Name $WorkspaceName -Sku Standard -ResourceGroupName $ResourceGroup

}

# Optional: Activate an OMS solution (in this case - Change Tracking) in the workspace
$null = Set-AzureRmOperationalInsightsIntelligencePack -ResourceGroupName $ResourceGroup -WorkspaceName $WorkspaceName -IntelligencePackName "ChangeTracking" -Enabled $true


# Create references to the WorkspaceId and WorkspaceKey
$WorkspaceId = $workspace.CustomerId
$WorkspaceKey = (Get-AzureRmOperationalInsightsWorkspaceSharedKeys -ResourceGroupName $workspace.ResourceGroupName -Name $workspace.Name).PrimarySharedKey

# Create a reference to the VM
$vm = Get-AzureRmVM -ResourceGroupName $VmResourceGroup -Name $VmName

# For Windows VM uncomment the following line
# Set-AzureRmVMExtension -ResourceGroupName $VMresourcegroup -VMName $VMresourcename -Name 'MicrosoftMonitoringAgent' -Publisher 'Microsoft.EnterpriseCloud.Monitoring' -ExtensionType 'MicrosoftMonitoringAgent' -TypeHandlerVersion '1.0' -Location $location -SettingString "{'workspaceId': '$WorkspaceId'}" -ProtectedSettingString "{'workspaceKey': '$WorkspaceKey'}"

# For Linux VM uncomment the following line
# Set-AzureRmVMExtension -ResourceGroupName $VmResourceGroup -VMName $VmName -Name 'OmsAgentForLinux' -Publisher 'Microsoft.EnterpriseCloud.Monitoring' -ExtensionType 'OmsAgentForLinux' -TypeHandlerVersion '1.0' -Location $OmsLocation -SettingString "{'workspaceId': '$WorkspaceId'}" -ProtectedSettingString "{'workspaceKey': '$WorkspaceKey'}"