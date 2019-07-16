<#
.SYNOPSIS
    This sample automation runbook onboards Azure VMs for either the Update or ChangeTracking (which includes Inventory) solution.
    It requires an existing Azure VM to already be onboarded to the solution as it uses this information to onboard the
    new VM to the same Log Analytics workspace and Automation Account.
    This Runbook needs to be run from the Automation account that you wish to connect the new VM to. It depends on
    the Enable-AutomationSolution runbook that is available from the gallery and
    https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Enable-AutomationSolution.ps1. If this Runbook is
    not present, it will be automatically imported.

    To set what Log Analytics workspace to use for Update and Change Tracking management (bypassing the logic that search for an existing onboarded VM),
    create the following AA variable assets:
        LASolutionSubscriptionId and populate with subscription ID of where the Log Analytics workspace is located
        LASolutionWorkspaceId and populate with the Workspace Id of the Log Analytics workspace

.DESCRIPTION
    This sample automation runbook onboards Azure VMs for either the Update or ChangeTracking (which includes Inventory) solution.
    It requires an existing Azure VM to already be onboarded to the solution as it uses this information to onboard the
    new VM to the same Log Analytics workspace and Automation Account.
    This Runbook needs to be run from the Automation account that you wish to connect the new VM to. It depends on
    the Enable-AutomationSolution runbook that is available from the gallery and
    https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Enable-AutomationSolution.ps1. If this Runbook is
    not present, it will be automatically imported.

.COMPONENT
    To predefine what Log Analytics workspace to use, create the following AA variable assets:
        LASolutionSubscriptionId
        LASolutionWorkspaceId

.PARAMETER VMSubscriptionId
    Optional. The name subscription id where the new VM to onboard is located.
    This will default to the same one as the workspace if not specified. If you
    give a different subscription id then you need to make sure the RunAs account for
    this automation account is added as a contributor to this subscription also.

.PARAMETER VMResourceGroup
    Required. The name of the resource group that the VM is a member of.

.PARAMETER VMName
    Optional. The name of a specific VM that you want onboarded to the Updates or ChangeTracking solution
    If this is not specified, all VMs in the resource group will be onboarded.

.PARAMETER SolutionType
    Required. The name of the solution to onboard to this Automation account.
    It must be either "Updates" or "ChangeTracking". ChangeTracking also includes the inventory solution.

