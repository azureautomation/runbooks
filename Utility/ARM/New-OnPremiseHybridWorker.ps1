<#PSScriptInfo 

.VERSION 1.6

.GUID b6ad1d8e-263a-46d6-882b-71592d6e166d 

.AUTHOR Azure Automation Team

.COMPANYNAME Microsoft / ITON

.COPYRIGHT 

.TAGS Azure Automation 

.LICENSEURI https://github.com/azureautomation/runbooks/blob/master/LICENSE

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/New-OnPremiseHybridWorker.ps1

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES 

1.6 - 11/15/2018
 -- MODIFIED BY Alexander Zabielski
 -- Updated the parameters to accept a TenantID to pass to the connection params.

1.5 - 5/29/2018
 -- MODIFIED BY Jenny Hunter
 -- updated use of New-AzureRmOperationInsightsWorkspace cmdlet to user the "PerNode" SKU

1.4 - 1/5/2018
 -- MODIFIED BY V-JASIMS TO FIX RESOURCEGROUP BUG 01/02/2018
 -- added param $OMSResourceGroupName - specify OMS resource group if using an existing OMS workspace
 -- APPROVED BY Jenny Hunter

1.3 - 8/7/2017
-- MODIFIED BY Jenny Hunter
-- updated to account for new region support

1.2 - 7/18/2017
 -- MODIFIED BY Peppe Kerstens at ITON
 -- corrected wrong type assignment
 -- added credential support
 -- APPROVED BY Jenny Hunter
#>

<#

.SYNOPSIS 

    This Azure/OMS Automation runbook onboards a local machine as a hybrid worker. An OMS workspace 
    will all be generated if needed.


.DESCRIPTION

    This Azure/OMS Automation runbook onboards a local machine as a hybrid worker. NOTE: This script is
    intended to be run with administrator privileges and on a machine with WMF 5.
    
    The major steps of the script are outlined below. 
    1) Install the necessary modules
    2) Login to an Azure account
    3) Check for the resource group and automation account
    4) Create references to automation account attributes
    5) Create an OMS Workspace if needed
    6) Enable the Azure Automation solution in OMS
    7) Download and install the Microsoft Monitoring Agent
    8) Register the machine as hybrid worker

 
.PARAMETER AAResourceGroupName

    Mandatory. The name of the resource group to be referenced for the Automation account. 


.PARAMETER OMSResourceGroupName

    Optional. The name of the resource group to be referenced for the OMS workspace. If not specified,
    
    the AAResourceGroupName is useed.


.PARAMETER SubscriptionID

    Mandatory. A string containing the SubscriptionID to be used.


.PARAMETER TenantID

    Optional. A string containing the TenantID to be used.


.PARAMETER WorkspaceName

    Optional. The name of the OMS Workspace to be referenced. If not specified, a new OMS workspace 

    is created using a unique identifier.


.PARAMETER AutomationAccountName

    Mandatory. The name of the Automation account to be referenced.


.PARAMETER HybridGroupName

    Mandatory. The hybrid worker group name to be referenced.

    
.PARAMETER Credential 

    Optional. The credentials to use when loging into Azure environment. When running this script on a Windows Core machine, credentials MUST be Azure AD credentials.

    See: https://github.com/Azure/azure-powershell/issues/2915


.EXAMPLE

    New-OnPremiseHybridWorker -AutomationAccountName "ContosoAA" -AAResourceGroupName "ContosoResources" -HybridGroupName "ContosoHybridGroup" -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"


.EXAMPLE

    $Credentials = Get-Credential

    New-OnPremiseHybridWorker -AutomationAccountName "ContosoAA" -AAResourceGroupName "ContosoResources" -HybridGroupName "ContosoHybridGroup" -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -Credential $Credentials


.NOTES

    AUTHOR: Jenny Hunter, Azure Automation Team

    LASTEDIT: May 29, 2018

    EDITBY: Jenny Hunter

#>


#Requires -RunAsAdministrator

Param (
# Setup initial variables
[Parameter(Mandatory=$true)]
[String] $AAResourceGroupName,

[Parameter(Mandatory=$false)]
[String] $OMSResourceGroupName,

[Parameter(Mandatory=$true)]
[String] $SubscriptionID,

[Parameter(Mandatory=$false)]
[String] $TenantID,

# OMS Workspace
[Parameter(Mandatory=$false)]
[String] $WorkspaceName = "hybridWorkspace" + (Get-Random -Maximum 99999),

# Automation Account
[Parameter(Mandatory=$true)]
[String] $AutomationAccountName ,

# Hyprid Group
[Parameter(Mandatory=$true)]
[String] $HybridGroupName,

# Hyprid Group
[Parameter(Mandatory=$false)]
[PSCredential] $Credential
)


# Stop the script if any errors occur
$ErrorActionPreference = "Stop"

# Add and update modules on the Automation account
Write-Output "Importing necessary modules..."

# Create a list of the modules necessary to register a hybrid worker
$AzureRmModule = @{"Name" = "AzureRM"; "Version" = ""}
$Modules = @($AzureRmModule)

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
$paramsplat = @{}

if ($Credential) {
    $paramsplat.Credential = $Credential
}

if($TenantID) {
    $paramsplat.TenantId = $TenantID
}

Write-Output "Connecting with the Following Parameters"
Write-Output $paramsplat

$Account = Add-AzureRmAccount @paramsplat 

