<#
    .DESCRIPTION
        A script to enable the system assigned identity in an automation account and assign the same set of permissions present in automation run as account to System Assigned identity of the automation account

        Prerequisites: 
        1. .NET framework 4.7.2 or later installed.
        2. Windows PowerShell version 5.1(64-bit) or later installed and run with Administrator permissions.
        3. Azure Az PowerShell module latest version installed, having minimum version Az.Accounts (2.5.4)`, `Az.Resources (4.4.0)` & `Az.Automation (1.7.1)` cmdlets
        4. You need the following permissions on the Azure user account:
            a. ‘Contributor’ access on the Azure subscription that has the Azure Automation account, and
            b. Owner permissions on the associated Run-As-Account Azure AD Application.

    .PARAMETER subscriptionId
        [Required] Subscription id where the automation account is present.

    .PARAMETER resourceGroupName
        [Required] Resource group of the automation account

    .PARAMETER accountName
        [Required] Name of automation account.

    .PARAMETER Env
    [Optional] Cloud environment name. 'AzureCloud' by default.

    .EXAMPLE
        PS> .\AssignMIRunAsRoles.ps1 -subscriptionId subId -resourceGroupName rgName -accountName accName

    .NOTES
        AUTHOR: Azure Automation Team
        LASTEDIT: June 5, 2023
#>

Param(
    [Parameter(Mandatory = $true)]
    [string] $subscriptionId,  
    [Parameter(Mandatory = $true)]
    [string] $resourceGroupName,
    [Parameter(Mandatory = $true)]
    [string] $accountName,
    [ValidateSet("AzureCloud", "AzureUSGovernment", "AzureChinaCloud")]
    [Parameter(Mandatory = $false, HelpMessage = "Cloud environment name. 'AzureCloud' by default")]
    [string]
    $Env = "AzureCloud"
)

Function AssignRunAsRoleToSystemIdentity
{
    param(
        $roleAssignment,
        $identityObjectId
    )
    $roleName = $roleAssignment.RoleDefinitionName
    $roleDefinitionId = $roleAssignment.RoleDefinitionId
    $scope = $roleAssignment.Scope
    Write-Output "The following role is assigned to Run As Account"
    Write-Output "Role: " $roleName
    Write-Output "Role Id: " $roleDefinitionId
    Write-Output "Scope: " $scope

    $assignRole = Read-Host "Do you want to assign this role to your System Identity? (If the role is Contributor, please re-evaluate your requirements and assign the lowest possible role). Note: if the role is already assigned, it will lead to 'Conflict error'. (Y/N): "

    if ($assignRole -ne "Y" -and $assignRole -ne 'y' -and $assignRole -ne "YES" -and $assignRole -ne "Yes") {
        continue
    }
    else {
        # Create the role assignment for the managed identity
        New-AzRoleAssignment -ObjectId $identityObjectId -RoleDefinitionId $roleDefinitionId -Scope $scope
    }
}

Connect-AzAccount -Environment $Env -ErrorAction Stop > $null

# ---------------------------------------------------------------------------------------------
# Enable System Assigned MI if not enabled.
$account = Get-AzAutomationAccount -ResourceGroupName $resourceGroupName -Name $accountName

$identityType = "SystemAssigned"

if ($account.Identity.UserAssignedIdentities) {
    $identityType = "SystemAssigned,UserAssigned"
} else {

    $userToken = (Get-AzAccessToken).Token
    $Headers = @{
        "Authorization" = "Bearer $userToken"
    }
    
    # Set the request body
    $body = @{
        "identity" = @{
            "type" = $identityType
        }
    } | ConvertTo-Json

    $requestUrl = "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${resourceGroupName}/providers/Microsoft.Automation/automationAccounts/${accountName}?api-version=2021-06-22"
    Invoke-RestMethod -Method "PATCH" -Uri "$($requestUrl)" -ContentType "application/json" -Headers $Headers -Body $body
}

# ------------------------------------------------------------------------------------------------
# Check if run as account is present. If so, assign the roles to System identity enabled previously.
$account = Get-AzAutomationAccount -ResourceGroupName $resourceGroupName -Name $accountName
$connection = Get-AzAutomationConnection -ResourceGroupName $resourceGroupName -AutomationAccountName $accountName -Name "AzureRunAsConnection"


if ($connection) {

    $identityObjectId = $account.Identity.PrincipalId
    $runAsAppId = $connection.FieldDefinitionValues.ApplicationId

    $roleAssignments = Get-AzRoleAssignment -ServicePrincipalName $runAsAppId
    #assign roles to the system identity
    if ($roleAssignments) {
        if ($roleAssignments.GetType().IsArray) {
            foreach ($roleAssignment in $roleAssignments) {
                if ($roleAssignment) {
                    AssignRunAsRoleToSystemIdentity -roleAssignment $roleAssignment -identityObjectId $identityObjectId
                }
            }
        } else {
            if ($roleAssignments) {
                AssignRunAsRoleToSystemIdentity -roleAssignment $roleAssignments -identityObjectId $identityObjectId
            }
        }
    } else {
        Write-Output "The run as account has no roles assigned."
    }
    
} else {
    Write-Output "No run as account present in automation account: " + $accountName 
}




