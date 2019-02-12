<#
.SYNOPSIS
    This sample automation runbook onboards Azure VMs for either the Update or ChangeTracking (which includes Inventory) solution.
    It requires an existing Azure VM to already be onboarded to the solution as it uses this information to onboard the
    new VM to the same Log Analytics workspace and Automation Account.
    This Runbook needs to be run from the Automation account that you wish to connect the new VM to. It depends on
    the Enable-AutomationSolution runbook that is available from the gallery and
    https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Enable-AutomationSolution.ps1. If this Runbook is
    not present, it will be automatically imported.

.DESCRIPTION
    This sample automation runbook onboards Azure VMs for either the Update or ChangeTracking (which includes Inventory) solution.
    It requires an existing Azure VM to already be onboarded to the solution as it uses this information to onboard the
    new VM to the same Log Analytics workspace and Automation Account.
    This Runbook needs to be run from the Automation account that you wish to connect the new VM to. It depends on
    the Enable-AutomationSolution runbook that is available from the gallery and
    https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Enable-AutomationSolution.ps1. If this Runbook is
    not present, it will be automatically imported.

.PARAMETER VMName
    Optional. The name of a specific VM that you want onboarded to the Updates or ChangeTracking solution
    If this is not specified, all VMs in the resource group will be onboarded.

.PARAMETER VMResourceGroup
    Required. The name of the resource group that the VM is a member of.

.PARAMETER SubscriptionId
    Optional. The name subscription id where the new VM to onboard is located.
    This will default to the same one as the workspace if not specified. If you
    give a different subscription id then you need to make sure the RunAs account for
    this automaiton account is added as a contributor to this subscription also.

.PARAMETER AlreadyOnboardedVM
    Required. The name of the existing Azure VM that is already onboarded to the Updates or ChangeTracking solution

.PARAMETER AlreadyOnboardedVMResourceGroup
    Required. The name of resource group that the existing VM with the solution is a member of

.PARAMETER SolutionType
    Required. The name of the solution to onboard to this Automation account.
    It must be either "Updates" or "ChangeTracking". ChangeTracking also includes the inventory solution.

