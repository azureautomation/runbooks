<#
.SYNOPSIS
    This Azure Automation Runbook imports a module and all of it's dependencies into AA from PowerShell Gallery.
    This is meant to only run from an Automation account. This module can import the Az module into the Automation account.

    NOTE:
        Running this on a new AA account one must input both AutomationResourceGroupName and AutomationAccountName

.DESCRIPTION
    This Azure Automation Runbook imports a module named as parameter input to AA from PowerShell Gallery.

    NOTE:
        AA only supports having one version of the same module imported, therefor this Runbook will only keep the latest version active.
        Even if module dependencies have reliance on previous versions of a module.
        (lik for Az, where different dependencies modules can depend on different versions of Az.Accounts)

        This module can not be run locally without the use of Automation ISE-addon
        URL: https://github.com/azureautomation/azure-automation-ise-addon

.PARAMETER NewModuleNames
    The name of a modules in the PowerShell gallery to import into Automation account.
    If entering multiple values through the portal use the following format:
        ['ModuleNam1','ModuleNam2','ModuleNam3']

.PARAMETER AutomationResourceGroupName
    Optional. The name of the Azure Resource Group containing the Automation account to update all modules for.
    If a resource group is not specified, then it will use the current one for the automation account
    if it is run from the automation service

.PARAMETER AutomationAccountName
    Optional. The name of the Automation account to update all modules for.
    If an automation account is not specified, then it will use the current one for the automation account
    if it is run from the automation service

.PARAMETER Force
    Optional. Forces import of newest version in PS Gallery

.PARAMETER DebugLocal
    Optional. Set to $true if debugging script locally to switch of logic that tries to discover the Automation account it is running in
    Default is $false

.EXAMPLE
    Import-PSGalleryModulesInAA -AutomationResourceGroupName "MyResourceGroup" -AutomationAccountName "MyAutomationAccount" -NewModuleName "AzureRM"
    Import-PSGalleryModulesInAA -NewModuleName "AzureRM"

.NOTES
    AUTHOR:         Automation Team
    CONTRIBUTOR:    Morten Lerudjordet
    LASTEDIT:       09.06.2019
#>

