<#

.SYNOPSIS 

    This Azure/OMS Automation runbook onboards a hybrid worker. A resource group, automation account, OMS workspace, 
    and VM will all be generated if needed.


.DESCRIPTION

    This Azure/OMS Automation runbook onboards a hybrid worker. A resource group, automation account, OMS workspace,
    and VM will all be generated if needed. The major steps of the script are outlined below.
    
    1) Login to an Azure account
    2) Create reference to resource group
    3) Create reference to Automation Account
    4) Create an OMS Workspace if needed
    5) Enable the Azure Automation solution in OMS
    6) Create reference to the VM 
    7) Download the DSC agent
    8) Submit the configuration to register the machine as a hybrid worker



.PARAMETER MachineName

    Mandatory. The computer name (Azure VM or on-premise) to be referenced. If not specified, a computer name

    is created, referencing the IDString in order to create a unique identifier.



.PARAMETER WorkspaceName

    Optional. The name of the OMS Workspace to be referenced. If not specified, a new OMS workspace 

    is created, referencing the IDString in order to create a unique identifier.



.PARAMETER Location

    Optional. The region of the OMS workspace, Automation account, and VM to be referenced. If not specified,
    
    "westeurope" is used.



.EXAMPLE



.NOTES

    AUTHOR: Jennifer Hunter, Azure/OMS Automation Team

    LASTEDIT: August 31, 2016  

#>

Param (
# VM
[Parameter(Mandatory=$true)]
[String] $MachineName,

# OMS Workspace
[Parameter(Mandatory=$false)]
[String] $WorkspaceName = "hybrid-worker",

[Parameter(Mandatory=$false)]
[String] $Location = "westeurope"

)

# Connect to the current Azure account
$Conn = Get-AutomationConnection -Name AzureRunAsConnection 
Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationID $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint 

# Get the subscription and tenant IDs
$SubscriptionID = $Conn.SubscriptionID
$TenantID = $Conn.TenantID

# Set the active subscription
Set-AzureRmContext -SubscriptionID $SubscriptionID

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

# Create refernce to the resource group
Get-AzureRmResourceGroup -Name $ResourceGroup -ErrorAction Stop

#Create a new automation account if needed 
Get-AzureRmAutomationAccount -ResourceGroupName $ResourceGroup -Name $AutomationAccountName -ErrorAction Stop

