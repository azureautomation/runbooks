<#

.SYNOPSIS 

    This Azure/OMS Automation runbook onboards a hybrid worker. A resource group, automation account, OMS workspace, 
    and VM will all be generated if needed.


.DESCRIPTION

    This Azure/OMS Automation runbook onboards a hybrid worker. A resource group, automation account, OMS workspace,
    and VM will all be generated if needed. The major steps of the script are outlined below.
    
    1) Login to an Azure account
    2) Create a resource group if needed
    3) Create and configure an Automaiton Account if needed
    4) Create an OMS Workspace if needed
    5) Enable the Azure Automation solution in OMS
    6) Check if the machine provided was flagged as an on-premise device
        a) If not, create and configure a VM if needed
    7) Download the DSC agent
    8) Submit the configuration to register the machine as a hybrid worker


.PARAMETER IDString

    Optional. A string added to newly generated resources to create unique identifiers. If not specified,

    a random number (Maximum of 99999) is used.

 
.PARAMETER ResourceGroup

    Optional. The name of the resource group to be referenced. If not specified, a new resource group

    is created, referencing the IDString in order to create a unique identifier.


.PARAMETER SubscriptionID

    Optional. A string containing the SubscriptionID to be used. If not specified, the first subscriptionID

    associated with the account is used.


.PARAMETER WorkspaceName

    Optional. The name of the OMS Workspace to be referenced. If not specified, a new OMS workspace 

    is created, referencing the IDString in order to create a unique identifier.


.PARAMETER Location

    Optional. The region of the OMS workspace and VM to be referenced. If not specified, "westeurope" is used.


.PARAMETER AutomationAccountName

    Optional. The name of the Automation account to be referenced. If not specified, a new automation account 

    is created, referencing the IDString in order to create a unique identifier.


.PARAMETER ApplicationDisplayName

    Optional. The name of the Application Display to be referenced. If not specified, a new application 

    is created with the AutomationAccountName as the name.


.PARAMETER CertPlainPassword

    Optional. The password for the AzureRunAs certificate. If not specified,"p@ssw0rdHybrid" is used.


.PARAMETER NoOfMonthsUntilExpired

    Optional. The number of months until the Automation key credential expires. If not specified, 12 is used.


.PARAMETER OnPremise

    Optional. A boolean to flag the provided machine as an on-premise device. If not specified, the value is

    set to false, and the machine is assumed to be an Azure VM.


.PARAMETER MachineName

    Optional. The computer name (Azure VM or on-premise) to be referenced. If not specified, a computer name

    is created, referencing the IDString in order to create a unique identifier.


.PARAMETER VMUser

    Optional. The username for the provided user machine. If not specified,"hybridUser" is used.


.PARAMETER VMPassword

    Optional. The password for the provided user on the machine. If not specified,"p@ssw0rdHybrid" is used.


.PARAMETER AvailabilityName

    Optional. The name of the Availability set to be referenced. If not specified, a new availability set 

    is created, referencing the IDString in order to create a unique identifier.


.PARAMETER StorageName

    Optional. The name of the Storage account to be referenced. If not specified, a new storage account 

    is created, referencing the IDString in order to create a unique identifier.


.PARAMETER OSDiskName

    Optional. The name of the OS Disk to be referenced. If not specified, a new OS Disk is created, 

    referencing the IDString in order to create a unique identifier.


.PARAMETER VNetName

    Optional. The name of the virtual network to be referenced. If not specified, a new virtual network

    is created with the Resource Group name as the virtal network name.


.PARAMETER PIpName

    Optional. The Public IP address name to be referenced. If not specified, a new public IP address is 

    created with the Resource Group name as the public IP address name.


.PARAMETER InterfaceName

    Optional. The name of the network interface to be referenced. If not specified, a new interface is

    created with the Resource Group name as the network interface name.


.EXAMPLE

    New-HybridWorker

    New-HybridWorker -IDString 12345


.NOTES

    AUTHOR: Jennifer Hunter, Azure/OMS Automation Team

    LASTEDIT: August 18, 2016  

#>


