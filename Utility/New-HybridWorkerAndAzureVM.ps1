<#

.SYNOPSIS 

    This Azure/OMS Automation runbook onboards a hybrid worker. A resource group, automation account, OMS workspace, 
    and VM will all be generated if needed.


.DESCRIPTION

    This Azure/OMS Automation runbook onboards a hybrid worker. A resource group, automation account, OMS workspace,
    and VM will all be generated if needed. The major steps of the script are outlined below.
    
    1) Login to an Azure account
    2) Import/Update the necessary modules
    3) Create a VM
    3) Import Install-HybridWorker for next steps


.PARAMETER IDString

    Optional. A string added to newly generated resources to create unique identifiers. If not specified,

    a random number (Maximum of 99999) is used.

 
.PARAMETER WorkspaceName

    Optional. The name of the OMS Workspace to be referenced. If not specified, a new OMS workspace 

    is created, referencing the IDString in order to create a unique identifier.


.PARAMETER Location

    Optional. The region of the OMS workspace, Automation account, and VM to be referenced. If not specified,
    
    "westeurope" is used.


.PARAMETER MachineName

    Optional. The computer name (Azure VM or on-premise) to be referenced. If not specified, a computer name

    is created, referencing the IDString in order to create a unique identifier.


.PARAMETER VMUser

    Optional. The username for the provided user machine. If not specified,"hybridUser" is used.


.PARAMETER VMPassword

    Optional. The password for the provided user on the machine. If not specified,"p@ssw0rdHybrid" is used.


.PARAMETER AvailabilityName

    Optional. The name of the Availability set to be referenced. If not specified, a new availability set 

    is created, referencing the VM name and IDString in order to create a unique identifier.


.PARAMETER StorageName

    Optional. The name of the Storage account to be referenced. If not specified, a new storage account 

    is created, referencing the vm name and IDString in order to create a unique identifier.


.PARAMETER OSDiskName

    Optional. The name of the OS Disk to be referenced. If not specified, a new OS Disk is created 

    with the VM name and "-osdisk" as the os disk name.


.PARAMETER VNetName

    Optional. The name of the virtual network to be referenced. If not specified, a new virtual network

    is created with the VM name and "-vnet" as the virtal network name.


.PARAMETER PIpName

    Optional. The Public IP address name to be referenced. If not specified, a new public IP address is 

    created with the VM name and "-ip" as the public IP address name.


.PARAMETER InterfaceName

    Optional. The name of the network interface to be referenced. If not specified, a new interface is

    created, referencing the vm name and IDString in order to create a unique identifier.


.EXAMPLE

    New-HybridWorker

    New-HybridWorker -WorkspaceName "ContosoWorkspace"


.NOTES

    AUTHOR: Jennifer Hunter, Azure/OMS Automation Team

    LASTEDIT: September 19, 2016  

#>

Param (
    # Setup base identifier variable
    [Parameter(Mandatory=$false)]
    [String] $IDString = (Get-Random -Maximum 99999),

    # OMS Workspace
    [Parameter(Mandatory=$false)]
    [String] $WorkspaceName = "hybrid-worker-" + $IDstring,

    [Parameter(Mandatory=$false)]
    [String] $Location = "westeurope",

    # VM
    [Parameter(Mandatory=$false)]
    [String] $MachineName = "hybridVM" + $IDstring,

    [Parameter(Mandatory=$false)]
    [String] $VMUser = "hybridUser",

    [Parameter(Mandatory=$false)]
    [String] $VMPassword = "p@ssw0rdHybrid",

    [Parameter(Mandatory=$false)]
    [String] $AvailabilityName = $MachineName + "-availability" + $IDstring,

    [Parameter(Mandatory=$false)]
    [String] $StorageName = $MachineName + "disks" + $IDstring,

    [Parameter(Mandatory=$false)]
    [String] $OSDiskName = $MachineName + "osdisk",

    [Parameter(Mandatory=$false)]
    [String] $VNetName = $MachineName + "-vnet",

    [Parameter(Mandatory=$false)]
    [String] $PIpName = $MachineName + "-ip",

    [Parameter(Mandatory=$false)]
    [String] $InterfaceName = $MachineName + $IDString
)

# Parameter adjustment
$VMSecurePassword = ConvertTo-SecureString $VMPassword -AsPlainText -Force;
$VMCredential = New-Object System.Management.Automation.PSCredential ($VMUser, $VMSecurePassword);

# Stop the runbook if any errors occur
$ErrorActionPreference = "Stop"

