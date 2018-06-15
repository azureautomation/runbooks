<#
.SYNOPSIS 
    This sample automation runbook onboards an Azure VM for either the Update or ChangeTracking (which includes Inventory) solution.
    It requires an existing Azure VM to already be onboarded to the solution as it uses this information to onboard the
    new VM to the same Log Analytics workspace and Automation Account.
    This Runbook needs to be run from the Automation account that you wish to connect the new VM to.

.DESCRIPTION
    This sample automation runbook onboards an Azure VM for either the Update or ChangeTracking (which includes Inventory) solution.
    It requires an existing Azure VM to already be onboarded to the solution as it uses this information to onboard the
    new VM to the same Log Analytics workspace and Automation Account.
    This Runbook needs to be run from the Automation account that you wish to connect the new VM to.

.PARAMETER VMName
    Required. The name of a specific VM that you want onboarded to the Updates or ChangeTracking solution

.PARAMETER ResourceGroupName
    Required. The name of the resource group that the VM is a member of.

.PARAMETER SubscriptionId
    Optional. The name subscription id where the new VM to onboard is located.
    This will default to the same one as the workspace if not specified. If you
    give a different subscription id then you need to make sure the RunAs account for
    this automaiton account is added as a contributor to this subscription also.

.PARAMETER ExistingVM
    Required. The name of the existing Azure VM that is already onboarded to the Updates or ChangeTracking solution

.PARAMETER ExistingVMResourceGroup
    Required. The name of resource group that the existing VM with the solution is a member of

.PARAMETER SolutionType
    Required. The name of the solution to onboard to this Automation account.
    It must be either "Updates" or "ChangeTracking". ChangeTracking also includes the inventory solution.

.PARAMETER UpdateScopeQuery
    Optional. Default is true. Indicates whether to add this VM to the list of computers to enable for this solution.
    Solutions enable an optional scope configuration to be set on them that contains a query of computers 
    to target the solution to. If you are calling this Runbook from a parent runbook that is onboarding
    multiple VMs concurrently, then you will want to set this to false and then do a final update of the
    search query with the list of onboarded computers to avoid any possible conflicts that this Runbook
    might do when reading, adding this VM, and updating the query since multiple versions of this Runbook
    might try and do this at the same time if run concurrently.

.Example
    .\Enable-AutomationSolution -VMName finance1 -ResourceGroupName finance `
             -ExistingVM hrapp1 -ExistingVMResourceGroup hr -SolutionType Updates

.Example
    .\Enable-AutomationSolution -VMName finance1 -ResourceGroupName finance `
             -ExistingVM hrapp1 -ExistingVMResourceGroup hr -SolutionType ChangeTracking -UpdateScopeQuery $False

.Example
    .\Enable-AutomationSolution -VMName finance1 -ResourceGroupName finance -SubscriptionId "1111-4fa371-22-46e4-a6ec-0bc48954" `
             -ExistingVM hrapp1 -ExistingVMResourceGroup hr -SolutionType Updates

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: June 4th, 2018
#>
 
Param (
    [Parameter(Mandatory=$True)]
    [String]
    $VMName,

    [Parameter(Mandatory=$True)]
    [String]
    $ResourceGroupName,

    [Parameter(Mandatory=$False)]
    [String]
    $SubscriptionId,

    [Parameter(Mandatory=$True)]
    [String]
    $ExistingVM,

    [Parameter(Mandatory=$True)]
    [String]
    $ExistingVMResourceGroup,

    [Parameter(Mandatory=$True)]
    [String]
    $SolutionType,

    [Parameter(Mandatory=$False)]
    [Boolean]
    $UpdateScopeQuery=$True 
    )

# Stop on errors
$ErrorActionPreference = 'stop'

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
    -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint | Write-Verbose

# Set subscription to work against
$SubscriptionContext = Set-AzureRmContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId 

if ([string]::IsNullOrEmpty($SubscriptionId))
{
    # Use the same subscription as the Automation account if not passed in
    $NewVMSubscriptionContext = Set-AzureRmContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId
    $SubscriptionId = $ServicePrincipalConnection.SubscriptionId
}
else 
{
    # VM is in a different subscription so set the context to this subscription
    $NewVMSubscriptionContext = Set-AzureRmContext -SubscriptionId $SubscriptionId
    
    # Register Automation provider if it is not registered on the subscription
    $AutomationProvider = Get-AzureRMResourceProvider -ProviderNamespace Microsoft.Automation `
                                                    -AzureRmContext $NewVMSubscriptionContext |  Where-Object {$_.RegistrationState -eq "Registered"}
    if ([string]::IsNullOrEmpty($AutomationProvider))
    {
        Register-AzureRmResourceProvider -ProviderNamespace Microsoft.Automation -AzureRmContext $NewVMSubscriptionContext | Write-Verbose
    }
}

