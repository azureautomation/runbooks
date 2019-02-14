﻿<#

.SYNOPSIS 

    This Azure/OMS Automation runbook onboards a pre-exisiting VM as a hybrid worker. (1/2)


.DESCRIPTION

    This Azure/OMS Automation runbook onboards a hybrid worker.  An OMS workspace will be generated
    if needed. The major steps of the script are outlined below.
    
    1) Login to an Azure account
    2) Import/Update the necessary modules
    3) Import Install-HybridWorker for next steps


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

    New-HybridWorker -MachineName "ContosoVM" -VMResourceGroup "ContosoResources"


.NOTES

    AUTHOR: Jenny Hunter, Azure/OMS Automation Team

    LASTEDIT: October 17, 2016  
#>

Param (
# VM
[Parameter(Mandatory=$true)]
[String] $VmName,

# VM Resource Group
[Parameter(Mandatory=$true)]
[String] $VMResourceGroup,

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
$AutomationResource = Get-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts
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

# If not provided, select an OMS workspace region
if ([string]::IsNullOrEmpty($OmsLocation)) {
    if ($AALocation -match "europe") {
        $OmsLocation = "westeurope"
    } elseif ($AALocation -match "asia") {
        $OmsLocation = "southeastasia"
    } elseif ($AALocation -match "australia") {
        $OmsLocation = "australiasoutheast"
    } else {
        $OmsLocation = "eastus"
    }
}

# Check that the provided region is a supported OMS region
$validRegions = "westeurope", "southeastasia", "eastus", "australiasoutheast"
if ($validRegions -notcontains $OmsLocation) {
    throw "Currently, only the West Europe, East US, Australia Southeast, and Southeast Asia regions are supported for OMS."
}

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
$ExistingAzureRmModules = Get-AzureRmAutomationModule -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName `
                    | where {$_.Name -match "AzureRM"} | select Name

foreach ($Module in $ExistingAzureRmModules) 
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

# Create an empty list to hold modules
$Modules = @()

# Add the names of the modules necessary to register a hybrid worker
$Modules += @{"Name" = "AzureRM.OperationalInsights"; "Version" = ""}
$Modules += @{"Name" = "HybridRunbookWorkerDsc"; "Version" = "1.0.0.0"}
$Modules += @{"Name" = "xPSDesiredStateConfiguration"; "Version" = "4.0.0.0"}

# Import modules
foreach ($NewModule in $Modules) {
    $ModuleName = $NewModule.Name
    $ModuleVersion = $NewModule.Version

    # Check if the version of the module if it is already in the automation account
    try {

        $ModuleInAutomation = Get-AzureRmAutomationModule `
            -ResourceGroupName $ResourceGroup `
            -AutomationAccountName $AutomationAccountName `
            -Name $ModuleName

        $ModuleVersionInAutomation = $ModuleInAutomation.Version
    } catch {

        $ModuleVersionInAutomation = "0.0"

    }
     
    # Check if module exists in the gallery
    $Url = "https://www.powershellgallery.com/api/v2/Search()?`$filter=IsLatestVersion&searchTerm=%27$ModuleName%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40" 
    $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -UseBasicParsing

    if($SearchResult.Length -and $SearchResult.Length -gt 1) {
        $SearchResult = $SearchResult | Where-Object -FilterScript {

            return $_.properties.title -eq $ModuleName

        }
    }

    if(!$SearchResult) {
        
        throw "Could not find module '$ModuleName' on PowerShell Gallery."
    }   else {
        
        if (!$ModuleVersion) {

            $PackageDetails = Invoke-RestMethod -Method Get -UseBasicParsing -Uri $SearchResult.id 
            $ModuleVersion = $PackageDetails.entry.properties.version

        }
        
        if(($ModuleVersionInAutomation -ne $ModuleVersion)) {

             _doImport `
                -ResourceGroupName $ResourceGroup `
                -AutomationAccountName $AutomationAccountName `
                -ModuleName $ModuleName `
                -ModuleVersion $ModuleVersion

        } else {

            Write-Output ("     Module '$ModuleName' is up to date.")

        }
    }
}
    
# Check for the Install-HybridWorker runbook in the automation account, import if not there
try {
    
    $null = Get-AzureRmAutomationRunbook -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Name "Install-HybridWorker" -ErrorAction Stop

} catch {

    # Download Install-HybridWorker
    $Source =  "https://raw.githubusercontent.com/azureautomation/runbooks/master/Utility/ARM/Install-HybridWorker.ps1"
    $Destination = "$env:temp\Install-HybridWorker.ps1"

    $null = Invoke-WebRequest -uri $Source -OutFile $Destination
    $null = Unblock-File $Destination


    # Import the DSC configuration to the automation account
    Write-Output "Importing Install-HybridWorker to complete the next steps..."
    $null = Import-AzureRmAutomationRunbook -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Path $Destination -Type "PowerShell"

    # Publish the runbook so it is runnable
    $null = Publish-AzureRmAutomationRunbook -AutomationAccountName $AutomationAccountName -Name "Install-HybridWorker" -ResourceGroupName $ResourceGroup

}

$runbookParams = @{"ResourceGroup"=$ResourceGroup;"AutomationAccountName"=$AutomationAccountName;"VmName"=$VmName; "VmResourceGroup" = $VMResourceGroup;"WorkspaceName"=$WorkspaceName; "OmsLocation"=$OmsLocation}

# Start the next runbook job
$null = Start-AzureRmAutomationRunbook -AutomationAccountName $AutomationAccountName -Name "Install-HybridWorker" -ResourceGroupName $ResourceGroup -Parameters $runbookParams 

Write-Output "Starting Install-HybridWorker..."