# Check that the provided region is a supported OMS region
$validRegions = "westeurope", "southeastasia"
if ($validRegions -notcontains $Location) {
    throw "Currently, only the West Europe and Southeast Asia regions are supported for both OMS and Automation. There will be compataibility issues when registering the DSC node if the Automation Account region, VM region, and OMS region do not match."
}

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
$null = Get-AzureRmAutomationAccount -ResourceGroupName $ResourceGroup -Name $AutomationAccountName -ErrorAction Stop

# Add and update modules on the Automation account
######
Write-Output "Importing necessary modules..."

$ModulesImported = @()

function _doImport {   

    param(

        [Parameter(Mandatory=$true)]
        [String] $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [String] $AutomationAccountName,

        [Parameter(Mandatory=$true)]
        [String] $ModuleName,

        # if not specified latest version will be imported
        [Parameter(Mandatory=$false)]
        [String] $ModuleVersion

    )

    $Url = "https://www.powershellgallery.com/api/v2/Search()?`$filter=IsLatestVersion&searchTerm=%27$ModuleName%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40"
    $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -UseBasicParsing

    if($SearchResult.Length -and $SearchResult.Length -gt 1) {
        $SearchResult = $SearchResult | Where-Object -FilterScript {

            return $_.properties.title -eq $ModuleName

        }
    }

    if(!$SearchResult) {

        Write-Error "Could not find module '$ModuleName' on PowerShell Gallery. This may be a module you imported from a different location"

    } else {

        $ModuleName = $SearchResult.properties.title # get correct casing for the module name
        $PackageDetails = Invoke-RestMethod -Method Get -UseBasicParsing -Uri $SearchResult.id 

        if(!$ModuleVersion) {

            # get latest version
            $ModuleVersion = $PackageDetails.entry.properties.version

        }

        $ModuleContentUrl = "https://www.powershellgallery.com/api/v2/package/$ModuleName/$ModuleVersion"

        # Make sure module dependencies are imported
        $Dependencies = $PackageDetails.entry.properties.dependencies


        if($Dependencies -and $Dependencies.Length -gt 0) {

            $Dependencies = $Dependencies.Split("|")

            # parse depencencies, which are in the format: module1name:module1version:|module2name:module2version:
            $Dependencies | ForEach-Object {

                if($_ -and $_.Length -gt 0) {

                    $Parts = $_.Split(":")
                    $DependencyName = $Parts[0]
                    $DependencyVersion = ($Parts[1] -replace '\[', '') -replace '\]', ''

                    # check if we already imported this dependency module during execution of this script

                    if(!$ModulesImported.Contains($DependencyName)) {

                        $AutomationModule = Get-AzureRmAutomationModule `
                            -ResourceGroupName $ResourceGroupName `
                            -AutomationAccountName $AutomationAccountName `
                            -Name $DependencyName `
                            -ErrorAction SilentlyContinue

                        # check if Automation account already contains this dependency module of the right version

                        if((!$AutomationModule) -or $AutomationModule.Version -ne $DependencyVersion) {

                            # this dependency module has not been imported, import it first
                            _doImport `
                                -ResourceGroupName $ResourceGroupName `
                                -AutomationAccountName $AutomationAccountName `
                                -ModuleName $DependencyName `
                                -ModuleVersion $DependencyVersion

                            $ModulesImported += $DependencyName

                        }
                    }
                }
            }
        }
            

        # Find the actual blob storage location of the module
        do {

            $ActualUrl = $ModuleContentUrl
            $ModuleContentUrl = (Invoke-WebRequest -Uri $ModuleContentUrl -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore).Headers.Location 

        } while(!$ModuleContentUrl.Contains(".nupkg"))

        $ActualUrl = $ModuleContentUrl

        $AutomationModule = New-AzureRmAutomationModule `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $ModuleName `
            -ContentLink $ActualUrl

        while(

            (!([string]::IsNullOrEmpty($AutomationModule))) -and
            $AutomationModule.ProvisioningState -ne "Created" -and
            $AutomationModule.ProvisioningState -ne "Succeeded" -and
            $AutomationModule.ProvisioningState -ne "Failed"

        ){
            Write-Verbose -Message "Polling for module import completion"
            Start-Sleep -Seconds 10
            $AutomationModule = $AutomationModule | Get-AzureRmAutomationModule
        }


        if($AutomationModule.ProvisioningState -eq "Failed") {

            Write-Error "     Importing $ModuleName module to Automation failed."

        } else {

            Write-Output "     Importing $ModuleName module to Automation succeeded."

        }
    }
}

