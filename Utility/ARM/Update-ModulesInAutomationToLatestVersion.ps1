<#PSScriptInfo

.VERSION 1.03

.GUID fa658952-8f94-45ac-9c94-f5fe23d0fcf9

.AUTHOR Automation Team

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

#Requires -Module AzureRM.Profile, AzureRM.Automation,AzureRM.Resources

<#
.SYNOPSIS
    This Azure/OMS Automation runbook imports the latest version on PowerShell Gallery of all modules in an
    Automation account.If a new module to import is specified, it will import that module from the PowerShell Gallery
    after all other modules are updated from the gallery.

.DESCRIPTION
    This Azure/OMS Automation runbook imports the latest version on PowerShell Gallery of all modules in an
    Automation account. By connecting the runbook to an Automation schedule, you can ensure all modules in
    your Automation account stay up to date.
    If a new module to import is specified, it will import that module from the PowerShell Gallery
    after all other modules are updated from the gallery.

.PARAMETER ResourceGroupName
    Optional. The name of the Azure Resource Group containing the Automation account to update all modules for.
    If a resource group is not specified, then it will use the current one for the automation account
    if it is run from the automation service

.PARAMETER AutomationAccountName
    Optional. The name of the Automation account to update all modules for.
    If an automation account is not specified, then it will use the current one for the automation account
    if it is run from the automation service


.PARAMETER NewModuleName
    Optional. The name of a module in the PowerShell gallery to import after all existing modules are updated

.PARAMETER UpdateAzureModulesOnly
    Optional. Set to $false to have logic try to update all modules installed in account.
    Default is $true, and this will only update Azure modules

.EXAMPLE
    Update-ModulesInAutomationToLatestVersion -ResourceGroupName "MyResourceGroup" -AutomationAccountName "MyAutomationAccount" -NewModuleName "AzureRM.Batch" -UpdateAzureModulesOnly $false
    Update-ModulesInAutomationToLatestVersion -ResourceGroupName "MyResourceGroup" -AutomationAccountName "MyAutomationAccount"
    Update-ModulesInAutomationToLatestVersion -UpdateAzureModulesOnly $false
    Update-ModulesInAutomationToLatestVersion

.NOTES
    AUTHOR: Automation Team
    CONTRIBUTOR: Morten Lerudjordet
    LASTEDIT:
#>

param(
    [Parameter(Mandatory=$false)]
    [String] $ResourceGroupName,

    [Parameter(Mandatory=$false)]
    [String] $AutomationAccountName,

    [Parameter(Mandatory=$false)]
    [String] $NewModuleName,

    [Parameter(Mandatory=$false)]
    [Bool] $UpdateAzureModulesOnly = $true
)
$VerbosePreference = "silentlycontinue"
$RunbookName = "Update-ModulesInAutomationToLatestVersion"
Write-Output -InputObject "Starting Runbook: $RunbookName at time: $(get-Date -format r).`nRunning PS version: $($PSVersionTable.PSVersion)`nOn host: $($env:computername)"
Import-Module -Name AzureRM.Profile, AzureRM.Automation,AzureRM.Resources -ErrorAction Continue -ErrorVariable oErr
If($oErr) {
    Write-Error -Message "Failed to load needed modules for Runbook. Error: $($oErr.Message)" -ErrorAction Stop
}
$VerbosePreference = "continue"
$ErrorActionPreference = "stop"
$ModulesImported = @()

#region Constants
$AzureSdkOwnerName = "azure-sdk"
$PsGalleryApiUrl = 'https://www.powershellgallery.com/api/v2'
#endregion

