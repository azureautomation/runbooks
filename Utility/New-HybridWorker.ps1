<#

.SYNOPSIS 

    This Azure/OMS Automation runbook onboards a hybrid worker.


.DESCRIPTION

    This Azure/OMS Automation runbook onboards a hybrid worker. The major steps of the script are outlined below.
    
    1) Login to an Azure account
    2) Import/Update the necessary modules
    3) Create a run the runbook with the next steps



.PARAMETER MachineName

    Mandatory. The computer name (Azure VM or on-premise) to be referenced.



.PARAMETER WorkspaceName

    Optional. The name of the OMS Workspace to be referenced. If not specified, a new OMS workspace 

    is created, referencing the IDString in order to create a unique identifier.



.PARAMETER Location

    Optional. The region of the OMS workspace, Automation account, and VM to be referenced. If not specified,
    
    "westeurope" is used.



.EXAMPLE

    New-HybridWorker -MachineName "ContosoVM"


.NOTES

    AUTHOR: Jenny Hunter, Azure/OMS Automation Team

    LASTEDIT: September 14, 2016  

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

Write-Output "Pulling account credentials..."

# Connect to the current Azure account
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
        Write-Output "     Could not find module '$ModuleName' on PowerShell Gallery."
    }
    else {
        $ModuleName = $SearchResult.properties.title # get correct casing for the module name
        $PackageDetails = Invoke-RestMethod -Method Get -UseBasicParsing -Uri $SearchResult.id 
    
        if(!$ModuleVersion) {
            # get latest version
            $ModuleVersion = ($PackageDetails.entry.properties.version -replace '\[', '') -replace '\]', ''
        }

        $ModuleContentUrl = "https://www.powershellgallery.com/api/v2/package/$ModuleName/$ModuleVersion"

        # Test if the module/version combination exists
        try {
            Invoke-RestMethod $ModuleContentUrl -ErrorAction Stop | Out-Null
            $Stop = $False
        }
        catch {
            Write-Error "Module with name '$ModuleName' of version '$ModuleVersion' does not exist. Are you sure the version specified is correct?"
            $Stop = $True
        }

        if(!$Stop) {
            # check if this module is the same version as the one in the service
            $AutomationModule = Get-AzureRmAutomationModule `
                                            -ResourceGroupName $ResourceGroupName `
                                            -AutomationAccountName $AutomationAccountName `
                                            -Name $ModuleName `
                                            -ErrorAction SilentlyContinue

            if(($AutomationModule) -and $AutomationModule.Version -eq $ModuleVersion) {
                # Skip importing this module                
                Write-Verbose -Message "Module $ModuleName is already in the service"
                return
            }

            # Make sure module dependencies are imported
            $Dependencies = $PackageDetails.entry.properties.dependencies
            $Parts = $Dependencies.Split(":")
            $DependencyName = $Parts[0]
            $DependencyVersion = ($Parts[1] -replace '\[', '') -replace '\]', ''

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
                                
                                Write-Verbose -Message "Importing dependency module $DependencyName of version $DependencyVersion first."

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
            } while($ModuleContentUrl -ne $Null)


            Write-Verbose -Message "Importing $ModuleName module of version $ModuleVersion from $ActualUrl to Automation"

            $AutomationModule = New-AzureRmAutomationModule `
                -ResourceGroupName $ResourceGroupName `
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
                Write-Output "     Importing $ModuleName module to Automation succeeded."
            }
        }
    }
}

# Create an empty list to hold module names
$ModuleNames = @()

# Add existing Azure RM modules to the update list since all modules must be on the same version
$ExistingModules = Get-AzureRmAutomationModule -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName `
                    | where {$_.Name -match "AzureRM"} | select Name

foreach ($ModuleName in $ExistingModules) 
{
    _doImport `
        -ResourceGroupName $ResourceGroup `
        -AutomationAccountName $AutomationAccountName `
        -ModuleName $ModuleName.Name `
        -ModuleVersion $ModuleVersion
}


# Add known dependencies first
$ModuleNames += "AzureRM.Profile"
$ModuleNames += "Azure.Storage"
$ModuleNames += "Azure"

# Add the names of the modules necessary to register a hybrid worker
$ModuleNames += "AzureRM.OperationalInsights"
$ModuleNames += "HybridRunbookWorker"

# Create a reference to the VM's temp folder
$ModuleBase = $env:temp

# Import modules
foreach ($AzureRMModule in $ModuleNames) {
    
    # Check if module exists in the gallery and import to the automation account
    $Url = "https://www.powershellgallery.com/api/v2/Search()?`$filter=IsLatestVersion&searchTerm=%27$AzureRMModule%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40" 
    $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -UseBasicParsing

    if($SearchResult.Length -and $SearchResult.Length -gt 1) {
        $SearchResult = $SearchResult | Where-Object -FilterScript {
            return $_.properties.title -eq $AzureRMModule
        }
    }


    if(!$SearchResult) {
        Write-Output "     Could not find module '$AzureRMModule' on PowerShell Gallery."
    } else {

        # If the new module is not already imported, then import it now
        if ($AzureRMModule -notin $ExistingModules.Name)
        {

            _doImport `
                -ResourceGroupName $ResourceGroup `
                -AutomationAccountName $AutomationAccountName `
                -ModuleName $AzureRMModule `
                -ModuleVersion $ModuleVersion
       
        }
    }

    
}

try {
    
    Get-AzureRmAutomationRunbook -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Name "Install-HybridWorker" -ErrorAction Stop

} catch {

    # Download Install-HybridWorker
    $Source =  "https://raw.githubusercontent.com/azureautomation/runbooks/jhunter-msft-dev/Utility/Install-HybridWorker.ps1"
    $Destination = "$env:temp\Install-HybridWorker.ps1"

    $null = Invoke-WebRequest -uri $Source -OutFile $Destination
    $null = Unblock-File $Destination


    # Import the DSC configuration to the automation account
    Write-Output "Importing Install-HybridWorker to complete the next steps..."
    $null = Import-AzureRmAutomationRunbook -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Path $Destination -Type Powershell -Force

    # Publish the runbook so it is runnable
    Publish-AzureRmAutomationRunbook -AutomationAccountName $AutomationAccountName -Name "Install-HybridWorker" -ResourceGroupName $ResourceGroup

}

$runbookParams = @{"ResourceGroup"=$ResourceGroup;"AutomationAccountName"=$AutomationAccountName;"MachineName"=$MachineName;"WorkspaceName"=$WorkspaceName;"Location"=$Location}

# Start the next runbook job
Start-AzureRmAutomationRunbook -AutomationAccountName $AutomationAccountName -Name "Install-HybridWorker" -ResourceGroupName $ResourceGroup -Parameters $runbookParams 

Write-Output "Starting Install-HybridWorker..."