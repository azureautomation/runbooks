<#
.SYNOPSIS
    Maintanance Runbook to update and remove retired VMs from solution saved searched in Log Analytics.
    Solutions supported are Update Management and Change Tracking.
    It will also check for duplicate hybrid worker entires and remove these.
    In addition it will check for stale workers and log this as a warning. If automation account is integrated with log analytics one can create alert to trigger when warning is logged.

    To set what Log Analytics workspace to use for Update and Change Tracking management (bypassing the logic that search for an existing onboarded VM),
    create the following AA variable assets:
        LASolutionSubscriptionId and populate with subscription ID of where the Log Analytics workspace is located
        LASolutionWorkspaceId and populate with the Workspace Id of the Log Analytics workspace

.DESCRIPTION
    This Runbooks assumes both Azure Automation account and Log Analytics account is in the same subscription
    For best effect schedule this Runbook to run on a recurring schedule to periodically search for retired VMs.

    Example of Log Analytics query for alerting:
        AzureDiagnostics
        | where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams" and StreamType_s == "Warning" and RunbookName_s == "Format-AutomationSolutionSearchAz"
        | sort by TimeGenerated asc
        | summarize makelist(ResultDescription, 1000) by JobId_g, bin(TimeGenerated, 1d),RunbookName_s, StreamType_s
        | sort by TimeGenerated desc
        | limit 1
        | project RunbookName_s , StreamType_s, list_ResultDescription

.COMPONENT
    To predefine what Log Analytics workspace to use, create the following AA variable assets:
        LASolutionSubscriptionId
        LASolutionWorkspaceId

.PARAMETER HybridWorkerStaleNrDays
    Optional. Threshold for when hybrid workers are reported as stale and in need of maintenance.
    It is also used by logic that removes duplicate hybrid worker entries
    Default is 7 days

.PARAMETER IgnoreLinuxMissingTag
    Optional. As Linux VMs need the VMUUID tag to correctly be identified an not removed from the solution search.
    This setting will override default behavior not to do cleanup of VMUUID if Linux VMs without the VMUUID tag is detected.
    Default is $False, this will skip cleaning search if a Linux VM without VMUUID tag is detected.
    Set to $True to force VMUUID cleanup even if Linux VMs without the VMUUID tag is detected.

.NOTES
    AUTHOR: Morten Lerudjordet
    LASTEDIT: July 9th, 2019