#Requires -RunAsAdministrator

Param (
# Setup initial variables
[Parameter(Mandatory=$false)]
#[String] $IDString = "56396",
[String] $IDString = (Get-Random -Maximum 99999),

[Parameter(Mandatory=$false)]
[String] $ResourceGroup = "hybrid-worker-" + $IDstring,

[Parameter(Mandatory=$false)]
#[String] $SubscriptionID = "",
[String] $SubscriptionID = "c9d8154e-9f57-47a9-8871-1f9b29fe2199",

# OMS Workspace
[Parameter(Mandatory=$false)]
[String] $WorkspaceName = "hybrid-worker-" + $IDstring,

[Parameter(Mandatory=$false)]
[String] $Location = "westeurope",

# Automation
[Parameter(Mandatory=$false)]
[String] $AutomationAccountName = "hybrid-worker-AA-" + $IDstring,

[Parameter(Mandatory=$false)]
[String] $ApplicationDisplayName = $AutomationAccountName,

[Parameter(Mandatory=$false)]
[String] $CertPlainPassword = "p@ssw0rdHybrid",

[Parameter(Mandatory=$false)]
[int] $NoOfMonthsUntilExpired = 12,

# VM
[Parameter(Mandatory=$false)]
[Boolean] $OnPremise = $false,

[Parameter(Mandatory=$false)]
[String] $MachineName = "hybridVM" + $IDstring,

[Parameter(Mandatory=$false)]
[String] $VMUser = "hybridUser",

[Parameter(Mandatory=$false)]
[String] $VMPassword = "p@ssw0rdHybrid",

[Parameter(Mandatory=$false)]
[String] $AvailabilityName = "hybrid-worker-availability-" + $IDstring,

[Parameter(Mandatory=$false)]
[String] $StorageName = "hybridworkerstorage" + $IDstring,

[Parameter(Mandatory=$false)]
[String] $OSDiskName = $MachineName + "OSDisk",

[Parameter(Mandatory=$false)]
[String] $VNetName = $ResourceGroup,

[Parameter(Mandatory=$false)]
[String] $PIpName = $ResourceGroup,

[Parameter(Mandatory=$false)]
[String] $InterfaceName = $ResourceGroup
)

# Parameter adjustment
$VMSecurePassword = ConvertTo-SecureString $VMPassword -AsPlainText -Force;
$VMCredential = New-Object System.Management.Automation.PSCredential ($VMUser, $VMSecurePassword);

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


Set-AzureRmContext -SubscriptionID $SubscriptionID

# Create the resource group if needed
try {

    Get-AzureRmResourceGroup -Name $ResourceGroup -ErrorAction Stop
} catch {

    New-AzureRmResourceGroup -Name $ResourceGroup -Location $Location -WarningAction SilentlyContinue
}

#Create a new automation account if needed 
try {

    Get-AzureRmAutomationAccount -ResourceGroupName $ResourceGroup -Name $AutomationAccountName -ErrorAction Stop
} catch {

    New-AzureRmAutomationAccount -Name $AutomationAccountName -Location $Location -ResourceGroupName $ResourceGroup -Plan "Free" -WarningAction SilentlyContinue
}

# Check if the account is configured as a runAs account
$ConnectionAssetName = "AzureRunAsConnection"

