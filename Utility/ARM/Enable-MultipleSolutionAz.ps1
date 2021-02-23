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
#>
Param (
    [Parameter(Mandatory = $false)]
    [String]
    $VMSubscriptionId,

    [Parameter(Mandatory = $true)]
    [String]
    $VMResourceGroupName,

    [Parameter(Mandatory = $false)]
    [String]
    $VMName,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Updates", "ChangeTracking", IgnoreCase = $false)]
    [String]
    $SolutionType,

    [Parameter(Mandatory = $false)]
    [String]
    $AutomationResourceGroupName,

    [Parameter(Mandatory = $false)]
    [String]
    $AutomationAccountName
)
try
{
    $RunbookName = "Enable-MultipleSolutionAz"
    Write-Output -InputObject "Starting Runbook: $RunbookName at time: $(get-Date -format r).`nRunning PS version: $($PSVersionTable.PSVersion)`nOn host: $($env:computername)"

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
    $DependencyRunbookName = "Enable-AutomationSolutionAz"
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
    if ([string]::IsNullOrEmpty($VMSubscriptionId))
    {
        # Use the same subscription as the Automation account if not passed in
        $NewVMSubscriptionContext = Set-AzContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to set azure context to subscription" -ErrorAction Stop
        }
        Write-Verbose -Message "Creating azure VM context using subscription: $($NewVMSubscriptionContext.Subscription.Name)"

    }
    else
    {
        # VM is in a different subscription so set the context to this subscription
        $NewVMSubscriptionContext = Set-AzContext -SubscriptionId $VMSubscriptionId -ErrorAction Continue -ErrorVariable oErr
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
    # Find automation account if account name and resource group name not defined as input
    if (([string]::IsNullOrEmpty($AutomationResourceGroupName)) -or ([string]::IsNullOrEmpty($AutomationAccountName)))
    {
        Write-Verbose -Message ("Finding the ResourceGroup and AutomationAccount that this job is running in ...")
        if ([string]::IsNullOrEmpty($PSPrivateMetadata.JobId.Guid) )
        {
            Write-Error -Message "This is not running from the automation service. Please specify ResourceGroupName and AutomationAccountName as parameters" -ErrorAction Stop
        }

        $AutomationResource = Get-AzResource -ResourceType Microsoft.Automation/AutomationAccounts -AzContext $SubscriptionContext -ErrorAction Stop

        foreach ($Automation in $AutomationResource)
        {
            $Job = Get-AzAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -AzContext $SubscriptionContext -ErrorAction SilentlyContinue
            if (!([string]::IsNullOrEmpty($Job)))
            {
                $AutomationResourceGroupName = $Job.ResourceGroupName
                $AutomationAccountName = $Job.AutomationAccountName
                break;
            }
        }
        if ($AutomationAccountName)
        {
            Write-Output -InputObject "Using AA account: $AutomationAccountName in resource group: $AutomationResourceGroupName"
        }
        else
        {
            Write-Error -Message "Failed to discover automation account, execution stopped" -ErrorAction Stop
        }
    }
    # Check runbook is published in the automation account
    $EnableSolutionRunbook = Get-AzAutomationRunbook -ResourceGroupName $AutomationResourceGroupName `
        -AutomationAccountName $AutomationAccountName -Name $DependencyRunbookName `
        -AzContext $SubscriptionContext -ErrorAction SilentlyContinue

    if ($EnableSolutionRunbook.State -ne "Published" -and $EnableSolutionRunbook.State -ne "Edit")
    {
        Write-Verbose ("Importing $DependencyRunbookName runbook as it is not present..")
        $LocalFolder = Join-Path $Env:SystemDrive (New-Guid).Guid
        New-Item -ItemType directory $LocalFolder -Force | Write-Verbose

        (New-Object System.Net.WebClient).DownloadFile("https://raw.githubusercontent.com/mortenlerudjordet/runbooks/master/Utility/ARM/$DependencyRunbookName.ps1", "$LocalFolder\$DependencyRunbookName.ps1")
        Unblock-File -Path "$LocalFolder\$DependencyRunbookName.ps1" -ErrorAction Stop | Write-Verbose
        Import-AzAutomationRunbook -ResourceGroupName $AutomationResourceGroupName `
            -AutomationAccountName $AutomationAccountName -Path $LocalFolder\$DependencyRunbookName.ps1 `
            -Published -Type PowerShell -AzContext $SubscriptionContext -Force -ErrorAction Stop | Write-Verbose
        Remove-Item -Path $LocalFolder -Recurse -Force
    }
    Write-Verbose -Message "Retrieving VMs"
    # Get list of VMs that you want to onboard the solution to
    if ( -not [string]::IsNullOrEmpty($VMResourceGroupName) -and -not [string]::IsNullOrEmpty($VMName) )
    {
        Write-Verbose -Message "Retrieving single VM: $VMName"
        $VMList = Get-AzVM -ResourceGroupName $VMResourceGroupName -Name $VMName -AzContext $NewVMSubscriptionContext `
            -Status -ErrorAction Continue -ErrorVariable oErr | Where-Object {$_.Statuses.code -match "running"}
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve VM: $VMName to onboard object" -ErrorAction Stop
        }
    }
    elseif ( -not [string]::IsNullOrEmpty($VMResourceGroupName) )
    {
        Write-Verbose -Message "Retrieving all VMs in resource group: $VMResourceGroupName"
        $VMList = Get-AzVM -ResourceGroupName $VMResourceGroupName -AzContext $NewVMSubscriptionContext `
            -Status -ErrorAction Continue -ErrorVariable oErr | Where-Object {$_.PowerState -match "running"}
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve VMs to onboard objects from resource group: $VMResourceGroupName" -ErrorAction Stop
        }
    }
    else
    {
        Write-Verbose -Message "Retrieving all VMs in subscription: $($NewVMSubscriptionContext.Name)"
        # If the resource group was not required, but optional, all VMs in the subscription could be onboarded.
        $VMList = Get-AzVM -AzContext $NewVMSubscriptionContext -Status -ErrorAction Continue -ErrorVariable oErr | Where-Object {$_.PowerState -match "running"}
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve all VMs in subscription: $($NewVMSubscriptionContext.Name) to onboard objects" -ErrorAction Stop
        }
    }
    Write-Verbose -Message "Scheduling AA"
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
            $RunbookNameParams.Add("UpdateScopeQuery", $true)

            # Loop here until a job was successfully submitted. Will stay in the loop until job has been submitted or an exception other than max allowed jobs is reached
            while ($true)
            {
                try
                {
                    $Job = Start-AzAutomationRunbook -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName `
                        -Name $DependencyRunbookName -Parameters $RunbookNameParams `
                        -AzContext $SubscriptionContext -ErrorAction Stop
                    $Jobs.Add($VM.VMId, $Job)
                    # Submitted job successfully, exiting while loop
                    Write-Verbose -Message "Added VM id: $($VM.VMId) to AA job"
                    Write-Output -InputObject "Triggered onbording for solution: $SolutionType for VM: $($VM.Name)"
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
    foreach ($RunningJob in $Jobs.GetEnumerator())
    {
        $ActiveJob = Get-AzAutomationJob -ResourceGroupName $AutomationResourceGroupName `
            -AutomationAccountName $AutomationAccountName -Id $RunningJob.Value.JobId `
            -AzContext $SubscriptionContext
        while ($ActiveJob.Status -ne "Completed" -and $ActiveJob.Status -ne "Failed" -and $ActiveJob.Status -ne "Suspended" -and $ActiveJob.Status -ne "Stopped")
        {
            Start-Sleep 30
            $ActiveJob = Get-AzAutomationJob -ResourceGroupName $AutomationResourceGroupName `
                -AutomationAccountName $AutomationAccountName -Id $RunningJob.Value.JobId `
                -AzContext $SubscriptionContext
        }
        if ($ActiveJob.Status -eq "Completed")
        {
            Write-Output -InputObject "Onboarded VM: $($VM.Name) to solution: $SolutionType successfully"
        }
        $JobsResults += $ActiveJob
    }

    # Print out results of the automation jobs
    $JobFailed = $False
    foreach ($JobsResult in $JobsResults)
    {
        $OutputJob = Get-AzAutomationJobOutput -ResourceGroupName $AutomationResourceGroupName `
            -AutomationAccountName $AutomationAccountName -Id `
            $JobsResult.JobId -AzContext $SubscriptionContext -Stream Output
        foreach ($Stream in $OutputJob)
        {
            (Get-AzAutomationJobOutputRecord -ResourceGroupName $AutomationResourceGroupName `
                    -AutomationAccountName $AutomationAccountName -JobID $JobsResult.JobId `
                    -AzContext $SubscriptionContext -Id $Stream.StreamRecordId).Value
        }

        $ErrorJob = Get-AzAutomationJobOutput -ResourceGroupName $AutomationResourceGroupName `
            -AutomationAccountName $AutomationAccountName -Id `
            $JobsResult.JobId -AzContext $SubscriptionContext -Stream Error
        foreach ($Stream in $ErrorJob)
        {
            (Get-AzAutomationJobOutputRecord -ResourceGroupName $AutomationResourceGroupName `
                    -AutomationAccountName $AutomationAccountName -JobID $JobsResult.JobId `
                    -AzContext $SubscriptionContext -Id $Stream.StreamRecordId).Value
        }

        $WarningJob = Get-AzAutomationJobOutput -ResourceGroupName $AutomationResourceGroupName `
            -AutomationAccountName $AutomationAccountName -Id `
            $JobsResult.JobId -AzContext $SubscriptionContext -Stream Warning
        foreach ($Stream in $WarningJob)
        {
            (Get-AzAutomationJobOutputRecord -ResourceGroupName $AutomationResourceGroupName `
                    -AutomationAccountName $AutomationAccountName -JobID $JobsResult.JobId `
                    -AzContext $SubscriptionContext -Id $Stream.StreamRecordId).Value
        }

        if ($JobsResult.Status -ne "Completed")
        {
            $JobFailed = $True
        }
    }
    if ($JobFailed)
    {
        Write-Error -Message "Some jobs failed to complete successfully. Please see output stream for details." -ErrorAction Continue
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