# Add existing Azure RM modules to the update list since all modules must be on the same version
$ExistingModules = Get-AzureRmAutomationModule -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName `
                    | where {$_.Name -match "AzureRM"} | select Name

foreach ($Module in $ExistingModules) 
{
   $Module = Get-AzureRmAutomationModule `
        -ResourceGroupName $ResourceGroup `
        -AutomationAccountName $AutomationAccountName `
        -Name $Module.Name

    $ModuleName = $Module.Name
    $ModuleVersionInAutomation = $Module.Version

    $Url = "https://www.powershellgallery.com/api/v2/Search()?`$filter=IsLatestVersion&searchTerm=%27$ModuleName%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40" 
    $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -UseBasicParsing

    if($SearchResult.Length -and $SearchResult.Length -gt 1) {

        $SearchResult = $SearchResult | Where-Object -FilterScript {

            return $_.properties.title -eq $ModuleName

        }
    }


    if(!$SearchResult) {

        Write-Error "Could not find module '$ModuleName' on PowerShell Gallery. This may be a module you imported from a different location"

    } else {

        $PackageDetails = Invoke-RestMethod -Method Get -UseBasicParsing -Uri $SearchResult.id 
        $LatestModuleVersionOnPSGallery = $PackageDetails.entry.properties.version

        if($ModuleVersionInAutomation -ne $LatestModuleVersionOnPSGallery) {

            _doImport `
                -ResourceGroupName $ResourceGroup `
                -AutomationAccountName $AutomationAccountName `
                -ModuleName $ModuleName

        } else {

            Write-Output "     Module '$ModuleName' is up to date."

        }
   }
}

# Create an empty list to hold module names
$ModuleNames = @()

# Add the names of the modules necessary to register a hybrid worker
$ModuleNames += "AzureRM.Network"
$ModuleNames += "AzureRM.OperationalInsights"
$ModuleNames += "HybridRunbookWorker"

# Import modules
foreach ($NewModuleName in $ModuleNames) {
     
     # Check if module exists in the gallery
    $Url = "https://www.powershellgallery.com/api/v2/Search()?`$filter=IsLatestVersion&searchTerm=%27$NewModuleName%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40" 
    $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -UseBasicParsing

    if($SearchResult.Length -and $SearchResult.Length -gt 1) {
        $SearchResult = $SearchResult | Where-Object -FilterScript {

            return $_.properties.title -eq $NewModuleName

        }
    }

    if(!$SearchResult) {
        throw "Could not find module '$NewModuleName' on PowerShell Gallery."
    }      

    if ($NewModuleName -notin $ExistingModules.Name) {

        _doImport `
            -ResourceGroupName $ResourceGroup `
            -AutomationAccountName $AutomationAccountName `
            -ModuleName $NewModuleName

    } else {

        Write-Output ("     Module $NewModuleName is up to date.")

    }

}

# Check for the Install-NewVmWorker runbook in the automation account, import if not there
try {
    
    $null = Get-AzureRmAutomationRunbook -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Name "Install-NewVmWorker" -ErrorAction Stop

} catch {

    # Download Install-NewVmWorker
    $Source =  "https://raw.githubusercontent.com/azureautomation/runbooks/jhunter-msft-dev/Utility/Install-NewVmWorker.ps1"
    $Destination = "$env:temp\Install-NewVmWorker.ps1"

    $null = Invoke-WebRequest -uri $Source -OutFile $Destination
    $null = Unblock-File $Destination


    # Import the DSC configuration to the automation account
    Write-Output "Importing Install-NewVmWorker to complete the next steps..."
    $null = Import-AzureRmAutomationRunbook -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Path $Destination -Type "PowerShell"

    # Publish the runbook so it is runnable
    $null = Publish-AzureRmAutomationRunbook -AutomationAccountName $AutomationAccountName -Name "Install-NewVmWorker" -ResourceGroupName $ResourceGroup

}

$runbookParams = @{"ResourceGroup"=$ResourceGroup;"AutomationAccountName"=$AutomationAccountName;"MachineName"=$MachineName;"WorkspaceName"=$WorkspaceName;"Location"=$Location; `
    "VMUser" = $VMuser; "VMPassword" = $VMPassword; "AvailabilityName" = $AvailabilityName; "StorageName" = $StorageName;`
    "OSDiskName" = $OSDiskName; "VNetName" = $VNetName; "PIpName" = $PIpName; "InterfaceName" = $InterfaceName}

# Start the next runbook job
$null = Start-AzureRmAutomationRunbook -AutomationAccountName $AutomationAccountName -Name "Install-NewVmWorker" -ResourceGroupName $ResourceGroup -Parameters $runbookParams 

Write-Output "Starting Install-NewVmWorker..."