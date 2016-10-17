<#

.SYNOPSIS 

    This Azure/OMS Automation runbook onboards a local machine as a hybrid worker. An OMS workspace 
    will all be generated if needed.


.DESCRIPTION

    This Azure/OMS Automation runbook onboards a local machine as a hybrid worker. The major steps of
    the script are outlined below.
    
    1) Install the necessary modules
    2) Login to an Azure account
    3) Check for the resource group and automation account
    4) Create references to automation account attributes
    5) Create an OMS Workspace if needed
    6) Enable the Azure Automation solution in OMS
    7) Download and install the Microsoft Monitoring Agent
    8) Register the machine as hybrid worker

 
.PARAMETER ResourceGroup

    Mandatory. The name of the resource group to be referenced. If not specified, a new resource group

    is created, referencing the IDString in order to create a unique identifier.


.PARAMETER SubscriptionID

    Optional. A string containing the SubscriptionID to be used. If not specified, the first subscriptionID

    associated with the account is used.


.PARAMETER WorkspaceName

    Optional. The name of the OMS Workspace to be referenced. If not specified, a new OMS workspace 

    is created, referencing the IDString in order to create a unique identifier.


.PARAMETER AutomationAccountName

    Mandatory. The name of the Automation account to be referenced. If not specified, a new automation account 

    is created, referencing the IDString in order to create a unique identifier.


.PARAMETER GroupName

    Mandatory. The hybrid worker group name to be referenced.


.EXAMPLE

    New-OnPremiseHybridWorker -AutomationAccountName "ContosoAA" -ResourceGroupName "ContosoResources"


.NOTES

    AUTHOR: Jenny Hunter, Azure/OMS Automation Team

    LASTEDIT: October 17, 2016  

#>


#Requires -RunAsAdministrator

Param (
# Setup initial variables
[Parameter(Mandatory=$true)]
[String] $ResourceGroupName,

[Parameter(Mandatory=$false)]
[String] $SubscriptionID = "",

# OMS Workspace
[Parameter(Mandatory=$false)]
[String] $WorkspaceName = "hybridWorkspace" + (Get-Random -Maximum 99999),

# Automation
[Parameter(Mandatory=$true)]
[String] $AutomationAccountName ,

# Machine
[Parameter(Mandatory=$true)]
[String] $GroupName
)

# Stop the script if any errors occur
$ErrorActionPreference = "Stop"

# Add and update modules on the Automation account
Write-Output "Importing necessary modules..."

# Create a list of the modules necessary to register a hybrid worker
$AzureRmModule = @{"Name" = "AzureRM"; "Version" = ""}
$HybridModule = @{"Name" = "HybridRunbookWorker"; "Version" = "1.1"}
$Modules = @($AzureRmModule; $HybridModule)


# Import modules
foreach ($Module in $Modules) {

    $ModuleName = $Module.Name

    # Find the module version
    if ([string]::IsNullOrEmpty($Module.Version)){
        
        # Find the latest module version if a version wasn't provided
        $ModuleVersion = (Find-Module -Name $ModuleName).Version

    } else {

        $ModuleVersion = $Module.Version

    }

    # Check if the required module is already installed
    $CurrentModule = Get-Module -Name $ModuleName -ListAvailable | where "Version" -eq $ModuleVersion

    if (!$CurrentModule) {

        $null = Install-Module -Name $ModuleName -RequiredVersion $ModuleVersion -Force
        Write-Output "     Successfully installed version $ModuleVersion of $ModuleName..."

    } else {
        Write-Output "     Required version $ModuleVersion of $ModuleName is installed..."
    }
}

# Connect to the current Azure account
Write-Output "Pulling Azure account credentials..."

# Login to Azure account
$Account = Add-AzureRmAccount

