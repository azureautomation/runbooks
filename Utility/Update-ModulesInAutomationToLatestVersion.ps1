<#PSScriptInfo

.VERSION 1.0

.GUID fa658952-8f94-45ac-9c94-f5fe23d0fcf9

.AUTHOR Joe Levy

.COMPANYNAME Microsoft

.COPYRIGHT 

.TAGS AzureAutomation OMS Module Utility

.LICENSEURI 

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/Utility/Update-ModulesInAutomationToLatestVersion.ps1

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
    This Azure/OMS Automation runbook imports the latest version on PowerShell Gallery of all modules in an 
    Automation account.

.DESCRIPTION
    This Azure/OMS Automation runbook imports the latest version on PowerShell Gallery of all modules in an 
    Automation account. By connecting the runbook to an Automation schedule, you can ensure all modules in
    your Automation account stay up to date.

.PARAMETER ResourceGroupName
    Required. The name of the Azure Resource Group containing the Automation account to update all modules for.

.PARAMETER AutomationAccountName
    Required. The name of the Automation account to update all modules for.

.PARAMETER AzureConnectionName
    Optional. The name of the Azure Run As Account connection asset to use to authenticate to Azure. If not specified,
    the default name of "AzureRunAsConnection" is used.  
    
.EXAMPLE
    Update-ModulesInAutomationToLatestVersion -ResourceGroupName "MyResourceGroup" -AutomationAccountName "MyAutomationAccount" 

.NOTES
    AUTHOR: Azure/OMS Automation Team
    LASTEDIT: June 5, 2016  
#>

param(
    [Parameter(Mandatory=$true)]
    [String] $ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [String] $AutomationAccountName,

    [Parameter(Mandatory=$false)]
    [String] $AzureConnectionName = "AzureRunAsConnection"
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

    if($SearchResult.Length -and $SearchResult.Length -gt 1) {
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

try {
    $ServicePrincipalConnection = Get-AutomationConnection -Name $AzureConnectionName         

    "Logging in to Azure..."
    Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
}
catch {
    if(!$ServicePrincipalConnection) {
        throw "Connection $AzureConnectionName not found."
    }
    else {
        throw $_.Exception
    }
}

$Modules = Get-AzureRmAutomationModule `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName

foreach($Module in $Modules) {

    $Module = Get-AzureRmAutomationModule `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $Module.Name
    
    $ModuleName = $Module.Name
    $ModuleVersionInAutomation = $Module.Version

    Write-Output "Checking if module '$ModuleName' is up to date in your automation account"

    $Url = "https://www.powershellgallery.com/api/v2/Search()?`$filter=IsLatestVersion&searchTerm=%27$ModuleName%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40" 
    $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -UseBasicParsing

    if($SearchResult.Length -and $SearchResult.Length -gt 1) {
        $SearchResult = $SearchResult | Where-Object -FilterScript {
            return $_.properties.title -eq $ModuleName
        }
    }

    if(!$SearchResult) {
        Write-Error "Could not find module '$ModuleName' on PowerShell Gallery."
    }
    else {
        $PackageDetails = Invoke-RestMethod -Method Get -UseBasicParsing -Uri $SearchResult.id 
        $LatestModuleVersionOnPSGallery = $PackageDetails.entry.properties.version

        if($ModuleVersionInAutomation -ne $LatestModuleVersionOnPSGallery) {
            Write-Output "Module '$ModuleName' is not up to date. Latest version on PS Gallery is '$LatestModuleVersionOnPSGallery' but this automation account has version '$ModuleVersionInAutomation'"
            Write-Output "Importing latest version of '$ModuleName' into your automation account"

            _doImport `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -ModuleName $ModuleName
        }
        else {
            Write-Output "Module '$ModuleName' is up to date."
        }
   }
}