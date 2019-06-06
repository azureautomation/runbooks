#Requires -Module AzureRM.Profile, AzureRM.Automation,AzureRM.Resources

<#
.SYNOPSIS
    This Azure Automation runbook imports a module and all of it's dependencies into AA from PowerShell Gallery

.DESCRIPTION
    This Azure Automation runbook imports a module named as parameter input to AA from PowerShell Gallery.

.PARAMETER ResourceGroupName
    Optional. The name of the Azure Resource Group containing the Automation account to update all modules for.
    If a resource group is not specified, then it will use the current one for the automation account
    if it is run from the automation service

.PARAMETER AutomationAccountName
    Optional. The name of the Automation account to update all modules for.
    If an automation account is not specified, then it will use the current one for the automation account
    if it is run from the automation service
.EXAMPLE
    Import-PSGalleryModulesInAA -ResourceGroupName "MyResourceGroup" -AutomationAccountName "MyAutomationAccount" -NewModuleName "Az"
    Import-PSGalleryModulesInAA -NewModuleName "Az"

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
    [String] $NewModuleName
)
$VerbosePreference = "silentlycontinue"
$RunbookName = "Import-PSGalleryModulesInAA"
Write-Output -InputObject "Starting Runbook: $RunbookName at time: $(get-Date -format r).`nRunning PS version: $($PSVersionTable.PSVersion)`nOn host: $($env:computername)"
Import-Module -Name AzureRM.Profile, AzureRM.Automation,AzureRM.Resources -ErrorAction Continue -ErrorVariable oErr
if($oErr)
{
    Write-Error -Message "Failed to load needed modules for Runbook: AzureRM.Profile, AzureRM.Automation,AzureRM.Resources" -ErrorAction Continue
    throw "Check AA account for modules"
}
$VerbosePreference = "continue"
$ErrorActionPreference = "stop"
$ModulesImported = @()

#region Constants
$script:PsGalleryApiUrl = 'https://www.powershellgallery.com/api/v2'
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
    try {
        $Filter = @($ModuleName.Trim('*').Split('*') | ForEach-Object { "substringof('$_',Id)" }) -join " and "
        $Url = "$script:PsGalleryApiUrl/Packages?`$filter=$Filter and IsLatestVersion"

        # Fetch results and filter them with -like, and then shape the output
        $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -ErrorAction Continue -ErrorVariable oErr | Where-Object { $_.title.'#text' -like $ModuleName } |
        Select-Object @{n='Name';ex={$_.title.'#text'}},
                    @{n='Version';ex={$_.properties.version}},
                    @{n='Url';ex={$_.Content.src}},
                    @{n='Dependencies';ex={$_.properties.Dependencies}},
                    @{n='Owners';ex={$_.properties.Owners}}
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
                $ModuleContentUrl = "$($script:PsGalleryApiUrl)/package/$ModuleName/$ModuleVersion"
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
                        # Gallery is returning double the same version on some modules: Az.Aks:[1.0.1, 1.0.1] some do [1.0.1, ]
                        if($Parts[1] -match ",")
                        {
                            $DependencyVersion = (($Parts[1]).Split(","))[0] -replace "[^0-9.]", ''
                        }
                        else
                        {
                            $DependencyVersion = $Parts[1] -replace "[^0-9.]", ''
                        }

                        # check if we already imported this dependency module during execution of this script
                        if(!$ModulesImported.Contains($DependencyName)) {
                            # Log errors if occurs
                            $AutomationModule = Get-AzureRmAutomationModule `
                                -ResourceGroupName $ResourceGroupName `
                                -AutomationAccountName $AutomationAccountName `
                                -Name $DependencyName `
                                -ErrorAction silentlycontinue

                            # check if Automation account already contains this dependency module of the right version
                            if((!$AutomationModule) -or $AutomationModule.Version -ne $DependencyVersion) {

                                Write-Output -InputObject "Importing dependency module $DependencyName with version $DependencyVersion first."

                                # this dependency module has not been imported, import it first
                                doModuleImport `
                                    -ResourceGroupName $ResourceGroupName `
                                    -AutomationAccountName $AutomationAccountName `
                                    -ModuleName $DependencyName `
                                    -ModuleVersion $DependencyVersion -ErrorAction Continue

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
                $ModuleContentUrl = (Invoke-WebRequest -Uri $ModuleContentUrl -MaximumRedirection 0 -UseBasicParsing -ErrorAction SilentlyContinue).Headers.Location
            }
            while(-not ($ModuleContentUrl.Contains(".nupkg")) )

            $ActualUrl = $ModuleContentUrl

            if($ModuleVersion)
            {
                Write-Output -InputObject "Importing version: $ModuleVersion of module: $ModuleName module to Automation account"
            }
            else
            {
                Write-Output -InputObject "Importing version: $($SearchResult.Version) of module: $ModuleName module to Automation account"
            }
            if(-not ([string]::IsNullOrEmpty($ActualUrl)))
            {
                $AutomationModule = New-AzureRmAutomationModule `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $ModuleName `
                -ContentLink $ActualUrl -ErrorAction continue
                while(
                    (!([string]::IsNullOrEmpty($AutomationModule))) -and
                    $AutomationModule.ProvisioningState -ne "Created" -and
                    $AutomationModule.ProvisioningState -ne "Succeeded" -and
                    $AutomationModule.ProvisioningState -ne "Failed" -and
                    $Null -eq $oErr
                )
                {
                    Write-Verbose -Message "Polling for module import completion"
                    Start-Sleep -Seconds 10
                    $AutomationModule = $AutomationModule | Get-AzureRmAutomationModule -ErrorAction silentlycontinue -ErrorVariable oErr
                }
                if($AutomationModule.ProvisioningState -eq "Failed" -or $oErr -ne $Null) {
                    Write-Error "Import of $ModuleName module to Automation account failed." -ErrorAction Continue
                    $oErr = $Null
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

        $Null = Add-AzureRmAccount `
            -ServicePrincipal `
            -TenantId $RunAsConnection.TenantId `
            -ApplicationId $RunAsConnection.ApplicationId `
            -CertificateThumbprint $RunAsConnection.CertificateThumbprint -ErrorAction Continue -ErrorVariable oErr
        if($oErr)
        {
            Write-Error -Message "Failed to connect to Azure" -ErrorAction Stop
        }
        $Subscription = Select-AzureRmSubscription -SubscriptionId $RunAsConnection.SubscriptionID -ErrorAction Continue -ErrorVariable oErr
        Write-Output -InputObject "Running in subscription: $($Subscription.Name)"
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

            $AutomationResource = Get-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts -ErrorAction Stop

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
            Write-Output -InputObject "Using AA account: $AutomationAccountName in resource group: $ResourceGroupName"
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
    # Import module if specified
    if (!([string]::IsNullOrEmpty($NewModuleName)))
    {
        # Check if module exists in the gallery
        $Filter = @($NewModuleName.Trim('*').Split('*') | ForEach-Object { "substringof('$_',Id)" }) -join " and "
        $Url = "$script:PsGalleryApiUrl/Packages?`$filter=$Filter and IsLatestVersion"

        # Fetch results and filter them with -like, and then shape the output
        $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -ErrorAction Continue -ErrorVariable oErr | Where-Object { $_.title.'#text' -like $NewModuleName } |
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
                -ModuleName $NewModuleName -ErrorAction Continue
        }
        else
        {
            Write-Output -InputObject ("Module $NewModuleName is already in the automation account")
        }
    }
    else
    {
        Write-Warning -Message "No Module name was entered"
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