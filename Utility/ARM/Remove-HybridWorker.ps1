<#

.SYNOPSIS 

    This Azure/OMS Automation runbook removes an exisiting hybrid worker. 


.DESCRIPTION

    This Azure/OMS Automation runbook removes an existing hybrid worker. It assumes that the machine is
    
    configured as a DSC node and utilizes DSC to unregister the hybrid worker.


.PARAMETER MachineName

    Mandatory. The computer name of the DSC Node to be referenced.


.PARAMETER HybridWorkerGroup

    Mandatory. The name of the hybrid worker group.


.EXAMPLE

    Remove-HybridWorker -MachineName "ContosoMachine"


.NOTES

    AUTHOR: Jenny Hunter, Azure/OMS Automation Team

    LASTEDIT: October 17, 2016  

#>

Param (
# Machine
[Parameter(Mandatory=$true)]
[String] $MachineName,

# Hybrid Worker Group
[Parameter(Mandatory=$true)]
[String] $HybridWorkerGroup
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
$AutomationResource = Get-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts -ExtensionResourceName Microsoft.Automation

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

# Get Azure Automation Primary Key and Endpoint
$AutomationInfo = Get-AzureRMAutomationRegistrationInfo -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName
$AutomationPrimaryKey = $AutomationInfo.PrimaryKey
$AutomationEndpoint = $AutomationInfo.Endpoint

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
                        | select Name

# Add the names of the modules necessary to unregister a hybrid worker
$NewModuleName = "HybridRunbookWorker"
$ModuleVersion = "1.1"

# Import modules
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
        -ModuleName $NewModuleName `
        -ModuleVersion $ModuleVersion

} else {

    Write-Output ("     Module $NewModuleName is up to date.")

}


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
    "HybridGroupName" = $HybridGroupName
}

# Use configuration data to bypass storing credentials as plain text
$ConfigData = @{
    AllNodes = @(
        @{
            NodeName = 'localhost'
            PSDscAllowPlainTextPassword = $true

        }
    )
} 

    
# Download the DSC configuration file
$Source =  "https://raw.githubusercontent.com/azureautomation/runbooks/jhunter-msft-dev/Utility/ARM/RemoveHybridWorker.ps1"
$Destination = "$env:temp\RemoveHybridWorker.ps1"

$null = Invoke-WebRequest -uri $Source -OutFile $Destination
$null = Unblock-File $Destination


# Import the DSC configuration to the automation account
Write-Output "Importing DSC configuration to unregister the hybrid worker..."
$null = Import-AzureRmAutomationDscConfiguration -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -SourcePath $Destination -Published -Force


# Compile the DSC configuration
Write-Output "Compiling DSC Job..."
$CompilationJob = Start-AzureRmAutomationDscCompilationJob -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -ConfigurationName "RemoveHybridWorker" -Parameters $ConfigParameters -ConfigurationData $ConfigData

while($CompilationJob.EndTime –eq $null -and $CompilationJob.Exception –eq $null)           
{
    $CompilationJob = $CompilationJob | Get-AzureRmAutomationDscCompilationJob
    Start-Sleep -Seconds 3
}
  
# Configure the DSC node
Write-Output "Setting the configuration for the DSC node..."
$null = Set-AzureRmAutomationDscNode -ResourceGroupName $ResourceGroup  -NodeConfigurationName "RemoveHybridWorker.localhost" -Id $DscNode.Id -AutomationAccountName $AutomationAccountName -Force

Write-Output "Complete: Please wait one configuration cycle (approximately 30 minutes) for the DSC configuration to be pulled from the server and the Hybrid Worker Group to be unregistered."