#region Functions
function doModuleImport {
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

    $Filter = @($ModuleName.Trim('*').Split('*') | ForEach-Object { "substringof('$_',Id)" }) -join " and "
    $Url = "$PsGalleryApiUrl/Packages?`$filter=$Filter and IsLatestVersion"

    # Fetch results and filter them with -like, and then shape the output
    $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -ErrorAction Continue -ErrorVariable oErr | Where-Object { $_.title.'#text' -like $ModuleName } |
    Select-Object @{n='Name';ex={$_.title.'#text'}},
                  @{n='Version';ex={$_.properties.version}},
                  @{n='Url';ex={$_.Content.src}},
                  @{n='Dependencies';ex={$_.properties.Dependencies}},
                  @{n='Owners';ex={$_.properties.Owners}}
    If($oErr) {
        # Will stop runbook, though message will not be logged
        Write-Error -Message "Stopping runbook" -ErrorAction Stop
    }
    # Should not be needed as filter will only return one hit, though will keep the code to strip away if search ever get multiple hits
    if($SearchResult.Length -and $SearchResult.Length -gt 1) {
        $SearchResult = $SearchResult | Where-Object -FilterScript {
            return $_.Name -eq $ModuleName
        }
    }

    if(!$SearchResult) {
        Write-Warning "Could not find module '$ModuleName' on PowerShell Gallery. This may be a module you imported from a different location"
    }
    else
    {
        $ModuleName = $SearchResult.Name # get correct casing for the module name

        if(!$ModuleVersion)
        {
            # get latest version
            $ModuleContentUrl = $SearchResult.Url
        }
        else
        {
            $ModuleContentUrl = "$PsGalleryApiUrl/package/$ModuleName/$ModuleVersion"
        }

        # Make sure module dependencies are imported
        $Dependencies = $SearchResult.Dependencies

        if($Dependencies -and $Dependencies.Length -gt 0) {
            $Dependencies = $Dependencies.Split("|")

            # parse dependencies, which are in the format: module1name:module1version:|module2name:module2version:
            $Dependencies | ForEach-Object {

                if($_ -and $_.Length -gt 0) {
                    $Parts = $_.Split(":")
                    $DependencyName = $Parts[0]
                    $DependencyVersion = $Parts[1] -replace "[^0-9.]", ''

                    # check if we already imported this dependency module during execution of this script
                    if(!$ModulesImported.Contains($DependencyName)) {
                        # Log errors if occurs
                        $AutomationModule = Get-AzureRmAutomationModule `
                            -ResourceGroupName $ResourceGroupName `
                            -AutomationAccountName $AutomationAccountName `
                            -Name $DependencyName `
                            -ErrorAction Continue

                        # check if Automation account already contains this dependency module of the right version
                        if((!$AutomationModule) -or $AutomationModule.Version -ne $DependencyVersion) {

                            Write-Output -InputObject "Importing dependency module $DependencyName of version $DependencyVersion first."

                            # this dependency module has not been imported, import it first
                            doModuleImport `
                                -ResourceGroupName $ResourceGroupName `
                                -AutomationAccountName $AutomationAccountName `
                                -ModuleName $DependencyName `
                                -ModuleVersion $DependencyVersion -ErrorAction Stop

                            $ModulesImported += $DependencyName
                        }
                    }
                }
            }
        }

        # Find the actual blob storage location of the module
        do
        {
            $ActualUrl = $ModuleContentUrl
            $ModuleContentUrl = (Invoke-WebRequest -Uri $ModuleContentUrl -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore).Headers.Location
        }
        while(!$ModuleContentUrl.Contains(".nupkg"))

        $ActualUrl = $ModuleContentUrl

        if($ModuleVersion)
        {
            Write-Output -InputObject "Importing $ModuleName module of version $ModuleVersion to Automation"
        }
        else
        {
            Write-Output -InputObject "Importing $ModuleName module of version $($SearchResult.Version) to Automation"
        }

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
            Write-Output -InputObject "Importing $ModuleName module to Automation succeeded."
        }
    }
}
#endregion