.Example
    .\Enable-MultipleSolution -VMName finance1 -ResourceGroupName finance `
             -AlreadyOnboardedVM hrapp1 -AlreadyOnboardedVMResourceGroup hr -SolutionType Updates

.Example
    .\Enable-MultipleSolution -ResourceGroupName finance `
             -AlreadyOnboardedVM hrapp1 -AlreadyOnboardedVMResourceGroup hr -SolutionType ChangeTracking

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: November 9th, 2017
#>
Param (
    [Parameter(
        Mandatory = $False
    )]
    [object] $WebhookData,

    [Parameter(
        Mandatory = $True
    )]
    [String]
    $VMSubscriptionId,

    [Parameter(
        Mandatory = $True
    )]
    [String]
    $VMResourceGroup,

    [Parameter(
        Mandatory = $False
    )]
    [String]
    $VMName,

    [Parameter(
        Mandatory = $False
    )]
    [String]
    $SolutionType = "Updates"
)
try
{
    Write-Verbose -Message  "Starting Runbook at time: $(get-Date -format r). Running PS version: $($PSVersionTable.PSVersion)"
    $VerbosePreference = "silentlycontinue"
    Import-Module -Name AzureRM.Profile, AzureRM.Automation, AzureRM.OperationalInsights -ErrorAction Continue -ErrorVariable oErr
    If ($oErr)
    {
        Write-Error -Message "Failed to load needed modules for Runbook, check that AzureRM.Automation and AzureRM.OperationalInsights is imported into Azure Automation" -ErrorAction Stop
    }
    $VerbosePreference = "Continue"

    # Runbook that is used to enable a solution on a VM.
    # If this is not present in the Automation account, it will be imported automatically from
    # https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Enable-AutomationSolution.ps1
    $RunbookName = "Enable-AutomationSolution"

    if ($SolutionType -cne "Updates" -and $SolutionType -cne "ChangeTracking")
    {
        throw ("Only a solution type of Updates or ChangeTracking is currently supported. These are case sensitive ")
    }


    # Authenticate to Azure
    $ServicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
    Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $ServicePrincipalConnection.TenantId `
        -ApplicationId $ServicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint -ErrorAction Continue -ErrorVariable oErr
    If ($oErr)
    {
        Write-Error -Message "Failed to connect to Azure" -ErrorAction Stop
    }

    # Set subscription to work against
    $SubscriptionContext = Set-AzureRmContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
    If ($oErr)
    {
        Write-Error -Message "Failed to set azure context to subscription for AA" -ErrorAction Stop
    }

    if ([string]::IsNullOrEmpty($VMSubscriptionId))
    {
        # Assume VM is in the same subscription as the Automation account
        $VMSubscriptionContext = Set-AzureRmContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
        If ($oErr)
        {
            Write-Error -Message "Failed to set azure context to VM subscription" -ErrorAction Stop
        }
    }
    else
    {
        # VM is in a different subscription so set the context to this subscription
        $VMSubscriptionContext = Set-AzureRmContext -SubscriptionId $VMSubscriptionId -ErrorAction Continue -ErrorVariable oErr
        If ($oErr)
        {
            Write-Error -Message "Failed to set azure context to VM subscription" -ErrorAction Stop
        }
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
        -AutomationAccountName $AutomationAccount -Name $RunbookName `
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

    # Get all subscription account has access to
    # TODO: Better subscription filter,
    <#
    if ($VMSubscriptionContext.SubscriptionName -like "*-prod")
    {
        # Only choose production subscriptions
        $AzureRmSubscriptions = Get-AzureRmSubscription | Where-Object {$_.Name -like "*-prod"}
    }
    elseif ($VMSubscriptionContext.SubscriptionName -like "*-test")
    {
        # Only choose test subscriptions
        $AzureRmSubscriptions = Get-AzureRmSubscription | Where-Object {$_.Name -like "*-test"}
    }
    elseif ($VMSubscriptionContext.SubscriptionName -like "*-dev")
    {
        # Only choose development subscriptions
        $AzureRmSubscriptions = Get-AzureRmSubscription | Where-Object {$_.Name -like "*-dev"}
    }
    else
    {
        $AzureRmSubscriptions = Get-AzureRmSubscription #| Sort-Object -Property @{Expression={if ($_ -match '(.+?)\d') {$Matches[1]}}; Ascending=$true}
    }
    #>
    $AzureRmSubscriptions = Get-AzureRmSubscription | Where-Object {$_.Name -eq "in.lab.azure" -or $_.Name -eq "in.lab.rogca"}

    # Run through each until a VM with Microsoft Monitoring Agent is found
    $SubscriptionCounter = 0
    foreach ($AzureRMsubscription in $AzureRMsubscriptions)
    {
        # Set subscription context
        $OnboardedVMSubscriptionContext = Set-AzureRmContext -SubscriptionId $AzureRmSubscription.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
        If ($oErr)
        {
            Write-Error -Message "Failed to set azure context to subscription: $($AzureRmSubscription.Name)" -ErrorAction Continue
            $oErr = $Null
        }
        if ($Null -ne $OnboardedVMSubscriptionContext)
        {
            # Find existing VM that is already onboarded to the solution.
            $MMAgentVMs = Get-AzureRmResource -ResourceType "Microsoft.Compute/virtualMachines/extensions" -AzureRmContext $OnboardedVMSubscriptionContext | Where-Object {$_.Name -like "*/OMSExtension"}

            # Find VM to use as template
            If ($MMAgentVMs)
            {
                Write-Verbose -Message "Found $($MMAgentVMs.Count) VM(s) with Microsoft Monitoring Agent installed"
                # Break out of loop if VM with Microsoft Monitoring Agent installed is found in a subscription
                break
            }
        }
        $SubscriptionCounter++
        If ($Count -eq $AzureRmSubscriptions.Count)
        {
            Write-Error -Message "Did not find any VM with Microsoft Monitoring Agent already installed. Install at least one in a subscription the AA RunAs account has access to" -ErrorAction Stop
        }
    }
    $VMCounter = 0
    foreach ($MMAgentVM in $MMAgentVMs)
    {
        if ($Null -ne $MMAgentVM.Name -and $Null -ne $MMAgentVM.ResourceGroupName)
        {
            $ExistingVMExtension = Get-AzureRmVMExtension -ResourceGroup $MMAgentVM.ResourceGroupName -VMName ($MMAgentVM.Name).Split('/')[0] `
                -AzureRmContext $OnboardedVMSubscriptionContext -Name ($MMAgentVM.Name).Split('/')[-1]
        }
        if ($Null -ne $ExistingVMExtension)
        {
            Write-Verbose -Message "Retrieved extension config from VM: $($ExistingVMExtension.VMName)"
            # Found VM with Microsoft Monitoring Agent installed
            break
        }
        $VMCounter++
        if ($VMCounter -eq $MMAgentVMs.Count)
        {
            Write-Error -Message "Failed to retrieve extension config for Microsoft Monitoring Agent on VM" -ErrorAction Stop
        }
    }

    # Check if the existing VM is already onboarded
    if ($ExistingVMExtension.PublicSettings)
    {
        $PublicSettings = ConvertFrom-Json $ExistingVMExtension.PublicSettings
        if ([string]::IsNullOrEmpty($PublicSettings.workspaceId))
        {
            Write-Error -Message "This VM " + $($ExistingVMExtension.VMName) + " is not onboarded. Please onboard first as it is used to collect information" -ErrorAction Stop
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
        Write-Error -Message "Failed to retrieve Operational Insight workspace info" -ErrorAction Stop
    }

    # Get the saved group that is used for solution targeting so we can update this with the new VM during onboarding..
    $SavedGroups = Get-AzureRmOperationalInsightsSavedSearch -ResourceGroupName $WorkspaceInfo.ResourceGroupName `
        -WorkspaceName $WorkspaceInfo.Name -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to retrieve Operational Insight saved groups info" -ErrorAction Stop
    }
    $SolutionGroup = $SavedGroups.Value | Where-Object {$_.Id -match "MicrosoftDefaultComputerGroup" -and $_.Properties.Category -eq $SolutionType}

    # Get list of VMs that you want to onboard the solution to
    if (!([string]::IsNullOrEmpty($VMResourceGroup)) -and !([string]::IsNullOrEmpty($VMName)))
    {
        $VMList = Get-AzureRMVM -ResourceGroupName $VMResourceGroup -Name $VMName -AzureRmContext $VMSubscriptionContext `
            -Status -ErrorAction Continue -ErrorVariable oErr | Where-Object {$_.Statuses.code -match "running"}
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve VM: $VMName to onboard object" -ErrorAction Stop
        }
    }
    elseif (!([string]::IsNullOrEmpty($VMResourceGroup)))
    {
        $VMList = Get-AzureRMVM -ResourceGroupName $VMResourceGroup -AzureRmContext $VMSubscriptionContext `
            -Status -ErrorAction Continue -ErrorVariable oErr | Where-Object {$_.PowerState -match "running"}
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve VMs to onboard objects from resource group: $VMResourceGroup" -ErrorAction Stop
        }
    }
    else
    {
        # If the resource group was not required, but optional, all VMs in the subscription could be onboarded.
        $VMList = Get-AzureRMVM -AzureRmContext $VMSubscriptionContext -Status -ErrorAction Continue -ErrorVariable oErr | Where-Object {$_.PowerState -match "running"}
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve all VMs in subscription: $($VMSubscriptionContext.Name) to onboard objects" -ErrorAction Stop
        }
    }

    # Process the list of VMs using the automation service and collect jobs used
    $Jobs = @{}

    foreach ($VM in $VMList)
    {
        # Start automation runbook to process VMs in parallel
        $RunbookNameParams = @{}
        $RunbookNameParams.Add("VMName", $VM.Name)
        $RunbookNameParams.Add("ResourceGroupName", $VM.ResourceGroupName)
        $RunbookNameParams.Add("ExistingVM", $ExistingVMExtension.VMName)
        $RunbookNameParams.Add("ExistingVMResourceGroup", $ExistingVMExtension.ResourceGroupName)
        $RunbookNameParams.Add("SolutionType", $SolutionType)
        $RunbookNameParams.Add("UpdateScopeQuery", $False)
        if (!([string]::IsNullOrEmpty($VMSubscriptionId)))
        {
            $RunbookNameParams.Add("SubscriptionId", $VMSubscriptionId)
        }

        # Loop here until a job was successfully submitted. Will stay in the loop until job has been submitted or an exception other than max allowed jobs is reached
        while ($true)
        {
            try
            {
                $Job = Start-AzureRmAutomationRunbook -ResourceGroupName $AutomationResourceGroup -AutomationAccountName $AutomationAccount `
                    -Name $RunbookName -Parameters $RunbookNameParams `
                    -AzureRmContext $SubscriptionContext -ErrorAction Stop
                $Jobs.Add($VM.Name, $Job)
                # Submitted job successfully, exiting while loop
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

    # Wait for jobs to complete, stop, fail, or suspend (final states allowed for a runbook)
    $JobsResults = @()
    $MachineList = $null
    foreach ($RunningJob in $Jobs.GetEnumerator())
    {
        $ActiveJob = Get-AzureRMAutomationJob -ResourceGroupName $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccount -Id $RunningJob.Value.JobId `
            -AzureRmContext $SubscriptionContext
        While ($ActiveJob.Status -ne "Completed" -and $ActiveJob.Status -ne "Failed" -and $ActiveJob.Status -ne "Suspended" -and $ActiveJob.Status -ne "Stopped")
        {
            Start-Sleep 30
            $ActiveJob = Get-AzureRMAutomationJob -ResourceGroupName $AutomationResourceGroup `
                -AutomationAccountName $AutomationAccount -Id $RunningJob.Value.JobId `
                -AzureRmContext $SubscriptionContext
        }
        if ($ActiveJob.Status -eq "Completed")
        {
            $VirutalMachineName = $RunningJob.Name
            if ($SolutionGroup)
            {
                if (!($SolutionGroup.Properties.Query -match $VirutalMachineName))
                {
                    $MachineList += "`"$VirutalMachineName`", "
                }
            }
        }
        $JobsResults += $ActiveJob
    }

    # Get latest group information and add new machines to the query if needed.
    $SavedGroups = Get-AzureRmOperationalInsightsSavedSearch -ResourceGroupName $WorkspaceInfo.ResourceGroupName `
        -WorkspaceName $WorkspaceInfo.Name -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to retrieve all VMs saved groups from Operational Insights" -ErrorAction Stop
    }

    $SolutionGroup = $SavedGroups.Value | Where-Object {$_.Id -match "MicrosoftDefaultComputerGroup" -and $_.Properties.Category -eq $SolutionType}

    if (!([string]::IsNullOrEmpty($MachineList)))
    {
        $MachineList = $MachineList.TrimEnd(', ')
        $NewQuery = $SolutionGroup.Properties.Query.Replace('(', "($MachineList, ")
    }
    else
    {
        $NewQuery = $SolutionGroup.Properties.Query
    }

    # If new machines need to be added to the scope query, add them here.
    if ($SolutionGroup -and !([string]::IsNullOrEmpty($MachineList)))
    {
        $ComputerGroupQueryTemplateLinkUri = "https://wcusonboardingtemplate.blob.core.windows.net/onboardingtemplate/ArmTemplate/updateKQLScopeQueryV2.json"

        # Add all of the parameters
        $DeploymentParams = @{}
        $DeploymentParams.Add("location", $WorkspaceInfo.Location)
        $DeploymentParams.Add("id", "/" + $SolutionGroup.Id)
        $DeploymentParams.Add("resourceName", ($WorkspaceInfo.Name + "/" + $SolutionType + "|" + "MicrosoftDefaultComputerGroup").ToLower())
        $DeploymentParams.Add("category", $SolutionType)
        $DeploymentParams.Add("displayName", "MicrosoftDefaultComputerGroup")
        $DeploymentParams.Add("query", $NewQuery)
        $DeploymentParams.Add("functionAlias", $SolutionType + "__MicrosoftDefaultComputerGroup")
        $DeploymentParams.Add("etag", $SolutionGroup.ETag)

        # Create deployment name
        $DeploymentName = "EnableAutomation" + (Get-Date).ToFileTimeUtc()

        New-AzureRmResourceGroupDeployment -ResourceGroupName $AutomationResourceGroup -TemplateUri $ComputerGroupQueryTemplateLinkUri `
            -Name $DeploymentName `
            -TemplateParameterObject $DeploymentParams -AzureRmContext $SubscriptionContext -Verbose

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
        throw ("Some jobs failed to complete successfully. Please see output stream for details.")
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
    Write-Verbose -Message  "Runbook ended at time: $(get-Date -format r)"
}