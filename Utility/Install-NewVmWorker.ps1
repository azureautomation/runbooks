<#

.SYNOPSIS 

    This Azure/OMS Automation runbook onboards a hybrid worker.


.DESCRIPTION

    This Azure/OMS Automation runbook onboards a hybrid worker. The major steps of the script are outlined below.
    
    1) Login to an Azure account
    2) Create an OMS Workspace if needed
    3) Enable the Azure Automation solution in OMS
    4) Create a new VM 
    5) Download the DSC agent
    6) Submit the configuration to register the machine as a hybrid worker


.PARAMETER ResourceGroup

    Mandatory. The name of the resource group to be referenced.



.PARAMETER AutomationAccountName

    Mandatory. The name of the automation account to be referenced.



.PARAMETER MachineName

    Mandatory. The computer name (Azure VM or on-premise) to be referenced.



.PARAMETER WorkspaceName

    Mandatory. The name of the OMS Workspace to be referenced.



.PARAMETER Location

    Mandatory. The region of the OMS workspace and VM to be referenced.


.PARAMETER VMUser

    Mandatory. The username for the provided user machine. 


.PARAMETER VMPassword

   Mandatory. The password for the provided user on the machine.


.PARAMETER AvailabilityName

    Mandatory. The name of the Availability set to be referenced.


.PARAMETER StorageName

    Mandatory. The name of the Storage account to be referenced. 


.PARAMETER OSDiskName

    Mandatory. The name of the OS Disk to be referenced.


.PARAMETER VNetName

    Mandatory. The name of the virtual network to be referenced. 


.PARAMETER PIpName

    Mandatory. The Public IP address name to be referenced.


.PARAMETER InterfaceName

    Mandatory. The name of the network interface to be referenced. 


.NOTES

    AUTHOR: Jenny Hunter, Azure/OMS Automation Team

    LASTEDIT: September 19, 2016  

#>