# Get a reference to the current subscription
#$Subscription = Get-AzureRmSubscription -SubscriptionId $SubscriptionID
# Get the tenant id for this subscription
#$TenantID = $Subscription.TenantId


# Set the active subscription
$null = Set-AzureRmContext -SubscriptionID $SubscriptionID

# Check that the resource groups are valid
$null = Get-AzureRmResourceGroup -Name $AAResourceGroupName
if ($OMSResourceGroupName) {
    $null = Get-AzureRmResourceGroup -Name $OMSResourceGroupName
} else {
    $OMSResourceGroupName = $AAResourceGroupName
}

# Check that the automation account is valid
$AutomationAccount = Get-AzureRmAutomationAccount -ResourceGroupName $AAResourceGroupName -Name $AutomationAccountName

# Find the automation account region
$AALocation = $AutomationAccount.Location

# Print out Azure Automation Account name and region
Write-Output("Accessing Azure Automation Account named $AutomationAccountName in region $AALocation...")

# Get Azure Automation Primary Key and Endpoint
$AutomationInfo = Get-AzureRMAutomationRegistrationInfo -ResourceGroupName $AAResourceGroupName -AutomationAccountName $AutomationAccountName
$AutomationPrimaryKey = $AutomationInfo.PrimaryKey
$AutomationEndpoint = $AutomationInfo.Endpoint

# Create a new OMS workspace if needed
try {

    $Workspace = Get-AzureRmOperationalInsightsWorkspace -Name $WorkspaceName -ResourceGroupName $OMSResourceGroupName  -ErrorAction Stop
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
    $Workspace = New-AzureRmOperationalInsightsWorkspace -Location $OmsLocation -Name $WorkspaceName -Sku PerNode -ResourceGroupName $OMSResourceGroupName

}

# Provide warning if the Automation account and OMS regions are different
if (!($AALocation -match $OmsLocation) -and !($OmsLocation -match "eastus" -and $AALocation -match "eastus")) {
    Write-Output "Warning: Your Automation account and OMS workspace are in different regions and will not be compatible for future linking."
}

# Get the workspace ID
$WorkspaceId = $Workspace.CustomerId

# Get the primary key for the OMS workspace
$WorkspaceSharedKeys = Get-AzureRmOperationalInsightsWorkspaceSharedKeys -ResourceGroupName $OMSResourceGroupName -Name $WorkspaceName
$WorkspaceKey = $WorkspaceSharedKeys.PrimarySharedKey

# Activate the Azure Automation solution in the workspace
$null = Set-AzureRmOperationalInsightsIntelligencePack -ResourceGroupName $OMSResourceGroupName -WorkspaceName $WorkspaceName -IntelligencePackName "AzureAutomation" -Enabled $true

# Check for the MMA on the machine
try {

    $mma = New-Object -ComObject 'AgentConfigManager.MgmtSvcCfg'
    
    Write-Output "Configuring the MMA..."
    $mma.AddCloudWorkspace($WorkspaceId, $WorkspaceKey)
    $mma.ReloadConfiguration()

} catch {
    # Download the Microsoft monitoring agent
    Write-Output "Downloading and installing the Microsoft Monitoring Agent..."

    # Check whether or not to download the 64-bit executable or the 32-bit executable
    if ([Environment]::Is64BitProcess) {
        $Source = "http://download.microsoft.com/download/1/5/E/15E274B9-F9E2-42AE-86EC-AC988F7631A0/MMASetup-AMD64.exe"
    } else {
        $Source = "http://download.microsoft.com/download/1/5/E/15E274B9-F9E2-42AE-86EC-AC988F7631A0/MMASetup-i386.exe"
    }

    $Destination = "$env:temp\MMASetup.exe"

    $null = Invoke-WebRequest -uri $Source -OutFile $Destination
    $null = Unblock-File $Destination

    # Change directory to location of the downloaded MMA
    cd $env:temp

    # Install the MMA
    $Command = "/C:setup.exe /qn ADD_OPINSIGHTS_WORKSPACE=1 OPINSIGHTS_WORKSPACE_ID=$WorkspaceID" + " OPINSIGHTS_WORKSPACE_KEY=$WorkspaceKey " + " AcceptEndUserLicenseAgreement=1"
    .\MMASetup.exe $Command

}

# Sleep until the MMA object has been registered
Write-Output "Waiting for agent registration to complete..."

# Timeout = 180 seconds = 3 minutes
$i = 18

do {
    
    # Check for the MMA folders
    try {
        # Change the directory to the location of the hybrid registration module
        cd "$env:ProgramFiles\Microsoft Monitoring Agent\Agent\AzureAutomation"
        $version = (ls | Sort-Object LastWriteTime -Descending | Select -First 1).Name
        cd "$version\HybridRegistration"

        # Import the module
        Import-Module (Resolve-Path('HybridRegistration.psd1'))

        # Mark the flag as true
        $hybrid = $true
    } catch{

        $hybrid = $false

    }
    # Sleep for 10 seconds
    Start-Sleep -s 10
    $i--

} until ($hybrid -or ($i -le 0))

if ($i -le 0) {
    throw "The HybridRegistration module was not found. Please ensure the Microsoft Monitoring Agent was correctly installed."
}

# Register the hybrid runbook worker
Write-Output "Registering the hybrid runbook worker..."
Add-HybridRunbookWorker -Name $HybridGroupName -EndPoint $AutomationEndpoint -Token $AutomationPrimaryKey
