<#
    .DESCRIPTION
        A runbook to find all the runbooks in a given automation account which are using run as account

    .NOTES
        AUTHOR: Azure Automation Team
        LASTEDIT: May 25, 2023
#>

Param(
    [Parameter(Mandatory = $true)]
    [string] $subscriptionId,  
    [Parameter(Mandatory = $true)]
    [string] $resourceGroupName,
    [Parameter(Mandatory = $true)]
    [string] $accountName
)

# This script requires system identity enabled for the automation account with automation reader access on this automation account - read runbook content.
Connect-AzAccount -Identity

$userToken = (Get-AzAccessToken).Token
$Headers = @{
    "Authorization" = "Bearer $userToken"
}

$requestUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Automation/automationAccounts/$accountName/runbooks?api-version=2015-10-31"

# get the runbooks
while($true) {
    $response = Invoke-RestMethod -Method "GET" -Uri "$($requestUrl)" -ContentType "application/json" -Headers $Headers

    $runbooks = $response.value

    foreach ($runbook in $runbooks) {
        
        $runbookName = $runbook.name
        if ($runbook.properties.runbookType -eq "PowerShell" -or $runbook.properties.runbookType -eq "PowerShell7") {

            $runbookContentUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Automation/automationAccounts/$accountName/runbooks/$runbookName/content?api-version=2015-10-31"
            $runbookContent = Invoke-RestMethod -Method "GET" -Uri "$($runbookContentUri)" -ContentType "text/powershell" -Headers $Headers
            
            if ($runbookContent -and $runbookContent.Contains("AzureRunAsConnection")) {
                Write-Output $runbookName
            }
        }
    }
    
    if ($response.nextLink) {
        $requestUrl = $response.nextLink
    }
    else {
        break
    }
}
