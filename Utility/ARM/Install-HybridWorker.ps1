﻿<#

.SYNOPSIS 

    This Azure/OMS Automation runbook onboards a pre-exisiting VM as a hybrid worker. (2/2)


.DESCRIPTION

    This Azure/OMS Automation runbook onboards a hybrid worker.  An OMS workspace will be generated
    if needed. The major steps of the script are outlined below.

    1) Login to an Azure account
    2) Create reference to the VM 
    3) Create an OMS Workspace if needed
    4) Enable the Azure Automation solution in OMS
    5) Download the DSC agent
    6) Submit the configuration to register the machine as a hybrid worker


.PARAMETER ResourceGroup

    Mandatory. The name of the resource group of the automation account to be referenced.



.PARAMETER AutomationAccountName

    Mandatory. The name of the automation account to be referenced.



.PARAMETER VMName

    Mandatory. The computer name of the Azure VM to be referenced.



.PARAMETER VMResourceGroup

    Mandatory. The resource group of the Azure VM to be referenced.



.PARAMETER WorkspaceName

    Mandatory. The name of the OMS Workspace to be referenced.




.PARAMETER OmsLocation

    Mandatory. The region of the OMS Workspace to be referenced.



.EXAMPLE

    Install-HybridWorker -MachineName "ContosoVM" -ResourceGroup "ContosoResources" -AutomationAccountName "ContosoAA" -WorkspaceName "ContosoSpace" -OmsLocation "westeurope"


.NOTES

    AUTHOR: Jenny Hunter, Azure/OMS Automation Team

    LASTEDIT: August 7, 2017  

#>

Param (
# Resource Group
[Parameter(Mandatory=$true)]
[String] $ResourceGroup,

# Automation Account
[Parameter(Mandatory=$true)]
[String] $AutomationAccountName,

# VM
[Parameter(Mandatory=$true)]
[String] $VmName,

# VM
[Parameter(Mandatory=$true)]
[String] $VmResourceGroup,

# OMS Workspace
[Parameter(Mandatory=$true)]
[String] $WorkspaceName,

# OMS Workspace Region
[Parameter(Mandatory=$true)]
[String] $OmsLocation
)

# Stop the runbook if any errors occur
$ErrorActionPreference = "Stop"

Write-Output "Pulling account credentials..."

# Connect to the current Azure account
$Conn = Get-AutomationConnection -Name AzureRunAsConnection 
$null = Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationID $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint 

# Get the subscription and tenant IDs
$SubscriptionID = $Conn.SubscriptionID
$TenantID = $Conn.TenantID

# Set the active subscription
$null = Set-AzureRmContext -SubscriptionID $SubscriptionID

# Get Azure Automation Primary Key and Endpoint
$AutomationInfo = Get-AzureRMAutomationRegistrationInfo -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName
$AutomationPrimaryKey = $AutomationInfo.PrimaryKey
$AutomationEndpoint = $AutomationInfo.Endpoint

# Retrieve OperationalInsights cmdlets
try {
    $null = Get-Command New-AzureRmOperationalInsightsWorkspace -CommandType Cmdlet -ErrorAction Stop
    Write-Output "OMS cmdlets successfully retrieved."
} catch {
    Write-Error "Could not retrieve OMS cmdlets."
}

# Create a reference to the VM
$VM = Get-AzureRmVM -ResourceGroupName $VmResourceGroup -Name $VmName -ErrorAction Stop

# Create a new OMS workspace if needed
Write-Output "Acquiring OMS workspace..."

try {
    $Workspace = Get-AzureRmOperationalInsightsWorkspace -Name $WorkspaceName -ResourceGroupName $ResourceGroup -ErrorAction Stop
} catch {
    # Create the new workspace for the given name, region, and resource group
    $Workspace = New-AzureRmOperationalInsightsWorkspace -Location $OmsLocation -Name $WorkspaceName -Sku Standard -ResourceGroupName $ResourceGroup -WarningAction SilentlyContinue
}

# Get the workspace ID
$WorkspaceId = $Workspace.CustomerId