# If a subscriptionID has not been provided, select the first registered to the account
if ([string]::IsNullOrEmpty($SubscriptionID)) {
   
    # Get a list of all subscriptions
    $Subscription =  Get-AzureRmSubscription

    # Get the subscription ID
    $SubscriptionID = (($Subscription).SubscriptionId | Select -First 1).toString()

    # Get the tenant id for this subscription
    $TenantID = (($Subscription).TenantId | Select -First 1).toString()

} else {

    # Get a reference to the current subscription
    $Subscription = Get-AzureRmSubscription -SubscriptionId $SubscriptionID
    # Get the tenant id for this subscription
    $TenantID = $Subscription.TenantId
}

# Set the active subscription
$null = Set-AzureRmContext -SubscriptionID $SubscriptionID

# Check that the resource group is valid
$null = Get-AzureRmResourceGroup -Name $ResourceGroupName

# Check that the automation account is valid
$AutomationAccount = Get-AzureRmAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName

# Find the automation account region
$AALocation = $AutomationAccount.Location

# Get Azure Automation Primary Key and Endpoint
$AutomationInfo = Get-AzureRMAutomationRegistrationInfo -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName
$AutomationPrimaryKey = $AutomationInfo.PrimaryKey
$AutomationEndpoint = $AutomationInfo.Endpoint

# Create a new OMS workspace if needed
try {

    $Workspace = Get-AzureRmOperationalInsightsWorkspace -Name $WorkspaceName -ResourceGroupName $ResourceGroupName  -ErrorAction Stop
    Write-Output "Referencing existing OMS Workspace named $WorkspaceName..."
    $OmsLocation = $Workspace.Location

} catch {

    # Select an OMS workspace region
    if ($AALocation -match "europe") {
        $OmsLocation = "westeurope"
    } elseif ($AALocation -match "asia") {
        $OmsLocation = "southeastasia"
    } elseif ($AALocation -match "australia") {
        $OmsLocation = "australiasoutheast"
    } else {
        $OmsLocation = "eastus"
    }

    Write-Output "Creating new OMS Workspace named $WorkspaceName in region $OmsLocation..."
    # Create the new workspace for the given name, region, and resource group
    $Workspace = New-AzureRmOperationalInsightsWorkspace -Location $OmsLocation -Name $WorkspaceName -Sku Standard -ResourceGroupName $ResourceGroupName

}

# Provide warning if the Automation account and OMS regions are different
if ($AALocation -match $OmsLocation) {
    Write-Output "Warning: Your Automation account and OMS workspace are in different regions and will not be compatible for future linking."
}

# Get the workspace ID
$WorkspaceId = $Workspace.CustomerId

# Get the primary key for the OMS workspace
$WorkspaceSharedKeys = Get-AzureRmOperationalInsightsWorkspaceSharedKeys -ResourceGroupName $ResourceGroupName -Name $WorkspaceName
$WorkspaceKey = $WorkspaceSharedKeys.PrimarySharedKey

# Activate the Azure Automation solution in the workspace
$null = Set-AzureRmOperationalInsightsIntelligencePack -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -IntelligencePackName "AzureAutomation" -Enabled $true

# Download the Microsoft monitoring agent
$Source = "https://download.microsoft.com/download/8/4/3/84312DF3-5111-4C13-9192-EBF2DF81B19B/MMASetup-AMD64.exe"
$Destination = "$env:temp\MMASetup-AMD64.exe"

$null = Invoke-WebRequest -uri $Source -OutFile $Destination
$null = Unblock-File $Destination

# Change directory to location of the downloaded MMA
cd $env:temp

# Install the MMA
./MMASetup-AMD64.exe /qn ADD_OPINSIGHTS_WORKSPACE=1 OPINSIGHTS_WORKSPACE_ID= + $WorkspaceID + OPINSIGHTS_WORKSPACE_KEY= + $WorkspaceKey + AcceptEndUserLicenseAgreement=1 

# Check for the HybridRegistration module
Write-Output "Checking for the HybridRegistration module..."
$null = Get-Module -Name HybridRegistration -ListAvailable

# Register the hybrid runbook worker
Write-Output "Registering the hybrid runbook worker..."
Add-HybridRunbookWorker -Name $GroupName -EndPoint $AutomationEndpoint -Token $AutomationPrimaryKey