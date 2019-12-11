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
 
 1.6 - 12/11/2019
  -- MODIFIED BY Jason Parker
  -- updated to work with Az Module rather than AzureRm Module
  -- added support for non-commercial clouds
  -- removed creation of OMS Workspace as it doesn't support non-commercial clouds
 
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
     intended to be run with administrator privileges and on a machine with WMF 5.1 and requires the Az Module. 
      
     The major steps of the script are outlined below. 
     1) Install the necessary modules (Az v3.0 or greater)
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
  
     LASTEDIT: December 11, 2019
  
     EDITBY: Jason Parker
  
 #>


#Requires -RunAsAdministrator

Param (
# Setup initial variables
[Parameter(Mandatory=$true)]
[String] $AzureEnvironment,

[Parameter(Mandatory=$true)]
[String] $AAResourceGroupName,

[Parameter(Mandatory=$false)]
[String] $OMSResourceGroupName,

[Parameter(Mandatory=$false)]
[String] $SubscriptionID,

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


# Add and update modules on the Automation account
Write-Output "Importing necessary modules..."

try {
    If (-Not ([security.principal.windowsprincipal][security.principal.windowsidentity]::GetCurrent()).IsInRole([security.principal.windowsbuiltinrole] "Administrator")) {
		      Write-Warning "Current PowerShell session is not running as Administrator, modules will be installed for the current user only"
        $IsAdmin =  $false
	   }
	   $IsAdmin = $true

    # Checks for legacy Azure RM PowerShell Module
    If ((Get-InstalledModule -Name AzureRm -ErrorAction SilentlyContinue -Debug:$false)) {
        Write-Warning ("AzureRM Module installed, this cmdlet requires Az Module v3.0 from PSGallery")
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::New(
                [System.SystemException]::New("Invalid Azure Powershell module is installed (AzureRM)"),
                "InvalidPowerShellModule",
                [System.Management.Automation.ErrorCategory]::InvalidResult,
                "AzureRm Module"
            )
        )
    }
    # Checks for current Azure PowerShell Module
    ElseIf (-NOT (Get-InstalledModule -Name Az -MinimumVersion 3.0 -ErrorAction SilentlyContinue -Debug:$false)) {
        Write-Warning ("Missing Azure PowerShell Module (Az), attempting to install...")
        Write-Output "Attempting to install lastest version of Az Module..."

        If ($IsAdmin) {Install-Module -Name Az -MinimumVersion 3.0 -Force -Debug:$false}
        Else {Install-Module -Name Az -MinimumVersion 3.0 -Scope CurrentUser -Force -Debug:$false}

        If (Get-InstalledModule -Name Az -MinimumVersion 3.0 -ErrorAction SilentlyContinue -Debug:$false) {
            Write-Output " Successfully installed Az Module (v3.0 Minimum)..."
        }
        Else {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::New(
                    [System.SystemException]::New("Missing or unable to install correct Azure Powershell module (Az v3.0)"),
                    "MissingPowerShellModule",
                    [System.Management.Automation.ErrorCategory]::InvalidResult,
                    "Az Module"
                )
            )
        }
    }
    Else {
        Write-Verbose ("Azure Powershell Module verified")
        Import-Module -Name Az -MinimumVersion 3.0 -Force -Debug:$false
    }

    # Connect to the current Azure account
    Write-Output "Connecting to Azure..."

    $Account = Connect-AzAccount -Environment $AzureEnvironment -ErrorAction SilentlyContinue -Debug:$false
    If ($SubscriptionID) {
        # Set the active subscription
        $null = Set-AzContext -SubscriptionID $SubscriptionID -Debug:$false
    }
    
    If ($null -eq $Account) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::New(
                [System.SystemException]::New("Error authenticating to Azure, user closed the authentication dialog"),
                "AzureAuthenticationFailed",
                [System.Management.Automation.ErrorCategory]::InvalidResult,
                "Connect-AzAccount"
            )
        )
    }
    Else {Write-Output "Successfully connected to Azure"}
}
catch {$PScmdlet.ThrowTerminatingError($PSItem)}

# Check that the resource groups are valid
$null = Get-AzResourceGroup -Name $AAResourceGroupName
if ($OMSResouceGroupName) {
    $null = Get-AzResourceGroup -Name $OMSResourceGroupName
} else {
    $OMSResourceGroupName = $AAResourceGroupName
}

# Check that the automation account is valid
$AutomationAccount = Get-AzAutomationAccount -ResourceGroupName $AAResourceGroupName -Name $AutomationAccountName

# Find the automation account region
$AALocation = $AutomationAccount.Location

# Print out Azure Automation Account name and region
Write-Output("Accessing Azure Automation Account named $AutomationAccountName in region $AALocation...")

# Get Azure Automation Primary Key and Endpoint
$AutomationInfo = Get-AzAutomationRegistrationInfo -ResourceGroupName $AAResourceGroupName -AutomationAccountName $AutomationAccountName
$AutomationPrimaryKey = $AutomationInfo.PrimaryKey
$AutomationEndpoint = $AutomationInfo.Endpoint

# Create a new OMS workspace if needed
try {

    $Workspace = Get-AzOperationalInsightsWorkspace -Name $WorkspaceName -ResourceGroupName $OMSResourceGroupName  -ErrorAction Stop
    $OmsLocation = $Workspace.Location
    Write-Output "Referencing existing OMS Workspace named $WorkspaceName in region $OmsLocation..."

} catch {$PSCmdlet.ThrowTerminatingError($PSItem)}

# Provide warning if the Automation account and OMS regions are different
if (!($AALocation -match $OmsLocation)) {
    Write-Output "Warning: Your Automation account and OMS workspace are in different regions and will not be compatible for future linking."
}

# Get the workspace ID
$WorkspaceId = $Workspace.CustomerId

# Get the primary key for the OMS workspace
$WorkspaceSharedKeys = Get-AzOperationalInsightsWorkspaceSharedKeys -ResourceGroupName $OMSResourceGroupName -Name $WorkspaceName
$WorkspaceKey = $WorkspaceSharedKeys.PrimarySharedKey

# Activate the Azure Automation solution in the workspace
$null = Set-AzOperationalInsightsIntelligencePack -ResourceGroupName $OMSResourceGroupName -WorkspaceName $WorkspaceName -IntelligencePackName "AzureAutomation" -Enabled $true

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