Param (
# Resource Group
[Parameter(Mandatory=$true)]
[String] $ResourceGroup,

# Automation Account
[Parameter(Mandatory=$true)]
[String] $AutomationAccountName,

# OMS Workspace
[Parameter(Mandatory=$true)]
[String] $WorkspaceName,

[Parameter(Mandatory=$true)]
[String] $Location,

# VM
[Parameter(Mandatory=$true)]
[String] $MachineName,

[Parameter(Mandatory=$true)]
[String] $VMUser,

[Parameter(Mandatory=$true)]
[String] $VMPassword,

[Parameter(Mandatory=$true)]
[String] $AvailabilityName,

[Parameter(Mandatory=$true)]
[String] $StorageName,

[Parameter(Mandatory=$true)]
[String] $OSDiskName,

[Parameter(Mandatory=$true)]
[String] $VNetName,

[Parameter(Mandatory=$true)]
[String] $PIpName,

[Parameter(Mandatory=$true)]
[String] $InterfaceName
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

# Create a new OMS workspace if needed
Write-Output "Acquiring OMS workspace..."

try {
    $Workspace = Get-AzureRmOperationalInsightWorkspace -Name $WorkspaceName -ResourceGroupName $ResourceGroup -Force -ErrorAction Stop
} catch {
    # Create the new workspace for the given name, region, and resource group
    $Workspace = New-AzureRmOperationalInsightsWorkspace -Location $Location -Name $WorkspaceName -Sku Standard -ResourceGroupName $ResourceGroup -Force -WarningAction SilentlyContinue
}

# Get the workspace ID
$WorkspaceId = $Workspace.CustomerId

# Get the primary key for the OMS workspace
$WorkspaceSharedKeys = Get-AzureRmOperationalInsightsWorkspaceSharedKeys -ResourceGroupName $ResourceGroup -Name $WorkspaceName
$WorkspaceKey = $WorkspaceSharedKeys.PrimarySharedKey

# Activate the Azure Automation solution in the workspace
Write-Output "Activating Automation solution in OMS..."
$null = Set-AzureRmOperationalInsightsIntelligencePack -ResourceGroupName $ResourceGroup -WorkspaceName $WorkspaceName -IntelligencePackName "AzureAutomation" -Enabled $true



# Create a new VM
Write-Output "Creating a new VM..."
# Convert the vm password to a secure string
$VMSecurePassword = ConvertTo-SecureString $VMPassword -AsPlainText -Force
# Create a credential with the username and password
$VMCredential = New-Object System.Management.Automation.PSCredential ($VMUser, $VMSecurePassword);

# Create a new availability set if needed
try {

    $AvailabilitySet = Get-AzureRmAvailabilitySet -ResourceGroupName $ResourceGroup -Name $AvailabilityName -ErrorAction Stop
} catch {

    $AvailabilitySet = New-AzureRmAvailabilitySet -ResourceGroupName $ResourceGroup -Name $AvailabilityName -Location $Location -WarningAction SilentlyContinue 
}
    
# Create a new VM configurable object
$VM = New-AzureRmVMConfig -VMName $MachineName -VMSize "Standard_A1" -AvailabilitySetID $AvailabilitySet.Id
    
# Set the Operating System for the new VM
$VM = Set-AzureRmVMOperatingSystem -VM $VM -Windows -Credential $VMCredential -ComputerName $MachineName
$VM = Set-AzureRmVMSourceImage -VM $VM -PublisherName MicrosoftWindowsServer -Offer WindowsServer -Skus 2012-R2-Datacenter -Version "latest"

# Storage - create a new storage accounot if needed
try {

    $StorageAccount = Get-AzureRmStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageName -ErrorAction Stop
} catch {

    $StorageAccount = New-AzureRmStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageName -Type "Standard_LRS" -Location $Location -WarningAction SilentlyContinue
}

#Network - create new network attributes if needed
try {

    $PIp = Get-AzureRmPublicIpAddress -Name $PIpName -ResourceGroupName $ResourceGroup -ErrorAction Stop
} catch {

    $PIp = New-AzureRmPublicIpAddress -Name $PIpName -ResourceGroupName $ResourceGroup -Location $Location -AllocationMethod Dynamic -WarningAction SilentlyContinue
}

try {

    $SubnetConfig = Get-AzureRmVirtualNetworkSubnetConfig -Name "default" -VirtualNetwork $VNetName -ErrorAction Stop
} catch {

    $SubnetConfig = New-AzureRmVirtualNetworkSubnetConfig -Name "default" -AddressPrefix "10.0.0.0/24" -WarningAction SilentlyContinue
}

try {

    $VNet = Get-AzureRmVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroup -ErrorAction Stop
} catch {

    $VNet = New-AzureRmVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroup -Location $Location -AddressPrefix "10.0.0.0/16" -Subnet $SubnetConfig -WarningAction SilentlyContinue
}

try {
    $Interface = Get-AzureRmNetworkInterface -Name $InterfaceName -ResourceGroupName $ResourceGroup -SubnetId $VNet.Subnets[0].Id -PublicIpAddressId $PIp.Id -ErrorAction Stop
} catch {

    $Interface = New-AzureRmNetworkInterface -Name $InterfaceName -ResourceGroupName $ResourceGroup -Location $Location -SubnetId $VNet.Subnets[0].Id -PublicIpAddressId $PIp.Id -WarningAction SilentlyContinue
}
   
$VM = Add-AzureRmVMNetworkInterface -VM $VM -Id $Interface.Id

# Setup local VM Object
$OSDiskUri = $StorageAccount.PrimaryEndpoints.Blob.ToString() + "vhds/" + $OSDiskName + ".vhd"
$VM = Set-AzureRmVMOSDisk -VM $VM -Name $OSDiskName -VhdUri $OSDiskUri -CreateOption FromImage

# Create the new VM
New-AzureRmVM -ResourceGroupName $ResourceGroup -Location $Location -VM $VM -WarningAction SilentlyContinue


# Enable the MMAgent extension if needed
Write-Output "Acquiring the VM monitoring agent..."
try {

    $null = Get-AzureRMVMExtension -ResourceGroupName $ResourceGroup -VMName $MachineName -Name 'MicrosoftMonitoringAgent' -ErrorAction Stop
} catch {

    $null = Set-AzureRMVMExtension -ResourceGroupName $ResourceGroup -VMName $MachineName -Name 'MicrosoftMonitoringAgent' -Publisher 'Microsoft.EnterpriseCloud.Monitoring' -ExtensionType 'MicrosoftMonitoringAgent' -TypeHandlerVersion '1.0' -Location $Location -SettingString "{'workspaceId':  '$workspaceId'}" -ProtectedSettingString "{'workspaceKey': '$workspaceKey' }"

}

# Register the VM as a DSC node if needed
Write-Output "Registering the DSC Node..."
try {
        
    $null = Register-AzureRmAutomationDscNode -AutomationAccountName $AutomationAccountName -AzureVMName $MachineName -ResourceGroupName $ResourceGroup -ErrorAction Stop
          
} catch {}

# Get a reference to the DSC node
$DscNode = Get-AzureRmAutomationDscNode -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -Name $MachineName
    
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
    "HybridGroupName" = $MachineName
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
$Source =  "https://raw.githubusercontent.com/azureautomation/runbooks/jhunter-msft-dev/Utility/HybridWorkerConfiguration.ps1"
$Destination = "$env:temp\HybridWorkerConfiguration.ps1"

$null = Invoke-WebRequest -uri $Source -OutFile $Destination
$null = Unblock-File $Destination


# Import the DSC configuration to the automation account
Write-Output "Importing Hybird Worker DSC file..."
$null = Import-AzureRmAutomationDscConfiguration -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -SourcePath $Destination -Published -Force


# Compile the DSC configuration
$CompilationJob = Start-AzureRmAutomationDscCompilationJob -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -ConfigurationName "HybridWorkerConfiguration" -Parameters $ConfigParameters -ConfigurationData $ConfigData

Write-Output "Compiling DSC Job..."

while($CompilationJob.EndTime –eq $null -and $CompilationJob.Exception –eq $null)           
{
    $CompilationJob = $CompilationJob | Get-AzureRmAutomationDscCompilationJob
    Start-Sleep -Seconds 3
}
  
# Configure the DSC node
Write-Output "Setting the configuration for the DSC node..."
$null = Set-AzureRmAutomationDscNode -ResourceGroupName $ResourceGroup  -NodeConfigurationName "HybridWorkerConfiguration.HybridVM" -Id $DscNode.Id -AutomationAccountName $AutomationAccountName -Force

Write-Output "Complete: Please wait one configuration cycle (approximately 30 minutes) for the DSC configuration to be pulled from the server and the Hybrid Worker Group to be created."