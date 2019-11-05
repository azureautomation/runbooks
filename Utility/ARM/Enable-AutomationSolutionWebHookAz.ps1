<#
.SYNOPSIS
    This sample automation runbook onboards an Azure VM for either the Update or ChangeTracking (which includes Inventory) solution.
    It requires an existing Azure VM to already be onboarded to the solution as it uses this information to onboard the
    new VM to the same Log Analytics workspace and Automation Account.
    The Runbook will search for an existing VM in both the onboarding VMs subscription and in the AA subscription.
    It is required to run this from an Automation account, and it's RunAs account will need contributor access rights to the subscription the onboaring VM is in.

    To set what Log Analytics workspace to use for Update and Change Tracking management (bypassing the logic that search for an existing onboarded VM),
    create the following AA variable assets:
        LASolutionSubscriptionId and populate with subscription ID of where the Log Analytics workspace is located
        LASolutionWorkspaceId and populate with the Workspace Id of the Log Analytics workspace

.DESCRIPTION
    This sample automation runbook onboards an Azure VM for either the Update or ChangeTracking (which includes Inventory) solution.
    It requires an existing Azure VM to already be onboarded to the solution as it uses this information to onboard the
    new VM to the same Log Analytics workspace and Automation Account.
    This Runbook needs to be run from the Automation account that you wish to connect the new VM to.

.COMPONENT
    To predefine what Log Analytics workspace to use, create the following AA variable assets:
        LASolutionSubscriptionId
        LASolutionWorkspaceId

.PARAMETER WebHookData
    The following parameters will need to be passed as a JSON object for this runbook to function correctly:
        VMSubscriptionName:
                The name subscription where the new VM to onboard is located.
                This will default to the same one as the azure automation account if not specified. If you
                give a different subscription id then you need to make sure the RunAs account for
                this automation account is added as a contributor to this subscription also.
        VMResourceGroupName:
                Required. The name of the resource group that the VM is a member of.
        VMName:
                Required. The name of a specific VM that you want onboarded to the Updates or ChangeTracking solution
        SolutionType:
                Defaults to "Updates" if not set. The name of the solution to onboard to this Automation account.
                It must be either "Updates" or "ChangeTracking". ChangeTracking also includes the inventory solution.
        UpdateScopeQuery:
                Optional. Default is true. Indicates whether to add this VM to the list of computers to enable for this solution.
                Solutions enable an optional scope configuration to be set on them that contains a query of computers
                to target the solution to. If you are calling this Runbook from a parent runbook that is onboarding
                multiple VMs concurrently, then you will want to set this to false and then do a final update of the
                search query with the list of onboarded computers to avoid any possible conflicts that this Runbook
                might do when reading, adding this VM, and updating the query since multiple versions of this Runbook
                might try and do this at the same time if run concurrently.

.NOTES
    AUTHOR: Automation Team
    Contributor: Morten Lerudjordet
