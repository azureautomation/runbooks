#Requires -Module AzureRM.Profile
#Requires -Module AzureRM.Automation
#Requires -Module AzureRM.OperationalInsights
#Requires -Module AzureRM.Insights

<#
.SYNOPSIS 
    This automation runbook configures the account to send diagnostics logs to a log analytics workspace.
    It must be run from the azure automation service as it uses the RunAs credentials to configure the account.

.DESCRIPTION
    This automation runbook configures the account to send diagnostics logs to a log analytics workspace.
    It requires that the account has the AzureRM.OperationalInsights and AzureRM.Insights modules imported
    from the gallery first before runnning.

    If the account is already configured for a workspace then it will not change this unless the OverrideExisting
    parameter is set to $true. If an existing workspace and resource group is not specified then a new free workspace
    will be created in the same resource group as the automation account and in a similar region.

.PARAMETER Workspace
    Optional. The name of the Log Analytics workspace to send automation diganostics logs.
    If a name is not specified, then one will be automatically created.

.PARAMETER WorkspaceResourceGroup
    Optional. The name of the Log Analytics workspace resource group.
    If an existing workspace and resource group is not specified, then the existing Automation account
    resource group will be used.

.PARAMETER OverrideExisting
    Optional. If the automation account is already set up to send logs to a workspace, this should be
    set to $True to point to the new workspace. The default is $False and the existing workspace will be returned.

.EXAMPLE
    Set-AutomationDiagnostics

.Example
    Set-AutomationDiagnostics -Workspace "MyWorkspace" -WorkspaceResourceGroup "MyWorkspaceResourceGroup" -OverrideExisting $True

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: January 5th, 2017 
#>
[OutputType('Microsoft.Azure.Commands.Insights.OutputClasses.PSServiceDiagnosticSetting')]
Param
(
    [Parameter(Mandatory=$false)]
    $WorkspaceName,

    [Parameter(Mandatory=$false)]
    $WorkspaceResourceGroup,

    [Parameter(Mandatory=$false)]
    [Boolean] $OverrideExisting=$false
) 

　
    $RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection"         

    Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $RunAsConnection.TenantId `
        -ApplicationId $RunAsConnection.ApplicationId `
        -CertificateThumbprint $RunAsConnection.CertificateThumbprint | Write-Verbose

    Select-AzureRmSubscription -SubscriptionId $RunAsConnection.SubscriptionID  | Write-Verbose 

    Write-Verbose ("Finding the ResourceGroup and AutomationAccount that this job is running in ...")
    if ([string]::IsNullOrEmpty($PSPrivateMetadata.JobId.Guid))
    {
            throw "This runbook needs to be run from the automation service."
    }
    $AutomationResource = Get-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts

    foreach ($Automation in $AutomationResource)
    {
        $Job = Get-AzureRmAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
        if (!([string]::IsNullOrEmpty($Job)))
        {
                $AutomationAccountResourceGroup = $Job.ResourceGroupName
                $AutomationAccountName = $Job.AutomationAccountName
                $AutomationLocation = $Automation.Location
                $AutomationResourceID = $Automation.ResourceId
                break;
        }
    }

    # Check that OperationalInsights Module is in the automation account
    $module = Get-AzureRmAutomationModule -ResourceGroupName $AutomationAccountResourceGroup -AutomationAccountName $AutomationAccountName -Name AzureRM.OperationalInsights -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($module))
    {
        throw ("AzureRM.OperationalInsights module is not in the automation account. Please update your Azure modules to the latest versions and then import this module from the gallery")
    }

    if ($module.Version -lt "2.4.0")
    {
        throw ("AzureRM.OperationalInsights module version is less than 2.4.0. Please update your Azure modules to the latest versions and then import this module from the gallery")
    }

    # Check that AzureRM.Insights Module is in the automation account
    $module = Get-AzureRmAutomationModule -ResourceGroupName $AutomationAccountResourceGroup -AutomationAccountName $AutomationAccountName -Name AzureRM.Insights -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($module))
    {
        throw ("AzureRM.Insights module is not in the automation account. Please update your Azure modules to the latest versions and then import this module from the gallery")
    }

    if ($module.Version -lt "2.4.0")
    {
        throw ("AzureRM.Insights module version is less than 2.4.0. Please update your Azure modules to the latest versions and then import this module from the gallery")
    }

    # Check if this automation account is already sending logs to a workspace
    $ExistingDiagnostics = Get-AzureRmDiagnosticSetting -ResourceId $AutomationResourceID
    if ((!($OverrideExisting)) -and (!([string]::IsNullOrEmpty($ExistingDiagnostics.WorkspaceId))))
    {
            throw ("This automation account is already sending logs to " + $ExistingDiagnostics.WorkspaceId + ". Set OverrideExisting parameter to true to update to new workspace")
    }

    if ((!([string]::IsNullOrEmpty($WorkspaceResourceGroup)) -and (!([string]::IsNullOrEmpty($WorkspaceName)))))
    {
        $Workspace = Get-AzureRmResource -ResourceGroupName $WorkspaceResourceGroup -ResourceName $WorkspaceName
    }
    else
    {
        # Set the location of the Log Analytics workspace to closet region as the Automation Account.
        if ($AutomationLocation -match "europe") {
            $WorkspaceLocation = "westeurope"
        } elseif ($AutomationLocation -match "asia") {
            $WorkspaceLocation = "southeastasia"
        } elseif ($AutomationLocation -match "australia") {
            $WorkspaceLocation = "australiasoutheast"
        } else {
            $WorkspaceLocation = "eastus"
        }
        $Workspace = New-AzureRmOperationalInsightsWorkspace -Location $WorkspaceLocation -Name ($AutomationAccountName + "Workspace" + (Get-Random -Maximum 99999)) -Sku free -ResourceGroupName $AutomationAccountResourceGroup 
}

Set-AzureRmDiagnosticSetting -ResourceId $AutomationResourceID -WorkspaceId $Workspace.ResourceId -Enabled $true

　
 