# Get existing VM that is onboarded already to get information from it
$ExistingVMExtension = Get-AzureRmResource -ResourceGroupName $ExistingVMResourceGroup -Name $ExistingVM `
                                            -ResourceType Microsoft.Compute/virtualMachines/extensions -ExpandProperties -AzureRmContext $SubscriptionContext `
                                            | Where-Object {$_.Properties.type -eq "MicrosoftMonitoringAgent"}
                                
if ([string]::IsNullOrEmpty($ExistingVMExtension))
{
    throw ("Cannot find monitoring agent on exiting machine " + $ExistingVM + " in resource group " + $ExistingVMResourceGroup )
}   

$ExistingVMExtension = Get-AzureRmVMExtension -ResourceGroupName $ExistingVMResourceGroup -VMName $ExistingVM `
                                                -AzureRmContext $SubscriptionContext -Name $ExistingVMExtension.Name

# Check if the existing VM is already onboarded
$PublicSettings = ConvertFrom-Json $ExistingVMExtension.PublicSettings
if ([string]::IsNullOrEmpty($PublicSettings.workspaceId))
{
    throw ("This VM " + $ExistingVM + " is not onboarded. Please onboard first as it is used to collect information")
}

# Get information about the workspace
$WorkspaceInfo = Get-AzureRmOperationalInsightsWorkspace -AzureRmContext $SubscriptionContext `
                                                    | Where-Object {$_.CustomerId -eq $PublicSettings.workspaceId}

# Get the saved group that is used for solution targeting so we can update this with the new VM during onboarding..
$SavedGroups = Get-AzureRmOperationalInsightsSavedSearch -ResourceGroupName $WorkspaceInfo.ResourceGroupName `
                                         -WorkspaceName $WorkspaceInfo.Name -AzureRmContext $SubscriptionContext

# Get details of the new VM to onboard.
$NewVM = Get-AzureRMVM -ResourceGroupName $ResourceGroupName -Name $VMName `
                        -AzureRmContext $NewVMSubscriptionContext
$VMName = $NewVM.Name

# Workspace information
$WorkspaceResourceGroupName = $WorkspaceInfo.ResourceGroupName
$WorkspaceName = $WorkspaceInfo.Name
$WorkspaceResourceId = $WorkspaceInfo.ResourceId

# New VM information
$VMResourceGroupName = $NewVM.ResourceGroupName
$VMName = $NewVM.Name
$VMLocation = $NewVM.Location
$VMResourceId = $NewVM.Id
$VMIdentityRequired = $false