param(
    [Parameter(Mandatory = $true)]
    [Array] $NewModuleNames,

    [Parameter(Mandatory = $false)]
    [String] $AutomationResourceGroupName,

    [Parameter(Mandatory = $false)]
    [String] $AutomationAccountName,

    [Parameter(Mandatory = $false)]
    [Bool] $Force = $false,

    [Parameter(Mandatory = $false)]
    [switch] $DebugLocal = $false
)
$VerbosePreference = "silentlycontinue"
$RunbookName = "Import-PSGalleryModulesInAA"
Write-Output -InputObject "Starting Runbook: $RunbookName at time: $(get-Date -format r).`nRunning PS version: $($PSVersionTable.PSVersion)`nOn host: $($env:computername)"
# Prefer to use Az module if available
if((Get-Module -Name "Az.Accounts" -ListAvailable) -and (Get-Module -Name "Az.Automation" -ListAvailable) -and (Get-Module -Name "Az.Resources" -ListAvailable))
{
    $AccountsModule = Get-Module -Name Az.Accounts -ListAvailable
    $AutomationModule = Get-Module -Name Az.Automation -ListAvailable
    $ResourcesModule = Get-Module -Name Az.Resources -ListAvailable

    Write-Output -InputObject "Running Az.Account version: $($AccountsModule.Version)"
    Write-Output -InputObject "Running Az.Automation version: $($AutomationModule.Version)"
    Write-Output -InputObject "Running Az.Resources version: $($ResourcesModule.Version)"

    Import-Module -Name Az.Accounts, Az.Automation, Az.Resources -ErrorAction Continue -ErrorVariable oErr
    if($oErr)
    {
        Write-Error -Message "Failed to load needed modules for Runbook: Az.Accounts, Az.Automation,Az.Resources" -ErrorAction Continue
        throw "Check AA account for modules"
    }
    Write-Output -InputObject "Using Az modules to execute runbook"
    # This will negate the need to change syntax of AzureRM function names even if using Az modules
    Enable-AzureRmAlias
    $script:AzureModuleFlavor = "Az"
}
elseif((Get-Module -Name AzureRM.Profile -ListAvailable) -and (Get-Module -Name AzureRM.Automation -ListAvailable) -and (Get-Module -Name AzureRM.Resources -ListAvailable))
{
    $ProfileModule = Get-Module -Name AzureRM.Profile -ListAvailable
    $AutomationModule = Get-Module -Name AzureRM.Automation -ListAvailable
    $ResourcesModule = Get-Module -Name AzureRM.Resources -ListAvailable

    Write-Output -InputObject "Running AzureRM.Profile version: $($ProfileModule.Version)"
    Write-Output -InputObject "Running AzureRM.Automation version: $($AutomationModule.Version)"
    Write-Output -InputObject "Running AzureRM.Resources version: $($ResourcesModule.Version)"

    if( ([System.Version]$ProfileModule.Version -le [System.Version]"5.0.0") -and ([System.Version]$AutomationModule.Version -le [System.Version]"5.0.0") -and ([System.Version]$ResourcesModule.Version -le [System.Version]"5.0.0") )
    {
        Write-Warning -Message "Need to update AzureRM base module first before anything else"
        $UpdateAzureRMFirst = $true
    }
    else
    {
        Import-Module -Name AzureRM.Profile, AzureRM.Automation, AzureRM.Resources -ErrorAction Continue -ErrorVariable oErr
        if($oErr)
        {
            Write-Warning -Message "Need to update AzureRM base module first before anything else"
            $UpdateAzureRMFirst = $true
        }
    }
    Write-Output -InputObject "Using AzureRM modules to execute runbook"
    $script:AzureModuleFlavor = "AzureRM"
}
else
{
    Write-Error -Message "Did not find AzureRM or Az modules installed in Automation account" -ErrorAction Stop
}
$VerbosePreference = "continue"

#region Variables
$script:ModulesImported = @()
# track depth of module dependencies import
$script:RecursionDepth = 0
# Make sure not to try to import dependencies of dependencies, like AzureRM module where some of the sub modules have different version dependencies on AzureRM.Accounts
$script:RecursionDepthLimit = 3
#endregion
#region Constants
$script:PsGalleryApiUrl = 'https://www.powershellgallery.com/api/v2'
#endregion