# Add the HybridRunbookWorker Module to the Automation Account
# The below code is based off of code written by Joe Levy at https://github.com/azureautomation/runbooks/blob/master/Utility/Update-ModulesInAutomationToLatestVersion.ps1
######################################
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

    if($SearchResult) {
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
                    $DependencyVersion = $Parts[1]

                    # check if we already imported this dependency module during execution of this script
                    if(!$ModulesImported.Contains($DependencyName)) {

                        $AutomationModule = Get-AzureRmAutomationModule `
                            -ResourceGroupName $ResourceGroupName `
                            -AutomationAccountName $AutomationAccountName `
                            -Name $DependencyName `
                            -ErrorAction SilentlyContinue
    
                        # check if Automation account already contains this dependency module of the right version
                        if((!$AutomationModule) -or $AutomationModule.Version -ne $DependencyVersion) {
                                
                            Write-Output "Importing dependency module $DependencyName of version $DependencyVersion first."

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

        Write-Output "Importing $ModuleName module of version $ModuleVersion from $ActualUrl to Automation"

        $AutomationModule = New-AzureRmAutomationModule `
            -ResourceGroupName $ResourceGroup `
            -AutomationAccountName $AutomationAccountName `
            -Name $ModuleName `
            -ContentLink $ActualUrl

        while(

            $AutomationModule.ProvisioningState -ne "Created" -and
            $AutomationModule.ProvisioningState -ne "Succeeded" -and
            $AutomationModule.ProvisioningState -ne "Failed"
        )
        {
            Write-Verbose -Message "Polling for module import completion"
            Start-Sleep -Seconds 10
            $AutomationModule = $AutomationModule | Get-AzureRmAutomationModule
        }

        if($AutomationModule.ProvisioningState -eq "Failed") {

            Write-Error "Importing $ModuleName module to Automation failed."
        }
        else {

            Write-Output "Importing $ModuleName module to Automation succeeded."
        }
    }
}

# Get a list of the current modules on the automation account 
$Modules = Get-AzureRmAutomationModule `
    -ResourceGroupName $ResourceGroup `
    -AutomationAccountName $AutomationAccountName

# Create an empty list to hold module names
$ModuleNames = @()

# Update the list of module names
foreach ($Module in $Modules) {

    $ModuleNames+= $Module.Name
}

# Add the names of the modules necessary to register a hybrid worker
$ModuleNames += "HybridRunbookWorker"
$ModuleNames += "AzureRM.OperationalInsights"

foreach ($ModuleName in $ModuleNames) {
    try {

        $Module = Get-AzureRmAutomationModule -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Name $ModuleName -ErrorAction Stop

        $ModuleVersionInAutomation = $Module.Version

    } catch{

        $ModuleVersionInAutomation = "0.0"
    }

    Write-Output "Checking if module '$ModuleName' is up to date in your automation account"


    $Url = "https://www.powershellgallery.com/api/v2/Search()?`$filter=IsLatestVersion&searchTerm=%27$ModuleName%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40" 

    $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -UseBasicParsing

    if($SearchResult.Length -and $SearchResult.Length -gt 1) {

        $SearchResult = $SearchResult | Where-Object -FilterScript {
    $DscNode = Get-AzureRmAutomationDscNode -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -Name $MachineName

            return $_.properties.title -eq $ModuleName
        }
    }

    if(!$SearchResult) {
        Write-Error "Could not find module '$ModuleName' on PowerShell Gallery."

    } else {
        $PackageDetails = Invoke-RestMethod -Method Get -UseBasicParsing -Uri $SearchResult.id 
        $LatestModuleVersionOnPSGallery = $PackageDetails.entry.properties.version

        if($ModuleVersionInAutomation -ne $LatestModuleVersionOnPSGallery) {

            Write-Output "Module '$ModuleName' is not up to date. Latest version on PS Gallery is '$LatestModuleVersionOnPSGallery' but this automation account has version '$ModuleVersionInAutomation'"
   
            Write-Output "Importing latest version of '$ModuleName' into your automation account"

            _doImport -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -ModuleName $ModuleName
        }

        else {

            Write-Output "Module '$ModuleName' is up to date."
        }
    }

}
##########################


# Get Azure Automation Primary Key and Endpoint
$AutomationInfo = Get-AzureRMAutomationRegistrationInfo -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName
$AutomationPrimaryKey = $AutomationInfo.PrimaryKey
$AutomationEndpoint = $AutomationInfo.Endpoint

# Create a new OMS workspace if needed
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
Set-AzureRmOperationalInsightsIntelligencePack -ResourceGroupName $ResourceGroup -WorkspaceName $WorkspaceName -IntelligencePackName "AzureAutomation" -Enabled $true

# Create a reference to the VM
$VM = Get-AzureRmVM -ResourceGroupName $ResourceGroup -Name $MachineName -ErrorAction Stop


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

Invoke-WebRequest -uri $Source -OutFile $Destination
Unblock-File $Destination


# Import the DSC configuration to the automation account
Import-AzureRmAutomationDscConfiguration -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -SourcePath $Destination -Published -Force


# Compile the DSC configuration
$CompilationJob = Start-AzureRmAutomationDscCompilationJob -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -ConfigurationName "HybridWorkerConfiguration" -Parameters $ConfigParameters -ConfigurationData $ConfigData
    
while($CompilationJob.EndTime –eq $null -and $CompilationJob.Exception –eq $null)           
{
    $CompilationJob = $CompilationJob | Get-AzureRmAutomationDscCompilationJob
    Start-Sleep -Seconds 3
}

$CompilationJob | Get-AzureRmAutomationDscCompilationJobOutput –Stream Any 
  
# Configure the DSC node
Set-AzureRmAutomationDscNode -ResourceGroupName $ResourceGroup  -NodeConfigurationName "HybridWorkerConfiguration.HybridVM" -Id $DscNode.Id -AutomationAccountName $AutomationAccountName -Force