#region Main
try
{

    $RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection" -ErrorAction Stop
    if($RunAsConnection)
    {
        Write-Output -InputObject ("Logging in to Azure...")

        Add-AzureRmAccount `
            -ServicePrincipal `
            -TenantId $RunAsConnection.TenantId `
            -ApplicationId $RunAsConnection.ApplicationId `
            -CertificateThumbprint $RunAsConnection.CertificateThumbprint -ErrorAction Continue -ErrorVariable oErr
        if($oErr)
        {
            Write-Error -Message "Failed to connect to Azure" -ErrorAction Stop
        }
        Select-AzureRmSubscription -SubscriptionId $RunAsConnection.SubscriptionID -ErrorAction Continue -ErrorVariable oErr
        if($oErr)
        {
            Write-Error -Message "Failed to select Azure subscription" -ErrorAction Stop
        }
        # Find the automation account or resource group is not specified
        if  (([string]::IsNullOrEmpty($ResourceGroupName)) -or ([string]::IsNullOrEmpty($AutomationAccountName)))
        {
            Write-Verbose -Message ("Finding the ResourceGroup and AutomationAccount that this job is running in ...")
            if ([string]::IsNullOrEmpty($PSPrivateMetadata.JobId.Guid))
            {
                Write-Error -Message "This is not running from the automation service. Please specify ResourceGroupName and AutomationAccountName as parameters" -ErrorAction Stop
            }
            # Breaking change in version 6 of AzureRM.Resources, Find-AzureRmResource is deprecated
            if((Get-Module -Name AzureRM.Resources).Version.Major -lt 6)
            {
                $AutomationResource = Find-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts
            }
            else
            {
                $AutomationResource = Get-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts
            }

            foreach ($Automation in $AutomationResource)
            {
                $Job = Get-AzureRmAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
                if (!([string]::IsNullOrEmpty($Job)))
                {
                        $ResourceGroupName = $Job.ResourceGroupName
                        $AutomationAccountName = $Job.AutomationAccountName
                        break;
                }
            }
        }
    }
    else
    {
        Write-Error -Message "Check that AzureRunAsConnection is configured for AA account: $AutomationAccountName" -ErrorAction Stop
    }

    $Modules = Get-AzureRmAutomationModule `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName -ErrorAction continue -ErrorVariable oErr
    if($oErr)
    {
        Write-Error -Message "Failed to retrieve modules in AA account $AutomationAccountName" -ErrorAction Stop
    }
    if($Modules)
    {
        foreach($Module in $Modules)
        {
            $Module = Get-AzureRmAutomationModule `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $Module.Name -ErrorAction continue -ErrorVariable oErr
            if($oErr)
            {
                Write-Error -Message "Failed to retrieve module: $($Module.Name) from AA account: $AutomationAccountName. Skipping update process" -ErrorAction Continue
                $oErr = $Null
            }
            else
            {
                $ModuleName = $Module.Name
                $ModuleVersionInAutomation = $Module.Version

                $Filter = @($ModuleName.Trim('*').Split('*') | ForEach-Object { "substringof('$_',Id)" }) -join " and "
                $Url = "$PsGalleryApiUrl/Packages?`$filter=$Filter and IsLatestVersion"

                # Fetch results and filter them with -like, and then shape the output
                $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -ErrorAction Continue -ErrorVariable oErr | Where-Object { $_.title.'#text' -like $ModuleName } |
                Select-Object @{n='Name';ex={$_.title.'#text'}},
                            @{n='Version';ex={$_.properties.version}},
                            @{n='Url';ex={$_.Content.src}},
                            @{n='Dependencies';ex={$_.properties.Dependencies}},
                            @{n='Owners';ex={$_.properties.Owners}}
                if($oErr) {
                    Write-Error -Message "Failed to query Gallery for module $ModuleName" -ErrorAction Continue
                    $oErr = $Null
                }
                if($SearchResult)
                {
                    # Should not be needed anymore, though in the event of the search returning more than one hit this will strip it down
                    if($SearchResult.Length -and $SearchResult.Length -gt 1)
                    {
                        $SearchResult = $SearchResult | Where-Object -FilterScript {
                            return $_.Name -eq $ModuleName
                        }
                    }

                    $UpdateModule = $false
                    if($UpdateAzureModulesOnly)
                    {
                        if($SearchResult.Owners -eq $AzureSdkOwnerName)
                        {
                            Write-Output -InputObject "Checking if module '$ModuleName' is up to date in your automation account"
                            $UpdateModule = $true
                        }
                    }
                    else
                    {
                        Write-Output -InputObject "Checking if module '$ModuleName' is up to date in your automation account"
                        $UpdateModule = $true
                    }
                    if($UpdateModule)
                    {
                        if(!$SearchResult)
                        {
                            Write-Warning "Could not find module '$ModuleName' on PowerShell Gallery. This may be a module imported from a different location"
                        }
                        else
                        {
                            $LatestModuleVersionOnPSGallery = $SearchResult.Version

                            if($ModuleVersionInAutomation -ne $LatestModuleVersionOnPSGallery)
                            {
                                Write-Output -InputObject "Module '$ModuleName' is not up to date. Latest version on PS Gallery is '$LatestModuleVersionOnPSGallery' but this automation account has version '$ModuleVersionInAutomation'"
                                Write-Output -InputObject "Importing latest version of '$ModuleName' into your automation account"

                                doModuleImport `
                                    -ResourceGroupName $ResourceGroupName `
                                    -AutomationAccountName $AutomationAccountName `
                                    -ModuleName $ModuleName
                            }
                            else
                            {
                                Write-Output -InputObject "Module '$ModuleName' is up to date."
                            }
                        }
                    }
                }
                else
                {
                    Write-Warning -Message "No result from querying PS Gallery for module: $ModuleName"
                }
            }
        }
    }
    else
    {
        Write-Error -Message "No modules found in AA account: $AutomationAccountName" -ErrorAction Stop
    }
    # Import module if specified
    if (!([string]::IsNullOrEmpty($NewModuleName)))
    {
        # Check if module exists in the gallery
        $Filter = @($ModuleName.Trim('*').Split('*') | ForEach-Object { "substringof('$_',Id)" }) -join " and "
        $Url = "$PsGalleryApiUrl/Packages?`$filter=$Filter and IsLatestVersion"

        # Fetch results and filter them with -like, and then shape the output
        $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -ErrorAction Continue -ErrorVariable oErr | Where-Object { $_.title.'#text' -like $ModuleName } |
        Select-Object @{n='Name';ex={$_.title.'#text'}},
                    @{n='Version';ex={$_.properties.version}},
                    @{n='Url';ex={$_.Content.src}},
                    @{n='Dependencies';ex={$_.properties.Dependencies}},
                    @{n='Owners';ex={$_.properties.Owners}}
        If($oErr) {
            # Will stop runbook, though message will not be logged
            Write-Error -Message "Failed to query Gallery" -ErrorAction Stop
        }

        if($SearchResult.Length -and $SearchResult.Length -gt 1) {
            $SearchResult = $SearchResult | Where-Object -FilterScript {
                return $_.Name -eq $NewModuleName
            }
        }

        if(!$SearchResult) {
            throw "Could not find module '$NewModuleName' on PowerShell Gallery."
        }

        if ($NewModuleName -notin $Modules.Name)
        {
            Write-Output -InputObject "Importing latest version of '$NewModuleName' into your automation account"

            doModuleImport `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -ModuleName $NewModuleName
        }
        else
        {
            Write-Output -InputObject ("Module $NewModuleName is already in the automation account")
        }
    }
}
catch
{
    if ($_.Exception.Message)
    {
        Write-Error -Message "$($_.Exception.Message)" -ErrorAction Continue
    }
    else
    {
        Write-Error -Message "$($_.Exception)" -ErrorAction Continue
    }
    throw "$($_.Exception)"
}
finally
{
    Write-Output -InputObject "Runbook: $RunbookName ended at time: $(get-Date -format r)"
}
#endregion Main