try {
    $ServicePrincipalConnection = Get-AzureRmAutomationConnection -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -Name $ConnectionAssetName -ErrorAction Stop
} catch {    
    # Configure the Automation account as a RunAs account
    $CurrentDate = Get-Date
    $EndDate = $CurrentDate.AddMonths($NoOfMonthsUntilExpired)
    $KeyId = (New-Guid).Guid
    $CertPath = Join-Path $env:TEMP ($ApplicationDisplayName + ".pfx")

    $Cert = New-SelfSignedCertificate -DnsName $ApplicationDisplayName -CertStoreLocation cert:\LocalMachine\My -KeyExportPolicy Exportable -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider"

    $CertPassword = ConvertTo-SecureString $CertPlainPassword -AsPlainText -Force
    Export-PfxCertificate -Cert ("Cert:\localmachine\my\" + $Cert.Thumbprint) -FilePath $CertPath -Password $CertPassword -Force | Write-Verbose

    $PFXCert = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate -ArgumentList @($CertPath, $CertPlainPassword)
    $KeyValue = [System.Convert]::ToBase64String($PFXCert.GetRawCertData())

    $KeyCredential = New-Object  Microsoft.Azure.Commands.Resources.Models.ActiveDirectory.PSADKeyCredential
    $KeyCredential.StartDate = $CurrentDate
    $KeyCredential.EndDate= $EndDate
    $KeyCredential.KeyId = $KeyId
    $KeyCredential.Type = "AsymmetricX509Cert"
    $KeyCredential.Usage = "Verify"
    $KeyCredential.Value = $KeyValue

    # Use Key credentials
    $Application = New-AzureRmADApplication -DisplayName $ApplicationDisplayName -HomePage ("http://" + $ApplicationDisplayName) -IdentifierUris ("http://" + $KeyId) -KeyCredentials $keyCredential

    New-AzureRMADServicePrincipal -ApplicationId $Application.ApplicationId | Write-Verbose 
    Get-AzureRmADServicePrincipal | Where {$_.ApplicationId -eq $Application.ApplicationId} | Write-Verbose

    $NewRole = $null
    $Retries = 0;
    while ($NewRole -eq $null -and $Retries -le 2)
    {

      # Sleep here for a few seconds to allow the service principal application to become active (should only take a couple of seconds normally)
      Sleep 5
      New-AzureRMRoleAssignment -RoleDefinitionName Contributor -ServicePrincipalName $Application.ApplicationId | Write-Verbose -ErrorAction SilentlyContinue
      Sleep 5
      $NewRole = Get-AzureRMRoleAssignment -ServicePrincipalName $Application.ApplicationId -ErrorAction SilentlyContinue
      $Retries++;
    }

    # Create the automation resources if needed
    try {

        Get-AzureRmAutomationCertificate -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName
    } catch {

        New-AzureRmAutomationCertificate -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -Path $CertPath -Name AzureRunAsCertificate -Password $CertPassword -Exportable | write-verbose -WarningAction SilentlyContinue
    }

    # Create a Automation connection asset named AzureRunAsConnection in the Automation account. This connection uses the service principal.

    Remove-AzureRmAutomationConnection -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -Name $ConnectionAssetName -Force -ErrorAction SilentlyContinue
    $ConnectionFieldValues = @{"ApplicationId" = $Application.ApplicationId; "TenantId" = $TenantID; "CertificateThumbprint" = $Cert.Thumbprint; "SubscriptionId" = $SubscriptionId}
    $AzureRunAsConnetion = 
    $ServicePrincipalConnection = New-AzureRmAutomationConnection -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -Name $ConnectionAssetName -ConnectionTypeName AzureServicePrincipal -ConnectionFieldValues $ConnectionFieldValues
}

# Get Azure Automation Primary Key and Endpoint
$AutomationInfo = Get-AzureRMAutomationRegistrationInfo -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName
$AutomationPrimaryKey = $AutomationInfo.PrimaryKey
$AutomationEndpoint = $AutomationInfo.Endpoint

# Create a new OMS workspace if needed
try {
    $Workspace = Get-AzureRmOperationalInsightWorkspace -Name $WorkspaceName -ResourceGroupName $ResourceGroup -ErrorAction Stop
} catch {
    # Create the new workspace for the given name, region, and resource group
    $Workspace = New-AzureRmOperationalInsightsWorkspace -Location $Location -Name $WorkspaceName -Sku Standard -ResourceGroupName $ResourceGroup -WarningAction SilentlyContinue
}

# Get the workspace ID
$WorkspaceId = $Workspace.CustomerId

# Get the primary key for the OMS workspace
$WorkspaceSharedKeys = Get-AzureRmOperationalInsightsWorkspaceSharedKeys -ResourceGroupName $ResourceGroup -Name $WorkspaceName
$WorkspaceKey = $WorkspaceSharedKeys.PrimarySharedKey

# Activate the Azure Automation solution in the workspace
Set-AzureRmOperationalInsightsIntelligencePack -ResourceGroupName $ResourceGroup -WorkspaceName $WorkspaceName -IntelligencePackName "AzureAutomation" -Enabled $true

# Check if the machine was flagged as an on-premise device
if (!$OnPremise) {
# Create a new VM if needed
    try {
        $VM = Get-AzureRmVM -ResourceGroupName $ResourceGroup -Name $MachineName -ErrorAction Stop
    } catch {
    
        # Create a new availability set if needed
        try {

            $AvailabilitySet = Get-AzureRmAvailabilitySet -ResourceGroupName $ResourceGroup -Name $AvailabilityName -ErrorAction Stop
        } catch {

            $AvailabilitySet = New-AzureRmAvailabilitySet -ResourceGroupName $ResourceGroup -Name $AvailabilityName -Location $Location -WarningAction SilentlyContinue 
        }
    
        # Create a new VM configurable object
        $VM = New-AzureRmVMConfig -VMName $MachineName -VMSize "Standard_A1" -AvailabilitySetID $AvailabilitySet.Id
    
        # Set the Operating System for the new VM
        # Create a new Windows VM
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
    }

    # Enable the MMAgent extension if needed
    try {

        Get-AzureRMVMExtension -ResourceGroupName $ResourceGroup -VMName $MachineName -Name 'MicrosoftMonitoringAgent' -ErrorAction Stop
    } catch {

        Set-AzureRMVMExtension -ResourceGroupName $ResourceGroup -VMName $MachineName -Name 'MicrosoftMonitoringAgent' -Publisher 'Microsoft.EnterpriseCloud.Monitoring' -ExtensionType 'MicrosoftMonitoringAgent' -TypeHandlerVersion '1.0' -Location $location -SettingString "{'workspaceId':  '$workspaceId'}" -ProtectedSettingString "{'workspaceKey': '$workspaceKey' }"

    }


    # Register the VM as a DSC node if needed
    try {
        
        Register-AzureRmAutomationDscNode -AutomationAccountName $AutomationAccountName -AzureVMName $MachineName -ResourceGroupName $ResourceGroup -ErrorAction Stop
          
    } catch {}

    $DscNode = Get-AzureRmAutomationDscNode -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -Name $MachineName


    # Install necessary modules
    Install-Module HybridRunbookWorker
    Import-Module Azure

    # Create a hashtable of paramters for the DSC configuration
    $ConfigParameters = @{
        "Endpoint" = $AutomationEndpoint
        "Token" = $AutomationPrimaryKey
        "GroupName" = $MachineName
    }

    # Import the DSC configuration to the automation account
    Import-AzureRmAutomationDscConfiguration -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -SourcePath "C:\Users\jehunte\Documents\GitHub\runbooks\Utility\HybridWorkerConfiguration.ps1" -Published -Force

    # Compile the DSC configuration
    try {
        $CompilationJob = Start-AzureRmAutomationDscCompilationJob -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -ConfigurationName "HybridWorkerConfiguration" -Parameters $ConfigParameters -ErrorAction Stop
    
        while($CompilationJob.EndTime –eq $null -and $CompilationJob.Exception –eq $null)           
        {
            $CompilationJob = $CompilationJob | Get-AzureRmAutomationDscCompilationJob
            Start-Sleep -Seconds 3
        }
    
    } catch {}

    
    # Configure the DSC node
    Set-AzureRmAutomationDscNode -ResourceGroupName $ResourceGroup  -NodeConfigurationName "HybridWorkerConfiguration" -Id $DscNode.Id -AutomationAccountName $AutomationAccountName -Force

    # Update the configuration of an Azure Virtual Machine
    Update-AzureRmVM -ResourceGroupName $ResourceGroup -Location $Location -VM $VM -Verbose

    # Check on status
    Get-AzureRmVMDscExtensionStatus -VM $VM -ResourceGroupName $ResourceGroup -Verbose 

} else {
    # Do same things but for on-premise machines
}