#>
#Requires -Version 5.0
Param (
    [Parameter(Mandatory = $true)]
    [Object]$WebHookData
)
try
{
    $RunbookName = "Enable-AutomationSolutionWebHookAz"
    Write-Output -InputObject "Starting Runbook: $RunbookName at time: $(get-Date -format r).`nRunning PS version: $($PSVersionTable.PSVersion)`nOn host: $($env:computername)"

    # Parse input
    if ($Null -ne $WebHookData)
    {
        if ($Null -ne $WebhookData.RequestBody)
        {
            $ObjectData = ConvertFrom-Json -InputObject $WebhookData.RequestBody
            if ($Null -ne $ObjectData.VMSubscriptionId -and "" -ne $ObjectData.VMSubscriptionId)
            {
                $VMSubscriptionName = $ObjectData.VMSubscriptionName
            }
            else
            {
                Write-Warning -Message "Missing VMSubscriptionId in input data, will assume VM to onboard is in same subscription as Azure Automation account"
                $VMSubscriptionName = $Null
            }
            if ($Null -ne $ObjectData.VMResourceGroupName -and "" -ne $ObjectData.VMResourceGroupName)
            {
                $VMResourceGroupName = $ObjectData.VMResourceGroupName
            }
            else
            {
                Write-Error -Message "Missing VMResourceGroupName in input data" -ErrorAction Stop
            }
            if ($Null -ne $ObjectData.VMName -and "" -ne $ObjectData.VMName)
            {
                $VMName = $ObjectData.VMName
            }
            else
            {
                Write-Error -Message "Missing VMName in input data" -ErrorAction Stop
            }
            if ($Null -ne $ObjectData.SolutionType -and "" -ne $ObjectData.SolutionType)
            {
                if ($ObjectData.SolutionType -cne "Updates" -and $ObjectData.SolutionType -cne "ChangeTracking")
                {
                    $SolutionType = $ObjectData.SolutionType
                }
                else
                {
                    Write-Error -Message "Only a solution type of Updates or ChangeTracking is currently supported. These are case sensitive." -ErrorAction Stop
                }
            }
            else
            {
                Write-Warning -Message "Missing SolutionType in input data, using default set to Updates"
                $SolutionType = "Updates"
            }
            if ($Null -ne $ObjectData.UpdateScopeQuery -and "" -ne $ObjectData.UpdateScopeQuery)
            {
                $UpdateScopeQuery = $ObjectData.UpdateScopeQuery
            }
            else
            {
                Write-Verbose -Message "Missing UpdateScopeQuery in input data, using default set to True"
                $UpdateScopeQuery = $true
            }
        }
        else
        {
            Write-Error -Message "Input data in request body is empty " -ErrorAction Stop
        }

    }
    else
    {
        Write-Error -Message "Input data from webhook is empty" -ErrorAction Stop
    }

    $VerbosePreference = "silentlycontinue"
    Import-Module -Name Az.Accounts, Az.Automation, Az.OperationalInsights, Az.Compute, Az.Resources -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to load needed modules for Runbook, check that Az.Automation, Az.OperationalInsights, Az.Compute and Az.Resources is imported into Azure Automation" -ErrorAction Stop
    }
    $VerbosePreference = "Continue"

    #region Variables
    ############################################################
    #   Variables
    ############################################################
    # Check if AA asset variable is set  for Log Analytics workspace subscription ID to use
    $LogAnalyticsSolutionSubscriptionId = Get-AutomationVariable -Name "LASolutionSubscriptionId" -ErrorAction SilentlyContinue
    if ($Null -ne $LogAnalyticsSolutionSubscriptionId)
    {
        Write-Verbose -Message "Using AA asset variable for Log Analytics subscription id"
    }
    else
    {
        Write-Verbose -Message "Will try to discover Log Analytics subscription id"
    }

    # Check if AA asset variable is set  for Log Analytics workspace ID to use
    $LogAnalyticsSolutionWorkspaceId = Get-AutomationVariable -Name "LASolutionWorkspaceId" -ErrorAction SilentlyContinue
    if ($Null -ne $LogAnalyticsSolutionWorkspaceId)
    {
        Write-Verbose -Message "Using AA asset variable for Log Analytics workspace id"
    }
    else
    {
        Write-Verbose -Message "Will try to discover Log Analytics workspace id"
    }
    $OldLogAnalyticsAgentExtensionName = "OMSExtension"
    $NewLogAnalyticsAgentExtensionName = "MicrosoftMonitoringAgent"
    $LogAnalyticsLinuxAgentExtensionName = "OmsAgentForLinux"

    $MMAApiVersion = "2018-10-01"
    $WorkspacesApiVersion = "2017-04-26-preview"
    $SolutionApiVersion = "2017-04-26-preview"
    #endregion

    # Fetch AA RunAs account detail from connection object asset
    $ServicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection" -ErrorAction Stop
    $Null = Add-AzAccount `
        -ServicePrincipal `
        -TenantId $ServicePrincipalConnection.TenantId `
        -ApplicationId $ServicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to connect to Azure" -ErrorAction Stop
    }

    # Set subscription of AA account
    $SubscriptionContext = Set-AzContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to set azure context to subscription for AA" -ErrorAction Stop
    }
    else
    {
        Write-Verbose -Message "Set subscription for AA to: $($SubscriptionContext.Subscription.Name)"
    }
    # set subscription of VM onboarded, else assume its in the same as the AA account
    if ([string]::IsNullOrEmpty($VMSubscriptionName))
    {
        # Use the same subscription as the Automation account if not passed in
        $NewVMSubscriptionContext = Set-AzContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to set azure context to subscription for AA" -ErrorAction Stop
        }
        Write-Verbose -Message "Creating azure VM context using subscription: $($NewVMSubscriptionContext.Subscription.Name)"

    }
    else
    {
        # VM is in a different subscription so set the context to this subscription
        $NewVMSubscriptionContext = Set-AzContext -Subscription $VMSubscriptionName -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to set azure context to subscription where VM is. Make sure AA RunAs account has contributor rights" -ErrorAction Stop
        }
        Write-Verbose -Message "Creating azure VM context using subscription: $($NewVMSubscriptionContext.Subscription.Name)"
        # Register Automation provider if it is not registered on the subscription
        $AutomationProvider = Get-AzResourceProvider -ProviderNamespace Microsoft.Automation `
            -AzContext $NewVMSubscriptionContext |  Where-Object {$_.RegistrationState -eq "Registered"}
        if ($Null -eq $AutomationProvider)
        {
            $ObjectOutPut = Register-AzResourceProvider -ProviderNamespace Microsoft.Automation -AzContext $NewVMSubscriptionContext -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to register Microsoft.Automation provider in: $($NewVMSubscriptionContext.Subscription.Name)" -ErrorAction Stop
            }
        }
    }

    # set subscription of Log Analytic workspace used for Update Management and Change Tracking, else assume its in the same as the AA account
    if ($Null -ne $LogAnalyticsSolutionSubscriptionId)
    {
        # VM is in a different subscription so set the context to this subscription
        $LASubscriptionContext = Set-AzContext -SubscriptionId $LogAnalyticsSolutionSubscriptionId -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to set azure context to subscription where Log Analytics workspace is" -ErrorAction Stop
        }
        Write-Verbose -Message "Creating Log Analytics context using subscription: $($LASubscriptionContext.Subscription.Name)"
    }

    # Check if Log Analytics workspace is set through a AA asset
    if ($Null -eq $LogAnalyticsSolutionWorkspaceId)
    {
        # Set order to sort subscriptions by
        $SortOrder = @($NewVMSubscriptionContext.Subscription.Name, $SubscriptionContext.Subscription.Name)
        # Get all subscriptions the AA account has access to
        $AzSubscriptions = (Get-AzSubscription).where({$_.State -eq "Enabled"}) |
            # Sort array so VM subscription will be search first for exiting onboarded VMs, then it will try AA subscription before moving on to others it has access to
        Sort-Object -Property {
            $SortRank = $SortOrder.IndexOf($($_.Name.ToLower()))
            if ($SortRank -ne -1)
            {
                $SortRank
            }
            else
            {
                [System.Double]::PositiveInfinity
            }
        }

        if ($Null -ne $AzSubscriptions)
        {
            # Run through each until a VM with Microsoft Monitoring Agent is found
            $SubscriptionCounter = 0
            foreach ($Azsubscription in $Azsubscriptions)
            {
                # Set subscription context
                $OnboardedVMSubscriptionContext = Set-AzContext -SubscriptionId $AzSubscription.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
                if ($oErr)
                {
                    Write-Error -Message "Failed to set azure context to subscription: $($AzSubscription.Name)" -ErrorAction Continue
                    $oErr = $Null
                }
                if ($Null -ne $OnboardedVMSubscriptionContext)
                {
                    # Find existing VM that is already onboarded to the solution.
                    $VMExtensions = Get-AzResource -ResourceType "Microsoft.Compute/virtualMachines/extensions" -AzContext $OnboardedVMSubscriptionContext |
                        Where-Object {($_.Name -like "*/$NewLogAnalyticsAgentExtensionName") -or ($_.Name -like "*/$OldLogAnalyticsAgentExtensionName") -or ($_.Name -like "*/$LogAnalyticsLinuxAgentExtensionName")}

                    # Find VM to use as template
                    if ($Null -ne $VMExtensions)
                    {
                        Write-Verbose -Message "Found $($VMExtensions.Count) VM(s) with Microsoft Monitoring Agent installed"
                        # Break out of loop if VM with Microsoft Monitoring Agent installed is found in a subscription
                        break
                    }
                }
                $SubscriptionCounter++
                if ($SubscriptionCounter -eq $AzSubscriptions.Count)
                {
                    Write-Error -Message "Did not find any VM with Microsoft Monitoring Agent already installed. Install at least one in a subscription the AA RunAs account has access to" -ErrorAction Stop
                }
            }
            $VMCounter = 0
            foreach ($VMExtension in $VMExtensions)
            {
                if ($Null -ne $VMExtension.Name -and $Null -ne $VMExtension.ResourceGroupName)
                {
                    $ExistingVMExtension = Get-AzVMExtension -ResourceGroup $VMExtension.ResourceGroupName -VMName ($VMExtension.Name).Split('/')[0] `
                        -AzContext $OnboardedVMSubscriptionContext -Name ($VMExtension.Name).Split('/')[-1]
                }
                if ($Null -ne $ExistingVMExtension)
                {
                    Write-Verbose -Message "Retrieved extension config from VM: $($ExistingVMExtension.VMName)"
                    # Found VM with Microsoft Monitoring Agent installed
                    break
                }
                $VMCounter++
                if ($VMCounter -eq $VMExtensions.Count)
                {
                    Write-Error -Message "Failed to find an already onboarded VM with the Microsoft Monitoring Agent installed (Log Analytics) in subscription: $($NewVMSubscriptionContext.Subscription.Name), $($SubscriptionContext.Subscription.Nam)" -ErrorAction Stop
                }
            }
        }
        else
        {
            Write-Error -Message "Make sure the AA RunAs account has contributor rights on all subscriptions in play." -ErrorAction Stop
        }
        # Check if the existing VM is already onboarded
        if ($ExistingVMExtension.PublicSettings)
        {
            $PublicSettings = ConvertFrom-Json $ExistingVMExtension.PublicSettings
            if ($Null -eq $PublicSettings.workspaceId)
            {
                Write-Error -Message "This VM: $($ExistingVMExtension.VMName) is not onboarded. Please onboard first as it is used to collect information" -ErrorAction Stop
            }
            else
            {
                Write-Verbose -Message "VM: $($ExistingVMExtension.VMName) is correctly onboarded and can be used as template to onboard: $VMName"
            }
        }
        else
        {
            Write-Error -Message "Public settings for VM extension is empty" -ErrorAction Stop
        }
        # Get information about the workspace
        $WorkspaceInfo = Get-AzOperationalInsightsWorkspace -AzContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr `
            | Where-Object {$_.CustomerId -eq $PublicSettings.workspaceId}
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve Operational Insight workspace information" -ErrorAction Stop
        }
        if ($Null -ne $WorkspaceInfo)
        {
            # Workspace information
            $WorkspaceResourceGroupName = $WorkspaceInfo.ResourceGroupName
            $WorkspaceName = $WorkspaceInfo.Name
            $WorkspaceResourceId = $WorkspaceInfo.ResourceId
            $WorkspaceId = $WorkspaceInfo.CustomerId
            $WorkspaceLocation = $WorkspaceInfo.Location
        }
        else
        {
            Write-Error -Message "Failed to retrieve Log Analytics workspace information" -ErrorAction Stop
        }
        # Get the saved group that is used for solution targeting so we can update this with the new VM during onboarding..
        $SavedGroups = Get-AzOperationalInsightsSavedSearch -ResourceGroupName $WorkspaceResourceGroupName `
            -WorkspaceName $WorkspaceName -AzContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve Log Analytics saved groups info" -ErrorAction Stop
        }
    }
    # Log Analytics workspace to use is set through AA assets
    else
    {
        if ($Null -ne $LASubscriptionContext)
        {
            # Get information about the workspace
            $WorkspaceInfo = Get-AzOperationalInsightsWorkspace -AzContext $LASubscriptionContext -ErrorAction Continue -ErrorVariable oErr `
                | Where-Object {$_.CustomerId -eq $LogAnalyticsSolutionWorkspaceId}
            if ($oErr)
            {
                Write-Error -Message "Failed to retrieve Log Analytics workspace information" -ErrorAction Stop
            }
            if ($Null -ne $WorkspaceInfo)
            {
                # Workspace information
                $WorkspaceResourceGroupName = $WorkspaceInfo.ResourceGroupName
                $WorkspaceName = $WorkspaceInfo.Name
                $WorkspaceResourceId = $WorkspaceInfo.ResourceId
                $WorkspaceId = $WorkspaceInfo.CustomerId
                $WorkspaceLocation = $WorkspaceInfo.Location
            }
            else
            {
                Write-Error -Message "Failed to retrieve Log Analytics workspace information" -ErrorAction Stop
            }
        }
        else
        {
            Write-Error -Message "Log Analytics subscription context not set, check AA assets has correct value and AA runAs account has access to subscription." -ErrorAction Stop
        }
    }

    Write-Verbose -Message "Retrieving VM with following details: RG: $VMResourceGroupName, Name: $VMName, SubName: $($NewVMSubscriptionContext.Subscription.Name)"
    # Get details of the new VM to onboard.
    $NewVM = Get-AzVM -ResourceGroupName $VMResourceGroupName -Name $VMName -Status `
        -AzContext $NewVMSubscriptionContext -ErrorAction Continue -ErrorVariable oErr | Where-Object {$_.Statuses.code -match "running"}
    if ($oErr)
    {
        Write-Error -Message "Failed to retrieve VM status data for: $VMName" -ErrorAction Stop
    }

    # Verify that VM is up and running before installing extension
    if ($Null -eq $NewVM)
    {
        Write-Error -Message "VM: $($NewVM.Name) is not running and can therefore not install extension" -ErrorAction Stop
    }
    else
    {
        $NewVM = Get-AzVM -ResourceGroupName $VMResourceGroupName -Name $VMName `
            -AzContext $NewVMSubscriptionContext -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve VM data for: $VMName" -ErrorAction Stop
        }
        if ($Null -ne $NewVM)
        {
            # New VM information
            $VMResourceGroupName = $NewVM.ResourceGroupName
            $VMName = $NewVM.Name
            $VMLocation = $NewVM.Location
            $VMId = $NewVM.VMId
            $VMIdentityRequired = $false
        }
        else
        {
            Write-Error -Message "Failed to retrieve VM data for: $VMName" -ErrorAction Stop
        }
    }
    if ($NewVM.StorageProfile.OSDisk.OSType -eq "Linux")
    {
        # Check if Linux MMA extension is installed
        Write-Verbose -Message "Checking if Linux MMA extension is already installed"
        $Onboarded = Get-AzVMExtension -ResourceGroup $VMResourceGroupName -VMName $VMName `
                        -Name $LogAnalyticsLinuxAgentExtensionName -AzContext $NewVMSubscriptionContext -ErrorAction SilentlyContinue -ErrorVariable oErr
        if ($oErr)
        {
            if ($oErr.Exception.Message -match "ResourceNotFound")
            {
                # VM does not have OMS extension installed
                $Onboarded = $Null
                Write-Verbose -Message "Linux MMA extension is not installed"
            }
            else
            {
                Write-Error -Message "Failed to retrieve extension data from VM: $VMName" -ErrorAction Stop
            }
        }
        # If installed fetch VMUUID tag
        else
        {
            Write-Verbose -Message "Linux MMA extension is already installed"
            if(-not $NewVM.Tags.VMUUID)
            {
                Write-Output -InputObject "No VMUUID tag found for VM: $VMName. Can therefore not check if VM is already added to Log Analytics solution search"
                $VMId = $null
            }
            else
            {
                $VMId = $NewVM.Tags.VMUUID
                Write-Verbose -Message "Linux VM: $VMName has VMUUID tag set to: $VMId"
            }
        }
    }
    else
    {
        # Check if the Windows VM is already onboarded to the Log Analytics workspace
        Write-Verbose -Message "Checking if Windows MMA extension is already installed"
        $Onboarded = Get-AzVMExtension -ResourceGroup $VMResourceGroupName -VMName $VMName `
            -Name $NewLogAnalyticsAgentExtensionName -AzContext $NewVMSubscriptionContext -ErrorAction SilentlyContinue -ErrorVariable oErr
        if ($oErr)
        {
            if ($oErr.Exception.Message -match "ResourceNotFound")
            {
                # VM does not have OMS extension installed
                $Onboarded = $Null
                Write-Verbose -Message "Windows MMA extension is not installed"
            }
            else
            {
                Write-Error -Message "Failed to retrieve extension data from VM: $VMName" -ErrorAction Stop
            }
        }
        else
        {
            Write-Verbose -Message "Windows MMA extension is already installed"
        }
        # Check if old extension name is in use
        if(-not $Onboarded)
        {
            $Onboarded = Get-AzVMExtension -ResourceGroup $VMResourceGroupName -VMName $VMName `
                    -Name $OldLogAnalyticsAgentExtensionName -AzContext $NewVMSubscriptionContext -ErrorAction SilentlyContinue -ErrorVariable oErr
            if ($oErr)
            {
                if ($oErr.Exception.Message -match "ResourceNotFound")
                {
                    # VM does not have OMS extension installed
                    $Onboarded = $Null
                }
                else
                {
                    Write-Error -Message "Failed to retrieve extension data from VM: $VMName" -ErrorAction Stop
                }

            }
        }
    }
    if ($Null -eq $Onboarded)
    {
        # Set up MMA extension information to onboard VM to the workspace
        if ($NewVM.StorageProfile.OSDisk.OSType -eq "Linux")
        {
            $MMAExentsionName = $LogAnalyticsLinuxAgentExtensionName
            $MMAOStype = $LogAnalyticsLinuxAgentExtensionName
            $MMATypeHandlerVersion = "1.7"
            Write-Output -InputObject "Deploying MMA extension to Linux VM"

            # Check if Linux VM is already onboarded
            if(-not $NewVM.Tags.VMUUID)
            {
                $RunCommand = "sudo dmidecode | grep UUID"
                $TempScript = New-TemporaryFile
                $RunCommand | Out-File -FilePath $TempScript.FullName

                # Fetch UUID from VM
                Write-Output -InputObject "Retrieving internal UUID from Linux VM to use for onboarding to solution"
                $ResultCommand = Invoke-AzVMRunCommand -VM $NewVM -CommandId "RunShellScript" -ScriptPath $TempScript.FullName -ErrorAction Continue -ErrorVariable oErr
                Remove-Item -Path $TempScript.FullName -Force
                if ($oErr)
                {
                    Write-Error -Message "Failed to run script command to retrieve VMUUID from Linux VM" -ErrorAction Stop
                }
                else
                {
                    if($ResultCommand.Status -eq "Succeeded")
                    {
                        $VMId =(Select-String -InputObject $ResultCommand.value.message -Pattern '\w{8}-\w{4}-\w{4}-\w{4}-\w{12}').Matches.Groups.Value
                        if($VMId)
                        {
                            Write-Output -InputObject "Linux VMUUID is: $VMId. This is not the same as VMid as is the case for Windows VMs"
                            Write-Output -InputObject "Adding VMUUID value as tag on VM: $VMName"
                            $VMTags = $NewVM.Tags
                            $VMTags += @{VMUUID=$VMId}
                            Set-AzResource -ResourceType "Microsoft.Compute/VirtualMachines" -Tag $VMTags -ResourceGroupName $VMResourceGroupName -Name $VMName -Force `
                                -AzContext $NewVMSubscriptionContext -ErrorAction Continue -ErrorVariable oErr
                            if ($oErr)
                            {
                                Write-Error -Message "Failed to update tags for: $VMName. Aborting onboarding to solution" -ErrorAction Stop
                            }
                            else
                            {
                                Write-Output -InputObject "Successfully updated tags for VM: $VMName"
                            }
                        }
                        else
                        {
                            Write-Error -Message "VMUUID for Linux VM was not extracted successfully" -ErrorAction Stop
                        }
                    }
                    else
                    {
                        Write-Error -Message "Failed to retrieve Linux VM VMUUID from script command" -ErrorAction Stop
                    }
                }
            }
            else
            {
                $VMId = $NewVM.Tags.VMUUID
                Write-Verbose -Message "Linux VM: $VMName has VMUUID tag set to: $VMId"
            }
        }
        elseif ($NewVM.StorageProfile.OSDisk.OSType -eq "Windows")
        {
            $MMAExentsionName = $NewLogAnalyticsAgentExtensionName
            $MMAOStype = $NewLogAnalyticsAgentExtensionName
            $MMATypeHandlerVersion = "1.0"
            Write-Output -InputObject "Deploying MMA extension to Windows VM"
        }
        else
        {
            Write-Error -Message "Could not determine OS of VM: $($NewVM.Name)"
        }
        #Region Windows & Linux ARM template
        # URL of original windows template: https://wcusonboardingtemplate.blob.core.windows.net/onboardingtemplate/ArmTemplate/createMmaWindowsV3.json
        # URL of original linux template:   https://wcusonboardingtemplate.blob.core.windows.net/onboardingtemplate/ArmTemplate/createMmaLinuxV3.json
        $ArmTemplate = @'
{
    "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "vmName": {
            "defaultValue": "",
            "type": "String"
        },
        "vmLocation": {
            "defaultValue": "",
            "type": "String"
        },
        "vmIdentityRequired": {
            "defaultValue": "false",
            "type": "Bool"
        },
        "workspaceName": {
            "defaultValue": "",
            "type": "String"
        },
        "workspaceId": {
            "defaultValue": "",
            "type": "String"
        },
        "workspaceResourceId": {
            "defaultValue": "",
            "type": "String"
        },
        "mmaExtensionName": {
            "defaultValue": "",
            "type": "String"
        },
        "apiVersion": {
            "defaultValue": "2018-10-01",
            "type": "String"
        },
        "workspacesApiVersion": {
            "defaultValue": "2017-04-26-preview",
            "type": "String"
        },
        "OStype": {
            "defaultValue": "",
            "type": "String"
        },
        "typeHandlerVersion": {
            "defaultValue": "",
            "type": "String"
        }
    },
    "variables": {
        "vmIdentity": {
            "type": "SystemAssigned"
        }
    },
    "resources": [
        {
            "type": "Microsoft.Compute/virtualMachines",
            "name": "[parameters('vmName')]",
            "apiVersion": "[parameters('apiVersion')]",
            "location": "[parameters('vmLocation')]",
            "identity": "[if(parameters('vmIdentityRequired'), variables('vmIdentity'), json('null'))]",
            "resources": [
                {
                    "type": "extensions",
                    "name": "[parameters('mmaExtensionName')]",
                    "apiVersion": "[parameters('apiVersion')]",
                    "location": "[parameters('vmLocation')]",
                    "properties": {
                        "publisher": "Microsoft.EnterpriseCloud.Monitoring",
                        "type": "[parameters('OStype')]",
                        "typeHandlerVersion": "[parameters('typeHandlerVersion')]",
                        "autoUpgradeMinorVersion": "true",
                        "settings": {
                            "workspaceId": "[parameters('workspaceId')]",
                            "stopOnMultipleConnections": "true"
                        },
                        "protectedSettings": {
                            "workspaceKey": "[listKeys(parameters('workspaceResourceId'), parameters('workspacesApiVersion')).primarySharedKey]"
                        }
                    },
                    "dependsOn": [
                        "[concat('Microsoft.Compute/virtualMachines/', parameters('vmName'))]"
                    ]
                }
            ]
        }
    ]
}
'@
        #Endregion
        # Create temporary file to store ARM template in
        $TempFile = New-TemporaryFile -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to create temporary file for Windows ARM template" -ErrorAction Stop
        }
        Out-File -InputObject $ArmTemplate -FilePath $TempFile.FullName -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to write arm template for log analytics agent installation to temp file" -ErrorAction Stop
        }

        $MMADeploymentParams = @{}
        $MMADeploymentParams.Add("vmName", $VMName)
        $MMADeploymentParams.Add("vmLocation", $VMLocation)
        $MMADeploymentParams.Add("vmIdentityRequired", $VMIdentityRequired)
        $MMADeploymentParams.Add("workspaceName", $WorkspaceName)
        $MMADeploymentParams.Add("workspaceId", $WorkspaceId)
        $MMADeploymentParams.Add("workspaceResourceId", $WorkspaceResourceId)
        $MMADeploymentParams.Add("mmaExtensionName", $MMAExentsionName)
        $MMADeploymentParams.Add("apiVersion", $MMAApiVersion)
        $MMADeploymentParams.Add("workspacesApiVersion", $WorkspacesApiVersion)
        $MMADeploymentParams.Add("OStype", $MMAOStype)
        $MMADeploymentParams.Add("typeHandlerVersion", $MMATypeHandlerVersion)

        # Create deployment name
        $DeploymentName = "AutomationAgentDeploy-PS-" + (Get-Date).ToFileTimeUtc()

        # Deploy solution to new VM
        $ObjectOutPut = New-AzResourceGroupDeployment -ResourceGroupName $VMResourceGroupName -TemplateFile $TempFile.FullName `
            -Name $DeploymentName `
            -TemplateParameterObject $MMADeploymentParams `
            -AzContext $NewVMSubscriptionContext -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Deployment of Log Analytics agent failed" -ErrorAction Stop
        }
        else
        {
            Write-Output -InputObject $ObjectOutPut
            Write-Output -InputObject "VM: $VMName successfully onboarded with Log Analytics MMA extension"
        }
        # Remove temp file with arm template
        Remove-Item -Path $TempFile.FullName -Force
    }
    else
    {
        Write-Output -InputObject "The VM: $VMName already has the Log Analytics extension installed."
    }

    # Check if query update is in progress in another Runbook instance
    $Busy = $true
    while($Busy)
    {
        # random wait to offset parallel executing onboarding runbooks
        Start-Sleep -Seconds (Get-Random -Minimum 1 -Maximum 5)
        # check that no other deployment is in progress
        $CurrentDeployments = Get-AzResourceGroupDeployment -ResourceGroupName $WorkspaceResourceGroupName -AzContext $LASubscriptionContext -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to get status of other solution deployments to resource group: $WorkspaceResourceGroupName" -ErrorAction Stop
        }
        if($CurrentDeployments | Where-Object { ($_.DeploymentName -like "AutomationSolutionUpdate-PS-*") -and ($_.ProvisioningState -eq "Running") })
        {

            Start-Sleep -Seconds (Get-Random -Minimum 1 -Maximum 5)
            $Busy = $true
            Write-Verbose -Message "Detected in progress solution query update, waiting"
        }
        else
        {
            $Busy = $false
            Write-Verbose -Message "No update in progress to solution query"
        }
    }
    # Get the saved group that is used for solution targeting so we can update this with the new VM during onboarding..
    $SavedGroups = Get-AzOperationalInsightsSavedSearch -ResourceGroupName $WorkspaceResourceGroupName `
        -WorkspaceName $WorkspaceName -AzContext $LASubscriptionContext -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to retrieve Log Analytics saved searches info" -ErrorAction Stop
    }
    # Update scope query if necessary
    $SolutionGroup = $SavedGroups.Value | Where-Object {$_.Id -match "MicrosoftDefaultComputerGroup" -and $_.Properties.Category -eq $SolutionType}

    if ($Null -ne $SolutionGroup)
    {
        if (-not (($SolutionGroup.Properties.Query -match $VMId) -or ($SolutionGroup.Properties.Query -match $VMName)) -and $UpdateScopeQuery -and ($null -ne $VMId) )
        {
            Write-Verbose -Message "Adding VM: $VMName to solution type: $SolutionType with VMUUID: $VMId"
            # Original saved search query:
            # $DefaultQuery = "Heartbeat | where Computer in~ (`"`") or VMUUID in~ (`"`") | distinct Computer"

            # Make sure to only add VM id into VMUUID block, the same as is done by adding through the portal
            if ($SolutionGroup.Properties.Query -match 'VMUUID')
            {
                # Will leave the "" inside "VMUUID in~ () so can find out what is added by runbook (left of "") and what is added through portal (right of "")
                Write-Verbose -Message "Before Update: $($SolutionGroup.Properties.Query)"
                $NewQuery = $SolutionGroup.Properties.Query.Replace('VMUUID in~ (', "VMUUID in~ (`"$VMId`",")
                Write-Verbose -Message "After Update: $NewQuery"
            }
            #Region Solution Onboarding ARM Template
            # ARM template to deploy log analytics agent extension for both Linux and Windows
            # URL to template: https://wcusonboardingtemplate.blob.core.windows.net/onboardingtemplate/ArmTemplate/createKQLScopeQueryV2.json
            $ArmTemplate = @'
{
    "$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "location": {
            "type": "string",
            "defaultValue": ""
        },
        "id": {
            "type": "string",
            "defaultValue": ""
        },
        "resourceName": {
            "type": "string",
            "defaultValue": ""
        },
        "category": {
            "type": "string",
            "defaultValue": ""
        },
        "displayName": {
            "type": "string",
            "defaultValue": ""
        },
        "query": {
            "type": "string",
            "defaultValue": ""
        },
        "functionAlias": {
            "type": "string",
            "defaultValue": ""
        },
        "etag": {
            "type": "string",
            "defaultValue": ""
        },
        "apiVersion": {
            "defaultValue": "2017-04-26-preview",
            "type": "String"
        }
    },
    "resources": [
        {
            "apiVersion": "[parameters('apiVersion')]",
            "type": "Microsoft.OperationalInsights/workspaces/savedSearches",
            "location": "[parameters('location')]",
            "name": "[parameters('resourceName')]",
            "id": "[parameters('id')]",
            "properties": {
                "displayname": "[parameters('displayName')]",
                "category": "[parameters('category')]",
                "query": "[parameters('query')]",
                "functionAlias": "[parameters('functionAlias')]",
                "etag": "[parameters('etag')]",
                "tags": [
                    {
                        "Name": "Group", "Value": "Computer"
                    }
                ]
            }
        }
    ]
}
'@
            #Endregion
            # Create temporary file to store ARM template in
            $TempFile = New-TemporaryFile -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to create temporary file for solution ARM template" -ErrorAction Stop
            }
            Out-File -InputObject $ArmTemplate -FilePath $TempFile.FullName -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to write ARM template for solution onboarding to temp file" -ErrorAction Stop
            }
            # Add all of the parameters
            $QueryDeploymentParams = @{}
            $QueryDeploymentParams.Add("location", $WorkspaceLocation)
            $QueryDeploymentParams.Add("id", "/" + $SolutionGroup.Id)
            $QueryDeploymentParams.Add("resourceName", ($WorkspaceName + "/" + $SolutionType + "|" + "MicrosoftDefaultComputerGroup").ToLower())
            $QueryDeploymentParams.Add("category", $SolutionType)
            $QueryDeploymentParams.Add("displayName", "MicrosoftDefaultComputerGroup")
            $QueryDeploymentParams.Add("query", $NewQuery)
            $QueryDeploymentParams.Add("functionAlias", $SolutionType + "__MicrosoftDefaultComputerGroup")
            $QueryDeploymentParams.Add("etag", $SolutionGroup.ETag)
            $QueryDeploymentParams.Add("apiVersion", $SolutionApiVersion)

            # Create deployment name
            $DeploymentName = "AutomationSolutionUpdate-PS-" + (Get-Date).ToFileTimeUtc()

            $ObjectOutPut = New-AzResourceGroupDeployment -ResourceGroupName $WorkspaceResourceGroupName -TemplateFile $TempFile.FullName `
                -Name $DeploymentName `
                -TemplateParameterObject $QueryDeploymentParams `
                -AzContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to add VM: $VMName to solution: $SolutionType" -ErrorAction Stop
            }
            else
            {
                Write-Output -InputObject $ObjectOutPut
                Write-Output -InputObject "VM: $VMName successfully added to solution: $SolutionType"
            }

            # Remove temp file with arm template
            Remove-Item -Path $TempFile.FullName -Force
        }
        else
        {
            if($null -eq $VMId)
            {
                Write-Output -InputObject "The Linux VM: $VMName could not be checked if already onboarded as it is missing the VMUUID tag"
            }
            else
            {
                Write-Output -InputObject "The VM: $VMName is already onboarded to solution: $SolutionType with VMUUID: $VMId"
            }
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