#region Functions
function doModuleImport
{
    param(
        [Parameter(Mandatory = $true)]
        [String] $AutomationResourceGroupName,

        [Parameter(Mandatory = $true)]
        [String] $AutomationAccountName,

        [Parameter(Mandatory = $true)]
        [String] $ModuleName,

        # if not specified latest version will be imported
        [Parameter(Mandatory = $false)]
        [String] $ModuleVersion
    )
    try
    {
        $Filter = @($ModuleName.Trim('*').Split('*') | ForEach-Object { "substringof('$_',Id)" }) -join " and "
        $Url = "$script:PsGalleryApiUrl/Packages?`$filter=$Filter and IsLatestVersion"

        # Fetch results and filter them with -like, and then shape the output
        $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -ErrorAction Continue -ErrorVariable oErr | Where-Object { $_.title.'#text' -like $ModuleName } |
            Select-Object @{n = 'Name'; ex = {$_.title.'#text'}},
        @{n = 'Version'; ex = {$_.properties.version}},
        @{n = 'Url'; ex = {$_.Content.src}},
        @{n = 'Dependencies'; ex = {$_.properties.Dependencies}},
        @{n = 'Owners'; ex = {$_.properties.Owners}}
        If($oErr)
        {
            # Will stop runbook, though message will not be logged
            Write-Error -Message "Failed to retrieve details of module: $ModuleName from Gallery" -ErrorAction Stop
        }
        # Should not be needed as filter will only return one hit, though will keep the code to strip away if search ever get multiple hits
        if($SearchResult.Length -and $SearchResult.Length -gt 1)
        {
            $SearchResult = $SearchResult | Where-Object -FilterScript {
                return $_.Name -eq $ModuleName
            }
        }

        if(-not $SearchResult)
        {
            Write-Warning "Could not find module '$ModuleName' on PowerShell Gallery. This may be a module you imported from a different location"
        }
        else
        {
            $ModuleName = $SearchResult.Name # get correct casing for the module name

            if(-not $ModuleVersion)
            {
                # get latest version
                $ModuleContentUrl = $SearchResult.Url
            }
            else
            {
                $ModuleContentUrl = "$($script:PsGalleryApiUrl)/package/$ModuleName/$ModuleVersion"
            }

            # Make sure module dependencies are imported
            $Dependencies = $SearchResult.Dependencies

            if($Dependencies -and $Dependencies.Length -gt 0)
            {
                # Track recursion depth
                $script:RecursionDepth ++
                $Dependencies = $Dependencies.Split("|")

                # parse dependencies, which are in the format: module1name:module1version:|module2name:module2version:
                $Dependencies | ForEach-Object {

                    if( $_ -and $_.Length -gt 0 )
                    {
                        $Parts = $_.Split(":")
                        $DependencyName = $Parts[0]
                        # Gallery is returning double the same version number on some modules: Az.Aks:[1.0.1, 1.0.1] some do [1.0.1, ]
                        if($Parts[1] -match ",")
                        {
                            $DependencyVersion = (($Parts[1]).Split(","))[0] -replace "[^0-9.]", ''
                        }
                        else
                        {
                            $DependencyVersion = $Parts[1] -replace "[^0-9.]", ''
                        }
                        # check if we already imported this dependency module during execution of this script
                        if( -not $script:ModulesImported.Contains($DependencyName) )
                        {
                            # check if Automation account already contains this dependency module of the right version
                            $AutomationModule = $null
                            $AutomationModule = Get-AzureRMAutomationModule `
                                -ResourceGroupName $AutomationResourceGroupName `
                                -AutomationAccountName $AutomationAccountName `
                                -Name $DependencyName `
                                -ErrorAction SilentlyContinue
                            # Do not downgrade version of module if newer exists in Automation account (limitation of AA that one can only have only one version of a module imported)
                            # limit also recursion depth of dependencies search
                            if( ($script:RecursionDepth -le $script:RecursionDepthLimit) -and ((-not $AutomationModule) -or [System.Version]$AutomationModule.Version -lt [System.Version]$DependencyVersion) )
                            {
                                Write-Output -InputObject "$ModuleName depends on: $DependencyName with version $DependencyVersion, importing this module first"

                                # this dependency module has not been imported, import it first
                                doModuleImport `
                                    -AutomationResourceGroupName $AutomationResourceGroupName `
                                    -AutomationAccountName $AutomationAccountName `
                                    -ModuleName $DependencyName `
                                    -ModuleVersion $DependencyVersion -ErrorAction Continue
                                # Register module has been imported
                                # TODO: If module import fails, do not add and remove the failed imported module from AA account
                                $script:ModulesImported += $DependencyName
                                $script:RecursionDepth --
                            }
                            else
                            {
                                Write-Output -InputObject "$ModuleName has a dependency on: $DependencyName with version: $DependencyVersion, though this is already installed with version: $($AutomationModule.Version)"
                            }
                        }
                        else
                        {
                            Write-Output -InputObject "$DependencyName already imported to Automation account"
                        }
                    }
                }
            }

            # Find the actual blob storage location of the module
            do
            {
                $ActualUrl = $ModuleContentUrl
                $ModuleContentUrl = (Invoke-WebRequest -Uri $ModuleContentUrl -MaximumRedirection 0 -UseBasicParsing -ErrorAction SilentlyContinue).Headers.Location
            }
            while(-not ($ModuleContentUrl.Contains(".nupkg")) )

            $ActualUrl = $ModuleContentUrl

            if($ModuleVersion)
            {
                Write-Output -InputObject "Importing version: $ModuleVersion of module: $ModuleName to Automation account"
            }
            else
            {
                Write-Output -InputObject "Importing version: $($SearchResult.Version) of module: $ModuleName to Automation account"
            }
            if(-not ([string]::IsNullOrEmpty($ActualUrl)))
            {
                $AutomationModule = New-AzureRMAutomationModule `
                    -ResourceGroupName $AutomationResourceGroupName `
                    -AutomationAccountName $AutomationAccountName `
                    -Name $ModuleName `
                    -ContentLink $ActualUrl -ErrorAction continue
                $oErr = $null
                while(
                    (-not ([string]::IsNullOrEmpty($AutomationModule))) -and
                    $AutomationModule.ProvisioningState -ne "Created" -and
                    $AutomationModule.ProvisioningState -ne "Succeeded" -and
                    $AutomationModule.ProvisioningState -ne "Failed" -and
                    [string]::IsNullOrEmpty($oErr)
                )
                {
                    Start-Sleep -Seconds 5
                    Write-Verbose -Message "Polling module import status for: $($AutomationModule.Name)"
                    $AutomationModule = $AutomationModule | Get-AzureRMAutomationModule -ErrorAction silentlycontinue -ErrorVariable oErr
                    if($oErr)
                    {
                        Write-Error -Message "Error fetching module status for: $($AutomationModule.Name)" -ErrorAction Continue
                    }
                    else
                    {
                        Write-Verbose -Message "Module import pull status: $($AutomationModule.ProvisioningState)"
                    }
                }
                if( ($AutomationModule.ProvisioningState -eq "Failed") -or $oErr )
                {
                    Write-Error -Message "Import of $($AutomationModule.Name) module to Automation account failed." -ErrorAction Continue
                    Write-Output -InputObject "Import of $($AutomationModule.Name) module to Automation account failed."
                    $oErr = $null
                }
                else
                {
                    Write-Output -InputObject "Import of $ModuleName module to Automation account succeeded."
                }
            }
            else
            {
                Write-Error -Message "Failed to retrieve download URL of module: $ModuleName in Gallery, update of module aborted" -ErrorId continue
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
}
#endregion

#region Main
try
{
    $RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection" -ErrorAction Stop
    if($RunAsConnection)
    {
        Write-Output -InputObject ("Logging in to Azure...")
        $Null = Add-AzureRMAccount `
            -ServicePrincipal `
            -TenantId $RunAsConnection.TenantId `
            -ApplicationId $RunAsConnection.ApplicationId `
            -CertificateThumbprint $RunAsConnection.CertificateThumbprint -ErrorAction Continue -ErrorVariable oErr
        if($oErr)
        {
            Write-Error -Message "Failed to connect to Azure" -ErrorAction Stop
        }
        Write-Verbose -Message "Selecting subscription to use"
        $Subscription = Select-AzureRMSubscription -SubscriptionId $RunAsConnection.SubscriptionID -ErrorAction Continue -ErrorVariable oErr
        if($oErr)
        {
            Write-Error -Message "Failed to select Azure subscription" -ErrorAction Stop
        }
        else
        {
            Write-Output -InputObject "Running in subscription: $($Subscription.Subscription.Name)"
        }
        if( (-not $DebugLocal) -and (-not $UpdateAzureRMFirst) )
        {
            Write-Verbose -Message "Attempting to discover AA account"
            # Find automation account if account name and resource group name not defined as input
            if(([string]::IsNullOrEmpty($AutomationResourceGroupName)) -or ([string]::IsNullOrEmpty($AutomationAccountName)))
            {
                Write-Verbose -Message ("Finding the ResourceGroup and AutomationAccount that this job is running in ...")
                if ([string]::IsNullOrEmpty($PSPrivateMetadata.JobId.Guid) )
                {
                    Write-Error -Message "This is not running from the automation service. Please specify ResourceGroupName and AutomationAccountName as parameters" -ErrorAction Stop
                }

                $AutomationResource = Get-AzureRMResource -ResourceType Microsoft.Automation/AutomationAccounts -ErrorAction Stop

                foreach ($Automation in $AutomationResource)
                {
                    $Job = Get-AzureRMAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
                    if (!([string]::IsNullOrEmpty($Job)))
                    {
                        $AutomationResourceGroupName = $Job.ResourceGroupName
                        $AutomationAccountName = $Job.AutomationAccountName
                        break;
                    }
                }
                if($AutomationAccountName)
                {
                    Write-Output -InputObject "Using AA account: $AutomationAccountName in resource group: $AutomationResourceGroupName"
                }
                else
                {
                    Write-Error -Message "Failed to discover automation account, execution stopped" -ErrorAction Stop
                }
            }
        }
        else
        {
            Write-Verbose -Message "Either first time run, or debugging has been activated"
            if(([string]::IsNullOrEmpty($AutomationResourceGroupName)) -or ([string]::IsNullOrEmpty($AutomationAccountName)))
            {
                Write-Error -Message "When debugging locally or first run on new AA account, ResourceGroupName and AutomationAccountName parameters must be provided in input" -ErrorAction Stop
            }
        }
    }
    else
    {
        Write-Error -Message "Check that AzureRunAsConnection is configured for AA account: $AutomationAccountName" -ErrorAction Stop
    }
    if($UpdateAzureRMFirst)
    {
        Write-Warning -Message "Forcing update of AzureRM base modules first, run again to import desired modules"
        $NewModuleNames = $null
        $NewModuleNames = @("AzureRM.Profile", "AzureRM.Automation", "AzureRM.Resources")
    }
    else
    {
        $Modules = Get-AzureRMAutomationModule `
        -ResourceGroupName $AutomationResourceGroupName `
        -AutomationAccountName $AutomationAccountName -ErrorAction continue -ErrorVariable oErr
        if($oErr)
        {
            Write-Error -Message "Failed to retrieve modules in AA account $AutomationAccountName" -ErrorAction Stop
        }
    }

    # Import module if specified
    if (!([string]::IsNullOrEmpty($NewModuleNames)))
    {
         foreach($NewModuleName in $NewModuleNames)
         {
            # Check if module exists in the gallery
            $Filter = @($NewModuleName.Trim('*').Split('*') | ForEach-Object { "substringof('$_',Id)" }) -join " and "
            $Url = "$script:PsGalleryApiUrl/Packages?`$filter=$Filter and IsLatestVersion"

            # Fetch results and filter them with -like, and then shape the output
            $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -ErrorAction Continue -ErrorVariable oErr | Where-Object { $_.title.'#text' -like $NewModuleName } |
                Select-Object @{n = 'Name'; ex = {$_.title.'#text'}},
            @{n = 'Version'; ex = {$_.properties.version}},
            @{n = 'Url'; ex = {$_.Content.src}},
            @{n = 'Dependencies'; ex = {$_.properties.Dependencies}},
            @{n = 'Owners'; ex = {$_.properties.Owners}}
            If($oErr)
            {
                # Will stop runbook, though message will not be logged
                Write-Error -Message "Failed to query Gallery" -ErrorAction Stop
            }

            if($SearchResult.Length -and $SearchResult.Length -gt 1)
            {
                $SearchResult = $SearchResult | Where-Object -FilterScript {
                    return $_.Name -eq $NewModuleName
                }
            }

            if(!$SearchResult)
            {
                throw "Could not find module '$NewModuleName' on PowerShell Gallery."
            }

            if ($NewModuleName -notin $Modules.Name -or $Force)
            {
                Write-Output -InputObject "Importing latest version of '$NewModuleName' into your automation account"

                doModuleImport `
                    -AutomationResourceGroupName $AutomationResourceGroupName `
                    -AutomationAccountName $AutomationAccountName `
                    -ModuleName $NewModuleName -ErrorAction Continue
            }
            else
            {
                Write-Output -InputObject "Module $NewModuleName is already imported to the automation account"
            }
        }
    }
    else
    {
        Write-Warning -Message "No Module name to import was entered"
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
    if($AzureModuleFlavor -eq "Az")
    {
        Disable-AzureRmAlias
    }
}
#endregion Main