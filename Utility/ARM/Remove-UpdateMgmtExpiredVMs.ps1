try
{
    Write-Verbose -Message  "Starting Runbook at time: $(get-Date -format r). Running PS version: $($PSVersionTable.PSVersion)"

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
    $LogAnalyticsAgentExtensionName = "OMSExtension"
    $LAagentApiVersion = "2015-06-15"
    $LAsolutionUpdateApiVersion = "2017-04-26-preview"
    #endregion

    # Authenticate to Azure
    $ServicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
    $Null = Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $ServicePrincipalConnection.TenantId `
        -ApplicationId $ServicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to connect to Azure" -ErrorAction Stop
    }

    $AzureRmSubscriptions = Get-AzureRmSubscription

    # Get information about the workspace
    $WorkspaceInfo = Get-AzureRmOperationalInsightsWorkspace -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to retrieve Operational Insight workspace info" -ErrorAction Stop
    }
    if ($Null -ne $WorkspaceInfo)
    {
        # Workspace information
        $WorkspaceResourceGroupName = $WorkspaceInfo.ResourceGroupName
        $WorkspaceName = $WorkspaceInfo.Name
        $WorkspaceResourceId = $WorkspaceInfo.ResourceId
    }
    else
    {
        Write-Error -Message "Failed to retrieve Operational Insights Workspace information" -ErrorAction Stop
    }

    # Get the saved group that is used for solution targeting so we can update this with the new VM during onboarding..
    $SavedGroups = Get-AzureRmOperationalInsightsSavedSearch -ResourceGroupName $WorkspaceInfo.ResourceGroupName `
        -WorkspaceName $WorkspaceInfo.Name -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to retrieve Operational Insight saved groups info" -ErrorAction Stop
    }

    $SolutionGroup = $SavedGroups.Value | Where-Object {$_.Id -match "MicrosoftDefaultComputerGroup" -and $_.Properties.Category -eq $SolutionType}

    $UpdatesQuery = $SolutionGroup.Properties.Query

    # Get all VMs from Computer and VMUUID  in Query
    $VmIds = (((Select-String -InputObject $UpdatesQuery -Pattern "VMUUID in~ \((.*?)\)").Matches.Groups[1].Value).Split(",")).Replace("`"", "") | Where-Object {$_}
    $VmNames = (((Select-String -InputObject $UpdatesQuery -Pattern "Computer in~ \((.*?)\)").Matches.Groups[1].Value).Split(",")).Replace("`"", "")  | Where-Object {$_}

    # Fetch all VMs by their ID's and check if they are still in use
    foreach ($VmId in $VmIds)
    {

    }
    # Fetch all VMs by their Names and check if they are still in use
    foreach ($VmName in $VmNames)
    {

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