# Get the primary key for the OMS workspace
$WorkspaceSharedKeys = Get-AzureRmOperationalInsightsWorkspaceSharedKeys -ResourceGroupName $ResourceGroup -Name $WorkspaceName
$WorkspaceKey = $WorkspaceSharedKeys.PrimarySharedKey

# Create automation variables for the workspace id and key
try {
    $null = Get-AzureRmAutomationVariable -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -Name "HybridWorkspaceKey"
    $null = Get-AzureRmAutomationVariable -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -Name "HybridWorkspaceId"
} catch {
    $null = New-AzureRmAutomationVariable -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Name "HybridWorkspaceKey" -Value $WorkspaceKey -Encrypted $True
    $null = New-AzureRmAutomationVariable -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Name "HybridWorkspaceId" -Value $WorkspaceId -Encrypted $True
}

# Activate the Azure Automation solution in the workspace
Write-Output "Activating Automation solution in OMS..."
$null = Set-AzureRmOperationalInsightsIntelligencePack -ResourceGroupName $ResourceGroup -WorkspaceName $WorkspaceName -IntelligencePackName "AzureAutomation" -Enabled $true


# Register the VM as a DSC node if needed
Write-Output "Registering DSC Node..."
   
$null = Register-AzureRmAutomationDscNode -AutomationAccountName $AutomationAccountName -AzureVMName $VmName -ResourceGroupName $ResourceGroup -AzureVMLocation $VM.Location -AzureVMResourceGroup $VM.ResourceGroupName


# Get a reference to the DSC node
$DscNode = Get-AzureRmAutomationDscNode -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -Name $VmName
    
# Create credential paramters for the DSC configuration
$DscPassword = ConvertTo-SecureString $AutomationPrimaryKey -AsPlainText -Force
$DscCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList "User", $DscPassword
    
# Make an automation credential if needed
try {
    $AutomationCredential = Get-AzureRmAutomationCredential -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -Name "TokenCredential" -ErrorAction Stop
} catch {
    $AutomationCredential = New-AzureRmAutomationCredential -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -Name "TokenCredential" -Value $DscCredential
}

# Create a hashtable of paramters for the DSC configuration
$ConfigParameters = @{
    "AutomationEndpoint" = $AutomationEndpoint
    "HybridGroupName" = $VmName
}

# Use configuration data to bypass storing credentials as plain text
$ConfigData = @{
    AllNodes = @(
        @{
            NodeName = 'HybridVM'
            PSDscAllowPlainTextPassword = $true

        }
    )
} 

    
# Download the DSC configuration file
$Source =  "https://raw.githubusercontent.com/azureautomation/runbooks/master/Utility/ARM/HybridRunbookWorkerConfiguration.ps1"
$Destination = "$env:temp\HybridRunbookWorkerConfiguration.ps1"

$null = Invoke-WebRequest -uri $Source -OutFile $Destination
$null = Unblock-File $Destination


# Import the DSC configuration to the automation account
Write-Output "Importing Hybrid Worker DSC file..."
$null = Import-AzureRmAutomationDscConfiguration -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -SourcePath $Destination -Published -Force


# Compile the DSC configuration
Write-Output "Compiling DSC Job..."
$CompilationJob = Start-AzureRmAutomationDscCompilationJob -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -ConfigurationName "HybridRunbookWorkerConfiguration" -Parameters $ConfigParameters -ConfigurationData $ConfigData

while($CompilationJob.EndTime –eq $null -and $CompilationJob.Exception –eq $null)           
{
    $CompilationJob = $CompilationJob | Get-AzureRmAutomationDscCompilationJob
    Start-Sleep -Seconds 3
}
  
# Configure the DSC node
Write-Output "Setting the configuration for the DSC node..."
$null = Set-AzureRmAutomationDscNode -ResourceGroupName $ResourceGroup  -NodeConfigurationName "HybridRunbookWorkerConfiguration.HybridVM" -Id $DscNode.Id -AutomationAccountName $AutomationAccountName -Force

Write-Output "Complete: Please wait one configuration cycle (approximately 30 minutes) for the DSC configuration to be pulled from the server and the Hybrid Worker Group to be created."