#>
#Requires -Version 5.0
param(
    [ValidateRange(0, [double]::MaxValue)]
    [double]$HybridWorkerStaleNrDays = 7,

    [Parameter(Mandatory = $False)]
    [Boolean]
    $IgnoreLinuxMissingTag = $False
)
try
{
    $RunbookName = "Format-AutomationSolutionSearchAz"
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
    $SolutionApiVersion = "2017-04-26-preview"
    $SolutionTypes = @("Updates", "ChangeTracking")
    #endregion

    # Authenticate to Azure
    $ServicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
    $Null = Add-AzAccount `
        -ServicePrincipal `
        -TenantId $ServicePrincipalConnection.TenantId `
        -ApplicationId $ServicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to connect to Azure" -ErrorAction Stop
    }

    # Set subscription to work against
    $SubscriptionContext = Set-AzContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to set azure context to subscription for AA" -ErrorAction Stop
    }
    #region Collect data
    # Find automation account if account name and resource group name not defined as input
    if (([string]::IsNullOrEmpty($AutomationResourceGroupName)) -or ([string]::IsNullOrEmpty($AutomationAccountName)))
    {
        Write-Verbose -Message ("Finding the ResourceGroup and AutomationAccount that this job is running in ...")
        if ([string]::IsNullOrEmpty($PSPrivateMetadata.JobId.Guid) )
        {
            Write-Error -Message "This is not running from the automation service. Please specify ResourceGroupName and AutomationAccountName as parameters" -ErrorAction Stop
        }

        $AutomationResource = Get-AzResource -ResourceType Microsoft.Automation/AutomationAccounts -ErrorAction Stop

        foreach ($Automation in $AutomationResource)
        {
            $Job = Get-AzAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
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

    # Get all VMs AA account has read access to
    $AllAzureVMs = Get-AzSubscription |
        Foreach-object { $Context = Set-AzContext -SubscriptionId $_.SubscriptionId; Get-AzVM -AzContext $Context} |
        Select-Object -Property Name, VmId, StorageProfile, Tags

    $SkipVMUUIDCleanup = $false
    foreach($AzureVM in $AllAzureVMs)
    {
        # Check OS types
        if($AzureVM.StorageProfile.OsDisk.OsType -eq "Linux")
        {
            # Get VMUUID from tags
            if($AzureVM.Tags.VMUUID)
            {
                # Hijack VMid for VMUUID usage
                $AzureVM.VmId = $AzureVM.Tags.VMUUID
                Write-Output -InputObject "Updated VMid with VMUUID for Linux VM: $($AzureVM.Name). UUID value from tag is: $($AzureVM.Tags.VMUUID)"
            }
            else
            {
                Write-Warning -Message "Linux VM: $($AzureVM.Name) was not onboarded with automation solution and is missing VMUUID tag. Manually add it to VM and run job again. Linux UUID must be attained from inside OS using dmidecode command"
                $SkipVMUUIDCleanup = $true
            }
        }
    }

    if ($Null -ne $LogAnalyticsSolutionWorkspaceId)
    {
        $WorkspaceInfo = Get-AzOperationalInsightsWorkspace -AzContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr |
            Where-Object {$_.CustomerId -eq $LogAnalyticsSolutionWorkspaceId}
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve Log Analytic workspace info" -ErrorAction Stop
        }
    }
    else
    {
        # Get information about the workspace
        $WorkspaceInfo = Get-AzOperationalInsightsWorkspace -AzContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve Log Analytic workspace info" -ErrorAction Stop
        }
        if ($Null -eq $WorkspaceInfo -and $WorkspaceInfo.Count -gt 1)
        {
            Write-Error -Message "Failed to retrieve Log Analytic workspace information. Or multiple Log Analytic workspaces was returned" -ErrorAction Stop
        }
    }


    # Get the saved group that is used for solution targeting so we can update this with the new VM during onboarding..
    if ($Null -ne $WorkspaceInfo)
    {
        $SavedGroups = Get-AzOperationalInsightsSavedSearch -ResourceGroupName $WorkspaceInfo.ResourceGroupName `
            -WorkspaceName $WorkspaceInfo.Name -AzContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve Operational Insight saved groups info" -ErrorAction Stop
        }
    }
    #endregion

    #region hybrid worker maintenance
    $HybridWorkerGroups = Get-AzAutomationHybridWorkerGroup -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName -AzContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr `
        | Where-Object {$_.GroupType -eq "System"}
    if ($oErr)
    {
        Write-Error -Message "Failed to retrieve hybrid worker groups, no maintenance will be done on hybrid workers" -ErrorAction Continue
    }
    if($HybridWorkerGroups)
    {
        # Check for duplicate entries
        $RemovedHybridWorkers = $HybridWorkerGroups.RunbookWorker | Sort-Object -Property Name -Unique
        $DuplicateHybridWorkers = Compare-Object -ReferenceObject $RemovedHybridWorkers -DifferenceObject $HybridWorkerGroups.RunbookWorker -Property Name | Where-Object {$_.SideIndicator -eq "=>"}

        foreach ($HybridWorkerGroup in $HybridWorkerGroups)
        {
            if ($DuplicateHybridWorkers)
            {
                if ($DuplicateHybridWorkers.Name -contains $HybridWorkerGroup.RunbookWorker.Name)
                {
                    Write-Output -InputObject "Hybrid worker: $($HybridWorkerGroup.RunbookWorker.Name) has duplicates"
                    # Check if it has checked in the last week
                    if ($HybridWorkerGroup.RunbookWorker.LastSeenDateTime -le (Get-Date).AddDays(-$HybridWorkerStaleNrDays))
                    {
                        Write-Output -InputObject "Hybrid worker: $($HybridWorkerGroup.Name) has not reported in for the last $HybridWorkerStaleNrDays days"
                        Write-Output -InputObject "Removing duplicate hybrid worker: $($HybridWorkerGroup.Name)"
                        Remove-AzAutomationHybridWorkerGroup -Name $HybridWorkerGroup.Name -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName -AzContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
                        if ($oErr)
                        {
                            Write-Error -Message "Failed to remove hybrid worker: $($HybridWorkerGroup.Name) identified as a duplicate and stale" -ErrorAction Continue
                        }
                        else
                        {
                            Write-Output -InputObject "Hybrid worker: $($HybridWorkerGroup.Name) successfully removed"
                        }
                    }
                }
            }
            # Check for stale hybrid workers
            if ($HybridWorkerGroup.RunbookWorker.LastSeenDateTime -le [DateTimeOffset]::Now.AddDays(-$HybridWorkerStaleNrDays))
            {
                Write-Warning -Message "Hybrid worker: $($HybridWorkerGroup.Name) has not reported in for the last $HybridWorkerStaleNrDays days. Hours since last seen: $([math]::Round(([DateTimeOffset]::Now - ($HybridWorkerGroup.RunbookWorker.LastSeenDateTime)).TotalHours))"
            }
            else
            {
                Write-Output -InputObject "Hybrid worker: $($HybridWorkerGroup.Name) has reported inn the last: $HybridWorkerStaleNrDays days"
            }
        }
    }
    else
    {
        Write-Output -InputObject "No system hybrid workers found"
    }
    #endregion

    #region Log Analytics query maintenance
    foreach ($SolutionType in $SolutionTypes)
    {
        $UpdatedQuery = $null
        Write-Output -InputObject "Processing solution type: $SolutionType"
        $SolutionGroup = $SavedGroups.Value | Where-Object {$_.Id -match "MicrosoftDefaultComputerGroup" -and $_.Properties.Category -eq $SolutionType}
        # Check that solution is deployed
        if ($Null -ne $SolutionGroup)
        {
            $SolutionQuery = $SolutionGroup.Properties.Query

            if ($Null -ne $SolutionQuery)
            {
                # Get all VMs from Computer and VMUUID  in Query
                $VmIds = (((Select-String -InputObject $SolutionQuery -Pattern "VMUUID in~ \((.*?)\)").Matches.Groups[1].Value).Split(",")).Replace("`"", "") | Where-Object {$_} | Select-Object -Property @{l = "VmId"; e = {$_.Trim()}}
                $VmNames = (((Select-String -InputObject $SolutionQuery -Pattern "Computer in~ \((.*?)\)").Matches.Groups[1].Value).Split(",")).Replace("`"", "")  | Where-Object {$_} | Select-Object -Property @{l = "Name"; e = {$_.Trim()}}

                # Remove empty elements
                if (($SolutionQuery -match ',"",') -or ($SolutionQuery -match '", "') -or ($SolutionQuery -match ',""') )
                {
                    # Clean search of whitespace between elements
                    $UpdatedQuery = $SolutionQuery.Replace('", "', '","')
                    # Clean empty elements from search
                    $UpdatedQuery = $UpdatedQuery.Replace(',"",', ',')
                    # Clean empty end element from search
                    $UpdatedQuery = $UpdatedQuery.Replace(',""', '')
                }

                if ($Null -ne $VmIds)
                {
                    # Remove duplicate entries
                    $DuplicateVmIDs = $VmIds | Sort-Object -Property VmId -Unique
                    $DuplicateVmIDs = Compare-Object -ReferenceObject $DuplicateVmIDs -DifferenceObject $VmIds -Property VmId | Where-Object {$_.SideIndicator -eq "=>"} | Sort-Object -Property VmId -Unique
                    if ($DuplicateVmIDs)
                    {
                        foreach ($DuplicateVmID in $DuplicateVmIDs)
                        {
                            if ($Null -eq $UpdatedQuery)
                            {
                                $UpdatedQuery = $SolutionQuery.Replace("`"$($DuplicateVmID.VmId)`",", "")
                                Write-Output -InputObject "Removing duplicate VM entry with Id: $($DuplicateVmID.VmId) from saved search"
                                # check if is an end element, need to remove differently
                                if($UpdatedQuery -match $DuplicateVmID.VmId)
                                {
                                    $UpdatedQuery = $SolutionQuery.Replace(",`"$($DuplicateVmID.VmId)`"", "")
                                    # Check if last element in search
                                    if($UpdatedQuery -match $DuplicateVmID.VmId)
                                    {
                                        $UpdatedQuery = $SolutionQuery.Replace("`"$($DuplicateVmID.VmId)`"", '""')
                                    }
                                }
                            }
                            else
                            {
                                $UpdatedQuery = $UpdatedQuery.Replace("`"$($DuplicateVmID.VmId)`",", "")
                                Write-Output -InputObject "Removing duplicate VM entry with Id: $($DuplicateVmID.VmId) from saved search"
                                if($UpdatedQuery -match $DuplicateVmID.VmId)
                                {
                                    $UpdatedQuery = $SolutionQuery.Replace(",`"$($DuplicateVmID.VmId)`"", "")
                                    # Check if last element in search
                                    if($UpdatedQuery -match $DuplicateVmID.VmId)
                                    {
                                        $UpdatedQuery = $SolutionQuery.Replace("`"$($DuplicateVmID.VmId)`"", '""')
                                    }
                                }
                            }
                        }
                    }
                    else
                    {
                        Write-Output -InputObject "No duplicate VM Ids to delete found"
                    }
                    if($AllAzureVMs)
                    {
                        if(-not $SkipVMUUIDCleanup -or $IgnoreLinuxMissingTag)
                        {
                            # Get VM Ids that are no longer alive
                            $DeletedVmIds = Compare-Object -ReferenceObject $VmIds -DifferenceObject $AllAzureVMs -Property VmId | Where-Object {$_.SideIndicator -eq "<="}
                            if ($DeletedVmIds)
                            {
                                # Remove deleted VM Ids from saved search query
                                foreach ($DeletedVmId in $DeletedVmIds)
                                {
                                    if ($Null -eq $UpdatedQuery)
                                    {
                                        $UpdatedQuery = $SolutionQuery.Replace("`"$($DeletedVmId.VmId)`",", "")
                                        Write-Output -InputObject "Removing VM with Id: $($DeletedVmId.VmId) from saved search"
                                        # check if end element in search
                                        if($UpdatedQuery -match $DeletedVmIds.VmId)
                                        {
                                            $UpdatedQuery = $SolutionQuery.Replace(",`"$($DeletedVmIds.VmId)`"", "")
                                            # Check if last element in search
                                            if($UpdatedQuery -match $DeletedVmIds.VmId)
                                            {
                                                $UpdatedQuery = $SolutionQuery.Replace("`"$($DeletedVmIds.VmId)`"",'""')
                                            }
                                        }
                                    }
                                    else
                                    {
                                        $UpdatedQuery = $UpdatedQuery.Replace("`"$($DeletedVmId.VmId)`",", "")
                                        Write-Output -InputObject "Removing VM with Id: $($DeletedVmId.VmId) from saved search"
                                        # check if end element in search
                                        if($UpdatedQuery -match $DeletedVmIds.VmId)
                                        {
                                            $UpdatedQuery = $SolutionQuery.Replace(",`"$($DeletedVmIds.VmId)`"", "")
                                                                                        # Check if last element in search
                                            if($UpdatedQuery -match $DeletedVmIds.VmId)
                                            {
                                                $UpdatedQuery = $SolutionQuery.Replace("`"$($DeletedVmIds.VmId)`"", "")
                                                # Check if last element in search
                                                if($UpdatedQuery -match $DeletedVmIds.VmId)
                                                {
                                                    $UpdatedQuery = $SolutionQuery.Replace("`"$($DeletedVmIds.VmId)`"", '""')
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            else
                            {
                                Write-Output -InputObject "No VM Ids to delete found"
                            }
                        }
                        else
                        {
                            Write-Warning -Message "Found Linux VMs, skipping VMUUID cleanup as not all Linux VMs have the VMUUID tag set"
                        }
                    }
                    else
                    {
                        Write-Output -InputObject "No VMs found in subscriptions"
                    }
                }
                else
                {
                    Write-Output -InputObject "There are no VM Ids in saved search"
                }

                # Get VM Names that are no longer alive
                if ($Null -ne $VmNames)
                {
                    # Remove duplicate entries
                    $DuplicateVms = $VmNames | Sort-Object -Property Name -Unique
                    $DuplicateVms = Compare-Object -ReferenceObject $DuplicateVms -DifferenceObject $VmNames -Property Name | Where-Object {$_.SideIndicator -eq "=>"} | Sort-Object -Property Name -Unique
                    if ($DuplicateVms)
                    {
                        foreach ($DuplicateVm in $DuplicateVms)
                        {
                            if ($Null -eq $UpdatedQuery)
                            {
                                $UpdatedQuery = $SolutionQuery.Replace("`"$($DuplicateVm.Name)`",", "")
                                Write-Output -InputObject "Removing duplicate VM entry with Name: $($DuplicateVm.Name) from saved search"
                                if($UpdatedQuery -match $DuplicateVm.Name)
                                {
                                    $UpdatedQuery = $SolutionQuery.Replace(",`"$($DuplicateVm.Name)`"", "")
                                    if($UpdatedQuery -match $DuplicateVm.Name)
                                    {
                                        $UpdatedQuery = $SolutionQuery.Replace("`"$($DuplicateVm.Name)`"", '""')
                                    }
                                }
                            }
                            else
                            {
                                $UpdatedQuery = $UpdatedQuery.Replace("`"$($DuplicateVm.Name)`",", "")
                                Write-Output -InputObject "Removing duplicate VM entry with Name: $($DuplicateVm.Name) from saved search"
                                if($UpdatedQuery -match $DuplicateVm.Name)
                                {
                                    $UpdatedQuery = $SolutionQuery.Replace(",`"$($DuplicateVm.Name)`"", "")
                                    if($UpdatedQuery -match $DuplicateVm.Name)
                                    {
                                        $UpdatedQuery = $SolutionQuery.Replace("`"$($DuplicateVm.Name)`"", '""')
                                    }
                                }
                            }
                        }
                    }
                    else
                    {
                        Write-Output -InputObject "No duplicate VM names to delete found"
                    }
                    if($AllAzureVMs)
                    {
                        $DeletedVms = Compare-Object -ReferenceObject $VmNames -DifferenceObject $AllAzureVMs -Property Name | Where-Object {$_.SideIndicator -eq "<="}
                        if ($DeletedVms)
                        {
                            # Remove deleted VM Names from saved search query
                            foreach ($DeletedVm in $DeletedVms)
                            {
                                if ($Null -eq $UpdatedQuery)
                                {
                                    $UpdatedQuery = $SolutionQuery.Replace("`"$($DeletedVm.Name)`",", "")
                                    Write-Output -InputObject "Removing VM with Name: $($DeletedVmId.Name) from saved search"
                                    if($UpdatedQuery -match $DeletedVmId.Name)
                                    {
                                        $UpdatedQuery = $SolutionQuery.Replace(",`"$($DeletedVmId.Name)`"", "")
                                        if($UpdatedQuery -match $DeletedVmId.Name)
                                        {
                                            $UpdatedQuery = $SolutionQuery.Replace("`"$($DeletedVmId.Name)`"", '""')
                                        }
                                    }
                                }
                                else
                                {
                                    $UpdatedQuery = $UpdatedQuery.Replace("`"$($DeletedVm.Name)`",", "")
                                    Write-Output -InputObject "Removing VM with Name: $($DeletedVmId.Name) from saved search"
                                    if($UpdatedQuery -match $DeletedVmId.Name)
                                    {
                                        $UpdatedQuery = $SolutionQuery.Replace(",`"$($DeletedVmId.Name)`"", "")
                                        if($UpdatedQuery -match $DeletedVmId.Name)
                                        {
                                            $UpdatedQuery = $SolutionQuery.Replace("`"$($DeletedVmId.Name)`"", '""')
                                        }
                                    }
                                }
                            }
                        }
                        else
                        {
                            Write-Output -InputObject "No VM to delete found"
                        }
                    }
                    else
                    {
                        Write-Output -InputObject "No VMs found in subscriptions"
                    }
                }
                else
                {
                    Write-Output -InputObject "There are no VM Names in saved search"
                }

                if ($Null -ne $UpdatedQuery)
                {
                    #region Solution Onboarding ARM Template
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
                    #endregion
                    # Create temporary file to store ARM template in
                    $TempFile = New-TemporaryFile -ErrorAction Continue -ErrorVariable oErr
                    if ($oErr)
                    {
                        Write-Error -Message "Failed to create temporary file for solution ARM template" -ErrorAction Stop
                    }
                    Out-File -InputObject $ArmTemplate -FilePath $TempFile.FullName -ErrorAction Continue -ErrorVariable oErr
                    if ($oErr)
                    {
                        Write-Error -Message "Failed to write ARM template for solution to temp file" -ErrorAction Stop
                    }
                    # Add all of the parameters
                    $QueryDeploymentParams = @{}
                    $QueryDeploymentParams.Add("location", $WorkspaceInfo.Location)
                    $QueryDeploymentParams.Add("id", "/" + $SolutionGroup.Id)
                    $QueryDeploymentParams.Add("resourceName", ($WorkspaceInfo.Name + "/" + $SolutionType + "|" + "MicrosoftDefaultComputerGroup").ToLower())
                    $QueryDeploymentParams.Add("category", $SolutionType)
                    $QueryDeploymentParams.Add("displayName", "MicrosoftDefaultComputerGroup")
                    $QueryDeploymentParams.Add("query", $UpdatedQuery)
                    $QueryDeploymentParams.Add("functionAlias", $SolutionType + "__MicrosoftDefaultComputerGroup")
                    $QueryDeploymentParams.Add("etag", $SolutionGroup.ETag)
                    $QueryDeploymentParams.Add("apiVersion", $SolutionApiVersion)

                    # Create deployment name
                    $DeploymentName = "AutomationControl-PS-" + (Get-Date).ToFileTimeUtc()

                    $ObjectOutPut = New-AzResourceGroupDeployment -ResourceGroupName $WorkspaceInfo.ResourceGroupName -TemplateFile $TempFile.FullName `
                        -Name $DeploymentName `
                        -TemplateParameterObject $QueryDeploymentParams `
                        -AzContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
                    if ($oErr)
                    {
                        Write-Error -Message "Failed to update solution type: $SolutionType saved search" -ErrorAction Stop
                    }
                    else
                    {
                        Write-Output -InputObject $ObjectOutPut
                        Write-Output -InputObject "Successfully updated solution type: $SolutionType saved search"
                    }

                    # Remove temp file with arm template
                    Remove-Item -Path $TempFile.FullName -Force
                }
                else
                {
                    Write-Output -InputObject "No retired VMs found, therefore no update to solution saved search will be done"
                }
            }
            else
            {
                Write-Warning -Message "Failed to retrieve saved search query for solution: $SolutionType"
            }
        }
        else
        {
            Write-Output -InputObject "Solution: $SolutionType is not deployed"
        }
    }
    #endregion
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