# Check if the VM is already onboarded to the MMA Agent and skip if it is
$Onboarded = Get-AzureRmVMExtension -ResourceGroup $ResourceGroupName  -VMName $VMName `
                -Name MicrosoftMonitoringAgent -AzureRmContext $NewVMSubscriptionContext -ErrorAction SilentlyContinue

if ([string]::IsNullOrEmpty($Onboarded))
{
    # Set up MMA agent information to onboard VM to the workspace
    if ($NewVM.StorageProfile.OSDisk.OSType -eq "Linux")
    {
        $MMAExentsionName = "OmsAgentForLinux"
        $MMATemplateLinkUri = "https://wcusonboardingtemplate.blob.core.windows.net/onboardingtemplate/ArmTemplate/createMmaLinuxV3.json"
    }
    elseif ($NewVM.StorageProfile.OSDisk.OSType -eq "Windows")  
    {
        $MMAExentsionName = "MicrosoftMonitoringAgent"
        $MMATemplateLinkUri = "https://wcusonboardingtemplate.blob.core.windows.net/onboardingtemplate/ArmTemplate/createMmaWindowsV3.json"      
    }
    else
    {
        Throw ("Could not determine OS of VM " + $NewVM.Name)
    }
    $MMADeploymentParams = @{}
    $MMADeploymentParams.Add("vmName", $VMName)
    $MMADeploymentParams.Add("vmLocation", $VMLocation)
    $MMADeploymentParams.Add("vmResourceId", $VMResourceId)
    $MMADeploymentParams.Add("vmIdentityRequired", $VMIdentityRequired)
    $MMADeploymentParams.Add("workspaceName",$WorkspaceName)
    $MMADeploymentParams.Add("workspaceId",$PublicSettings.workspaceId)
    $MMADeploymentParams.Add("workspaceResourceId", $WorkspaceResourceId)
    $MMADeploymentParams.Add("mmaExtensionName", $MMAExentsionName)

    # Create deployment name
    $DeploymentName = "AutomationControl-PS-" + (Get-Date).ToFileTimeUtc()

    # Deploy solution to new VM
    New-AzureRmResourceGroupDeployment -ResourceGroupName $VMResourceGroupName -TemplateUri $MMATemplateLinkUri `
                                        -Name $DeploymentName `
                                        -TemplateParameterObject $MMADeploymentParams `
                                        -AzureRmContext $NewVMSubscriptionContext | Write-Verbose
    Write-Output("VM " + $VMName + " successfully onboarded.")
}
else 
{
    Write-Warning("The VM " + $VMName + " already has the MMA agent installed. Skipping this one.")
}

# Update scope query if necessary
$SolutionGroup = $SavedGroups.Value | Where-Object {$_.Id -match "MicrosoftDefaultComputerGroup" -and $_.Properties.Category -eq $SolutionType}                                          

if (!([string]::IsNullOrEmpty($SolutionGroup)))
{
    if (!($SolutionGroup.Properties.Query -match $VMName) -and $UpdateScopeQuery)
    {
        $NewQuery = $SolutionGroup.Properties.Query.Replace('(',"(`"$VMName`", ")
        $ComputerGroupQueryTemplateLinkUri = "https://wcusonboardingtemplate.blob.core.windows.net/onboardingtemplate/ArmTemplate/updateKQLScopeQueryV2.json"                                       

        # Add all of the parameters
        $QueryDeploymentParams = @{}
        $QueryDeploymentParams.Add("location", $WorkspaceInfo.Location)
        $QueryDeploymentParams.Add("id", "/" + $SolutionGroup.Id)
        $QueryDeploymentParams.Add("resourceName", ($WorkspaceInfo.Name + "/" + $SolutionType + "|" + "MicrosoftDefaultComputerGroup").ToLower())
        $QueryDeploymentParams.Add("category", $SolutionType)
        $QueryDeploymentParams.Add("displayName", "MicrosoftDefaultComputerGroup")
        $QueryDeploymentParams.Add("query", $NewQuery)
        $QueryDeploymentParams.Add("functionAlias", $SolutionType + "__MicrosoftDefaultComputerGroup")
        $QueryDeploymentParams.Add("etag", $SolutionGroup.ETag)

        # Create deployment name
        $DeploymentName = "AutomationControl-PS-" + (Get-Date).ToFileTimeUtc()

        New-AzureRmResourceGroupDeployment -ResourceGroupName $WorkspaceResourceGroupName -TemplateUri $ComputerGroupQueryTemplateLinkUri `
                                            -Name $DeploymentName `
                                            -TemplateParameterObject $QueryDeploymentParams `
                                            -AzureRmContext $SubscriptionContext | Write-Verbose
    }
}
 