.Example
    .\Enable-MultipleSolution -VMName finance1 -ResourceGroupName finance `
            -SolutionType Updates

.Example
    .\Enable-MultipleSolution -ResourceGroupName finance `
            -SolutionType ChangeTracking

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: November 9th, 2017
#>
Param (
    [Parameter(Mandatory = $False)]
    [String]
    $VMSubscriptionId,

    [Parameter(Mandatory = $True)]
    [String]
    $VMResourceGroup,

    [Parameter(Mandatory = $False)]
    [String]
    $VMName,

    [Parameter(Mandatory = $True)]
    [ValidateSet("Updates", "ChangeTracking", IgnoreCase = $False)]
    [String]
    $SolutionType
)
try
{
    $RunbookName = "Enable-MultipleAutomationSolution"
    Write-Output -InputObject "Starting Runbook: $RunbookName at time: $(get-Date -format r).`nRunning PS version: $($PSVersionTable.PSVersion)`nOn host: $($env:computername)"
    Write-Error -Message "This Runbook is no longer supported" -ErrorAction Stop
    $VerbosePreference = "silentlycontinue"
    Import-Module -Name AzureRM.Profile, AzureRM.Automation, AzureRM.OperationalInsights, AzureRM.Compute, AzureRM.Resources -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to load needed modules for Runbook, check that AzureRM.Automation, AzureRM.OperationalInsights, AzureRM.Compute and AzureRM.Resources is imported into Azure Automation" -ErrorAction Stop
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
        Write-Output -InputObject "Using AA asset variable for Log Analytics subscription id"
    }
    else
    {
        Write-Output -InputObject "Will try to discover Log Analytics subscription id"
    }

    # Check if AA asset variable is set  for Log Analytics workspace ID to use
    $LogAnalyticsSolutionWorkspaceId = Get-AutomationVariable -Name "LASolutionWorkspaceId" -ErrorAction SilentlyContinue
    if ($Null -ne $LogAnalyticsSolutionWorkspaceId)
    {
        Write-Output -InputObject "Using AA asset variable for Log Analytics workspace id"
    }
    else
    {
        Write-Output -InputObject "Will try to discover Log Analytics workspace id"
    }
    # Runbook that is used to enable a solution on a VM.
    # If this is not present in the Automation account, it will be imported automatically from
    # https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Enable-AutomationSolution.ps1
    $DependencyRunbookName = "Enable-AutomationSolution"
    $OldLogAnalyticsAgentExtensionName = "OMSExtension"
    $NewLogAnalyticsAgentExtensionName = "MMAExtension"
    $SolutionApiVersion = "2017-04-26-preview"
    #endregion

    # Fetch AA RunAs account detail from connection object asset
    $ServicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection" -ErrorAction Stop
    $Null = Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $ServicePrincipalConnection.TenantId `
        -ApplicationId $ServicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to connect to Azure" -ErrorAction Stop
    }

    # Set subscription of AA account
    $SubscriptionContext = Set-AzureRmContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to set azure context to subscription for AA" -ErrorAction Stop
    }
    # set subscription of VM onboarded, else assume its in the same as the AA account
    if ($Null -eq $VMSubscriptionId -or "" -eq $VMSubscriptionId)
    {
        # Use the same subscription as the Automation account if not passed in
        $NewVMSubscriptionContext = Set-AzureRmContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to set azure context to subscription for AA" -ErrorAction Stop
        }
        Write-Verbose -Message "Creating azure VM context using subscription: $($NewVMSubscriptionContext.Subscription.Name)"
    }
    else
    {
        # VM is in a different subscription so set the context to this subscription
        $NewVMSubscriptionContext = Set-AzureRmContext -SubscriptionId $VMSubscriptionId -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to set azure context to subscription where VM is. Make sure AA RunAs account has contributor rights" -ErrorAction Stop
        }
        Write-Verbose -Message "Creating azure VM context using subscription: $($NewVMSubscriptionContext.Subscription.Name)"
    }

    # set subscription of Log Analytic workspace used for Update Management and Change Tracking, else assume its in the same as the AA account
    if ($Null -ne $LogAnalyticsSolutionSubscriptionId)
    {
        # VM is in a different subscription so set the context to this subscription
        $LASubscriptionContext = Set-AzureRmContext -SubscriptionId $LogAnalyticsSolutionSubscriptionId -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to set azure context to subscription where Log Analytics workspace is" -ErrorAction Stop
        }
        Write-Verbose -Message "Creating Log Analytics context using subscription: $($LASubscriptionContext.Subscription.Name)"
    }

    # Find out the resource group and account name
    $AutomationResource = Get-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
    If ($oErr)
    {
        Write-Error -Message "Failed to retrieve automation account resource details" -ErrorAction Stop
    }
    foreach ($Automation in $AutomationResource)
    {
        $Job = Get-AzureRmAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name `
            -Id $PSPrivateMetadata.JobId.Guid -AzureRmContext $SubscriptionContext -ErrorAction SilentlyContinue
        if (!([string]::IsNullOrEmpty($Job)))
        {
            $AutomationResourceGroup = $Job.ResourceGroupName
            $AutomationAccount = $Job.AutomationAccountName
            break
        }
    }

    # Check that Enable-AutomationSolution runbook is published in the automation account
    $EnableSolutionRunbook = Get-AzureRmAutomationRunbook -ResourceGroupName $AutomationResourceGroup `
        -AutomationAccountName $AutomationAccount -Name $DependencyRunbookName `
        -AzureRmContext $SubscriptionContext -ErrorAction SilentlyContinue

    if ($EnableSolutionRunbook.State -ne "Published" -and $EnableSolutionRunbook.State -ne "Edit")
    {
        Write-Verbose ("Importing Enable-AutomationSolution runbook as it is not present..")
        $LocalFolder = Join-Path $Env:SystemDrive (New-Guid).Guid
        New-Item -ItemType directory $LocalFolder -Force | Write-Verbose

        (New-Object System.Net.WebClient).DownloadFile("https://raw.githubusercontent.com/azureautomation/runbooks/master/Utility/ARM/Enable-AutomationSolution.ps1", "$LocalFolder\Enable-AutomationSolution.ps1")
        Unblock-File $LocalFolder\Enable-AutomationSolution.ps1 | Write-Verbose
        Import-AzureRmAutomationRunbook -ResourceGroupName $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccount -Path $LocalFolder\Enable-AutomationSolution.ps1 `
            -Published -Type PowerShell -AzureRmContext $SubscriptionContext -Force | Write-Verbose
        Remove-Item -Path $LocalFolder -Recurse -Force
    }

    # Check if Log Analytics workspace is set through a AA asset
    if ($Null -eq $LogAnalyticsSolutionWorkspaceId)
    {
        # Set order to sort subscriptions by
        $SortOrder = @($NewVMSubscriptionContext.Subscription.Name, $SubscriptionContext.Subscription.Name)
        # Get all subscriptions the AA account has access to
        $AzureRmSubscriptions = Get-AzureRmSubscription |
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

        if ($Null -ne $AzureRmSubscriptions)
        {
            # Run through each until a VM with Microsoft Monitoring Agent is found
            $SubscriptionCounter = 0
            foreach ($AzureRMsubscription in $AzureRMsubscriptions)
            {
                # Set subscription context
                $OnboardedVMSubscriptionContext = Set-AzureRmContext -SubscriptionId $AzureRmSubscription.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
                if ($oErr)
                {
                    Write-Error -Message "Failed to set azure context to subscription: $($AzureRmSubscription.Name)" -ErrorAction Continue
                    $oErr = $Null
                }
                if ($Null -ne $OnboardedVMSubscriptionContext)
                {
                    # Find existing VM that is already onboarded to the solution.
                    $VMExtensions = Get-AzureRmResource -ResourceType "Microsoft.Compute/virtualMachines/extensions" -AzureRmContext $OnboardedVMSubscriptionContext |
                        Where-Object {($_.Name -like "*/$NewLogAnalyticsAgentExtensionName") -or ($_.Name -like "*/$OldLogAnalyticsAgentExtensionName")}

                    # Find VM to use as template
                    if ($Null -ne $VMExtensions)
                    {
                        Write-Verbose -Message "Found $($VMExtensions.Count) VM(s) with Microsoft Monitoring Agent installed"
                        # Break out of loop if VM with Microsoft Monitoring Agent installed is found in a subscription
                        break
                    }
                }
                $SubscriptionCounter++
                if ($SubscriptionCounter -eq $AzureRmSubscriptions.Count)
                {
                    Write-Error -Message "Did not find any VM with Microsoft Monitoring Agent already installed. Install at least one in a subscription the AA RunAs account has access to" -ErrorAction Stop
                }
            }
            $VMCounter = 0
            foreach ($VMExtension in $VMExtensions)
            {
                if ($Null -ne $VMExtension.Name -and $Null -ne $VMExtension.ResourceGroupName)
                {
                    $ExistingVMExtension = Get-AzureRmVMExtension -ResourceGroup $VMExtension.ResourceGroupName -VMName ($VMExtension.Name).Split('/')[0] `
                        -AzureRmContext $OnboardedVMSubscriptionContext -Name ($VMExtension.Name).Split('/')[-1]
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
        $WorkspaceInfo = Get-AzureRmOperationalInsightsWorkspace -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr `
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
            $WorkspaceLocation = $WorkspaceInfo.Location
        }
        else
        {
            Write-Error -Message "Failed to retrieve Log Analytics workspace information" -ErrorAction Stop
        }
        # Get the saved group that is used for solution targeting so we can update this with the new VM during onboarding..
        $SavedGroups = Get-AzureRmOperationalInsightsSavedSearch -ResourceGroupName $WorkspaceResourceGroupName `
            -WorkspaceName $WorkspaceName -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
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
            $WorkspaceInfo = Get-AzureRmOperationalInsightsWorkspace -AzureRmContext $LASubscriptionContext -ErrorAction Continue -ErrorVariable oErr `
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
                $WorkspaceLocation = $WorkspaceInfo.Location
            }
            else
            {
                Write-Error -Message "Failed to retrieve Log Analytics workspace information" -ErrorAction Stop
            }
            # Get the saved group that is used for solution targeting so we can update this with the new VM during onboarding..
            $SavedGroups = Get-AzureRmOperationalInsightsSavedSearch -ResourceGroupName $WorkspaceResourceGroupName `
                -WorkspaceName $WorkspaceName -AzureRmContext $LASubscriptionContext -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to retrieve Log Analytics saved groups info" -ErrorAction Stop
            }
        }
        else
        {
            Write-Error -Message "Log Analytics subscription context not set, check AA assets has correct value and AA runAs account has access to subscription." -ErrorAction Stop
        }
    }

    $SolutionGroup = $SavedGroups.Value | Where-Object {$_.Id -match "MicrosoftDefaultComputerGroup" -and $_.Properties.Category -eq $SolutionType}

    # Get list of VMs that you want to onboard the solution to
    if (($Null -ne $VMResourceGroup) -and ($Null -ne $VMName))
    {
        $VMList = Get-AzureRMVM -ResourceGroupName $VMResourceGroup -Name $VMName -AzureRmContext $NewVMSubscriptionContext `
            -Status -ErrorAction Continue -ErrorVariable oErr | Where-Object {$_.Statuses.code -match "running"}
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve VM: $VMName to onboard object" -ErrorAction Stop
        }
    }
    elseif ($Null -ne $VMResourceGroup)
    {
        $VMList = Get-AzureRMVM -ResourceGroupName $VMResourceGroup -AzureRmContext $NewVMSubscriptionContext `
            -Status -ErrorAction Continue -ErrorVariable oErr | Where-Object {$_.PowerState -match "running"}
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve VMs to onboard objects from resource group: $VMResourceGroup" -ErrorAction Stop
        }
    }
    else
    {
        # If the resource group was not required, but optional, all VMs in the subscription could be onboarded.
        $VMList = Get-AzureRMVM -AzureRmContext $NewVMSubscriptionContext -Status -ErrorAction Continue -ErrorVariable oErr | Where-Object {$_.PowerState -match "running"}
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve all VMs in subscription: $($NewVMSubscriptionContext.Name) to onboard objects" -ErrorAction Stop
        }
    }

    # Process the list of VMs using the automation service and collect jobs used
    $Jobs = @{}
    if ($Null -ne $VMList)
    {
        foreach ($VM in $VMList)
        {
            # Start automation runbook to process VMs in parallel
            $RunbookNameParams = @{}
            $RunbookNameParams.Add("VMSubscriptionId", ($VM.id).Split('/')[2])
            $RunbookNameParams.Add("VMResourceGroupName", $VM.ResourceGroupName)
            $RunbookNameParams.Add("VMName", $VM.Name)
            $RunbookNameParams.Add("SolutionType", $SolutionType)
            $RunbookNameParams.Add("UpdateScopeQuery", $False)

            # Loop here until a job was successfully submitted. Will stay in the loop until job has been submitted or an exception other than max allowed jobs is reached
            while ($true)
            {
                try
                {
                    $Job = Start-AzureRmAutomationRunbook -ResourceGroupName $AutomationResourceGroup -AutomationAccountName $AutomationAccount `
                        -Name $RunbookName -Parameters $RunbookNameParams `
                        -AzureRmContext $SubscriptionContext -ErrorAction Stop
                    $Jobs.Add($VM.VMId, $Job)
                    # Submitted job successfully, exiting while loop
                    Write-Verbose -Message "Added VM id: $($VM.VMId) to AA job"
                    break
                }
                catch
                {
                    # If we have reached the max allowed jobs, sleep backoff seconds and try again inside the while loop
                    if ($_.Exception.Message -match "conflict")
                    {
                        Write-Verbose -Message ("Sleeping for 30 seconds as max allowed jobs has been reached. Will try again afterwards")
                        Start-Sleep 60
                    }
                    else
                    {
                        throw $_
                    }
                }
            }
        }
    }
    else
    {
        Write-Error -Message "No VMs to onboard found." -ErrorAction
    }


    # Wait for jobs to complete, stop, fail, or suspend (final states allowed for a runbook)
    $JobsResults = @()
    $MachineList = $null
    foreach ($RunningJob in $Jobs.GetEnumerator())
    {
        $ActiveJob = Get-AzureRMAutomationJob -ResourceGroupName $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccount -Id $RunningJob.Value.JobId `
            -AzureRmContext $SubscriptionContext
        while ($ActiveJob.Status -ne "Completed" -and $ActiveJob.Status -ne "Failed" -and $ActiveJob.Status -ne "Suspended" -and $ActiveJob.Status -ne "Stopped")
        {
            Start-Sleep 30
            $ActiveJob = Get-AzureRMAutomationJob -ResourceGroupName $AutomationResourceGroup `
                -AutomationAccountName $AutomationAccount -Id $RunningJob.Value.JobId `
                -AzureRmContext $SubscriptionContext
        }
        if ($ActiveJob.Status -eq "Completed")
        {
            if ($Null -ne $RunningJob.VMId)
            {
                $VirutalMachineId = $RunningJob.VMId
                if ($SolutionGroup)
                {
                    if (-not ($SolutionGroup.Properties.Query -match $VirutalMachineId))
                    {
                        $MachineList += "`"$VirutalMachineId`", "
                    }
                }
            }
            else
            {
                Write-Warning -Message "Failed to retrieve VM Id stored in AA job"
            }
        }
        $JobsResults += $ActiveJob
    }

    if ($Null -ne $MachineList)
    {
        $MachineList = $MachineList.TrimEnd(', ')
        $NewQuery = $SolutionGroup.Properties.Query.Replace('VMUUID in~ (', "VMUUID in~ ($MachineList,")
    }
    else
    {
        $NewQuery = $SolutionGroup.Properties.Query
    }

    if ($Null -ne $MachineList -and $Null -ne $SolutionGroup.Properties.Query)
    {
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
        $DeploymentName = "EnableMultipleAutomation" + (Get-Date).ToFileTimeUtc()

        $ObjectOutPut = New-AzureRmResourceGroupDeployment -ResourceGroupName $WorkspaceResourceGroupName -TemplateFile $TempFile.FullName `
            -Name $DeploymentName `
            -TemplateParameterObject $QueryDeploymentParams `
            -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
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

    # Print out results of the automation jobs
    $JobFailed = $False
    foreach ($JobsResult in $JobsResults)
    {
        $OutputJob = Get-AzureRmAutomationJobOutput  -ResourceGroupName $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccount -Id `
            $JobsResult.JobId -AzureRmContext $SubscriptionContext -Stream Output
        foreach ($Stream in $OutputJob)
        {
            (Get-AzureRmAutomationJobOutputRecord  -ResourceGroupName $AutomationResourceGroup `
                    -AutomationAccountName $AutomationAccount -JobID $JobsResult.JobId `
                    -AzureRmContext $SubscriptionContext -Id $Stream.StreamRecordId).Value
        }

        $ErrorJob = Get-AzureRmAutomationJobOutput  -ResourceGroupName $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccount -Id `
            $JobsResult.JobId -AzureRmContext $SubscriptionContext -Stream Error
        foreach ($Stream in $ErrorJob)
        {
            (Get-AzureRmAutomationJobOutputRecord  -ResourceGroupName $AutomationResourceGroup `
                    -AutomationAccountName $AutomationAccount -JobID $JobsResult.JobId `
                    -AzureRmContext $SubscriptionContext -Id $Stream.StreamRecordId).Value
        }

        $WarningJob = Get-AzureRmAutomationJobOutput  -ResourceGroupName $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccount -Id `
            $JobsResult.JobId -AzureRmContext $SubscriptionContext -Stream Warning
        foreach ($Stream in $WarningJob)
        {
            (Get-AzureRmAutomationJobOutputRecord  -ResourceGroupName $AutomationResourceGroup `
                    -AutomationAccountName $AutomationAccount -JobID $JobsResult.JobId `
                    -AzureRmContext $SubscriptionContext -Id $Stream.StreamRecordId).Value
        }

        if ($JobsResult.Status -ne "Completed")
        {
            $JobFailed = $True
        }
    }
    if ($JobFailed)
    {
        Write-Error -Message "Some jobs failed to complete successfully. Please see output stream for details." -ErrorAction Stop
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