<#PSScriptInfo

.VERSION 1.1

.GUID 15bb25ff-20df-44ab-a4b4-8333818ca084

.AUTHOR Joe Levy

.COMPANYNAME Microsoft

.COPYRIGHT 

.TAGS AzureAutomation OMS Module Utility

.LICENSEURI 

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/AutomationAccountManagement/Import-ModuleFromPSGalleryToAutomation.ps1

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES

#>

#Requires -Module AzureRM.Profile
#Requires -Module AzureRM.Automation

<#
.SYNOPSIS 
    Imports a module on PowerShell Gallery into the Azure/OMS Automation service.

.DESCRIPTION
    Imports a module on PowerShell Gallery into the Azure/OMS Automation service.

    Requires that authentication to Azure (Resource Manager) is already established before running.

.PARAMETER ResourceGroupName
    Required. The name of the Azure Resource Group containing the Automation account to import this module to.

.PARAMETER AutomationAccountName
    Required. The name of the Automation account to import this module to.
    
.PARAMETER ModuleName
    Required. The name of the module to import to Automation.

.PARAMETER ModuleVersion
    Optional. The version of the module to import to Automation. If not specified, the latest version of the
    module will be imported.
    
.EXAMPLE
    Import-ModuleFromPSGalleryToAutomation -ResourceGroupName "MyResourceGroup" -AutomationAccountName "MyAutomationAccount" -ModuleName "AzureRM.Storage" 

.NOTES
    AUTHOR: Azure/OMS Automation Team
    LASTEDIT: May 21, 2016  
#>

param(
    [Parameter(Mandatory=$true)]
    [String] $ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [String] $AutomationAccountName,
    
    [Parameter(Mandatory=$true)]
    [String] $ModuleName,

    [Parameter(Mandatory=$false)]
    [String] $ModuleVersion
)

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

    if($SearchResult -ne $null) {
        $SearchResult = $SearchResult | Where-Object -FilterScript {
            return $_.properties.title -eq $ModuleName
        }
    }

    if(!$SearchResult) {
        Write-Error "Could not find module '$ModuleName' on PowerShell Gallery."
    }
    else {
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
            Write-Output "Importing $ModuleName module to Automation succeeded."
        }
    }
}

_doImport `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -ModuleName $ModuleName `
    -ModuleVersion $ModuleVersion