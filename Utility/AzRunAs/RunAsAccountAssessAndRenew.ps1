<#
.SYNOPSIS
    This script is used to check which automation accounts have run as account configured and renew the run as certificate

.DESCRIPTION
    This script will assess automation account which has configured RunAs accounts and renews the certificate if the user chooses to do so. On confirmation 
    it will renew the key credentials of Azure-AD App and 
    uploading new self-signed certificate to the Azure-AD App.

    Prerequisites: 
    1. .NET framework 4.7.2 or later installed.
    2. Windows PowerShell version 5.1(64-bit) or later installed and run with Administrator permissions.
    3. Azure Az PowerShell module latest version installed, having minimum version Az.Accounts (2.5.4)`, `Az.Resources (4.4.0)` & `Az.Automation (1.7.1)` cmdlets
    4. You need the following permissions on the Azure user account:
        a. ‘Contributor’ access on the Azure subscription that has the Azure Automation account, and
        b. Owner permissions on the associated Run-As-Account Azure AD Application.

    Examples to run :
        1) To assess and renew automation runas accounts in all subscriptions - Ex: .\RunAsAccountAssessAndRenew.ps1 
        2) To assess and renew automation runas accounts in set of subscriptions - Ex: .\RunAsAccountAssessAndRenew.ps1 - SubscriptionIds subId1,subId2

.PARAMETER SubscriptionIds
    [Optional] Assess and renew all the Automation run as accounts from the input subscriptions.

.PARAMETER Env
    [Optional] Cloud environment name. 'AzureCloud' by default.

.PARAMETER Verbose
    [Optional] Enable verbose logging

.EXAMPLE
    PS> .\AutomationAssessAndRenew.ps1 -SubscriptionIds subId1,subId2

.AUTHOR Microsoft

.VERSION 1.0
#>

#Requires -Modules @{ ModuleName="Az.Accounts"; ModuleVersion="2.5.4" },@{ ModuleName="Az.Resources"; ModuleVersion="4.4.0" },@{ ModuleName="Az.Automation"; ModuleVersion="1.7.1" }
#Requires -PSEdition Desktop
#Requires -RunAsAdministrator

[CmdletBinding()]
Param(
    [string[]]
    $SubscriptionIds,

    # Max number of retries for List Applications or List ServicePrincipals MS Graph request
    [int]
    $MaxRetryLimitForGraphApiCalls = 5,

    # Cut off days for expiry upto which runascertificate can be renewed
    [int]
    $ExpiryCutOffDays = 30,

    [ValidateSet("AzureCloud", "AzureUSGovernment", "AzureChinaCloud")]
    [Parameter(Mandatory = $false, HelpMessage = "Cloud environment name. 'AzureCloud' by default")]
    [string]
    $Env = "AzureCloud"
)

function Show-Description {
    Write-Warning ""
    Write-Warning "The script can be used to run at a time on set of subscriptions." 
    Write-Warning "Please note that the script will work for Automation managed RunAs AAD Apps, and if you are using Third-party/CA-signed certificates, please follow manual renewal steps mentioned in Notes #check"
    Write-Warning ""

    Write-Warning "Prerequisites:"
    Write-Warning "1. .NET framework 4.7.2 or later installed."
    Write-Warning "2. Windows PowerShell version 5.1(64-bit) or later installed and run with Administrator permissions."
    Write-Warning "3. Azure Az PowerShell module latest version installed, having minimum version Az.Accounts (2.5.4)`, `Az.Resources (4.4.0)` & `Az.Automation (1.7.1)` cmdlets"
    Write-Warning "4. You need the following permissions on the Azure user account:"
    Write-Warning "    a. ‘Contributor’ access on the Azure subscription that has the Azure Automation account, and"
    Write-Warning "    b. Owner permissions on the associated Run-As-Account Azure AD Application."

    Write-Warning "Example to run :"
    Write-Warning "    To assess and renew run as accounts in set of subscriptions - Ex: .\AutomationAssessAndRenew.ps1 - SubscriptionIds subId1,subId2"
}

Function Get-MSGraphEndpoint
{
    param(
        [string]
        $Env
    )

    switch ($Env)
    {
        "AzureCloud" { return "https://graph.microsoft.com" }
        "AzureChinaCloud" { return "https://microsoftgraph.chinacloudapi.cn" }
        "AzureUSGovernment" { return "https://graph.microsoft.us" }
        default { throw "$($Env) is not a valid cloud environment." }
    }
}

class AutomationAccount {
    [string] $Name
    [string] $ResourceId
    [string] $Region
    [string] $ResourceGroup
    [string] $SubscriptionId
    [string] $RunAsAppId
    [DateTimeOffset] $RunAsConnectionCreationTime
    [bool] $UsesThirdParytCert
    [string] $Thumbprint
    [bool] $IsExpireCert
}

$RunAsAutomationAccounts = New-Object System.Collections.ArrayList

function Assess-Accounts {
    Write-Output ""
    Write-Output "================================================="
    Write-Output "Started Assessing Automation accounts..."
    Write-Output "================================================="

    # Get all automation accounts accessible to current user
    $queryPayload = @{
        query = 'resources | where type == "microsoft.automation/automationaccounts"'
        subscriptions = $SubscriptionIds
        options = @{
        '$top' = 10000
        '$skip' = 0
        '$skipToken' = ""
        'resultFormat' = "table"
        }
    }
    $payload = $queryPayload | ConvertTo-Json

    $resp = Invoke-AzRestMethod -Path "/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01" -Method POST -Payload $payload
    $resp = $resp.Content | ConvertFrom-Json

    $allAccounts = New-Object System.Collections.ArrayList
    $defaultDate = (Get-Date 01-01-1970)
    foreach ($row in $resp.data.rows)
    {
        $a = [AutomationAccount]@{
            ResourceId = $row[0]
            Name = $row[1]
            Region = $row[5]
            ResourceGroup = $row[6]
            SubscriptionId = $row[7]
            RunAsAppId = ""
            RunAsConnectionCreationTime = $defaultDate
            UsesThirdParytCert = $false
            Thumbprint= ""
            IsExpireCert = $false
        }
        Write-Debug "$($a.Name), $($a.Region), $($a.ResourceGroup), $($a.SubscriptionId)"

        $allAccounts.Add($a) > $null
    }

    Assess-AccountsBySubscriptionGroup $allAccounts
    Write-Output ""
    Write-Output "==================================================="
    Write-Output "Completed Assessing Automation accounts..."
    Write-Output "==================================================="  
    Write-Output ""  
}

function Assess-AccountsBySubscriptionGroup {
    param ($accounts)

    # Group by subscription ID
    $accountsGroup = $accounts | Group-Object { $_.SubscriptionId }

    foreach ($item in $accountsGroup) {
        Write-Output ""
        Write-Output "Procesing accounts in subscription $($item.Name): $($item.Group.Count)"
        Select-AzSubscription -SubscriptionId $item.Name > $null

        foreach ($a in $item.Group) {
            Assess-Account $a
        }
    }
}

function Assess-Account {
    param ([AutomationAccount] $account)

    Write-Verbose "Assessing account $($account.ResourceId)"
    # Get the RunAs connection
    $conn = Get-AzAutomationConnection -AutomationAccountName $account.Name -ResourceGroupName $account.ResourceGroup -Name "AzureRunAsConnection" -ErrorAction SilentlyContinue
    
    $runAsCert = Get-AzAutomationCertificate -ResourceGroupName $account.ResourceGroup -AutomationAccountName $account.Name -Name "AzureRunAsCertificate" -ErrorAction SilentlyContinue

    if ($null -ne $conn -and $conn.ConnectionTypeName -eq "AzureServicePrincipal" -and $null -ne $runAsCert) {
        $account.RunAsAppId = $conn.FieldDefinitionValues.ApplicationId
        $account.RunAsConnectionCreationTime = $conn.CreationTime
        $account.Thumbprint= $runAsCert.Thumbprint

        Assess-CertificatesOnApp $account
    }
    else {
        Write-Verbose "Account $($a.ResourceId) is not using RunAsAccount"
    }
}

function Assess-CertificatesOnApp {
    param ([AutomationAccount] $account)

    $url = "$($MsGraphEndpoint)/v1.0/applications?`$filter=appId eq '$($account.RunAsAppId)'&`$select=id,appId,keyCredentials"

    $resp = Make-MSGraphRequest -Url $url -MaxRetryLimit $MaxRetryLimitForGraphApiCalls
   
    # check for associated certicates in AAD for RunAsApp
    if ($null -ne $resp -and $null -ne $resp.value.keyCredentials) {
        foreach ($keyCred in $resp.value.keyCredentials) {
            if (($keyCred.Key.Length -gt 0) -and ($keyCred.type -eq 'AsymmetricX509Cert') -and (($keyCred.usage -eq 'Verify') -or ($keyCred.usage -eq 'Encrypt'))) {
                
                $reqdiff = New-TimeSpan -Days $ExpiryCutOffDays
                $timediff = ((Get-Date $keyCred.endDateTime) - (Get-Date)) -lt $reqdiff

                # check cert is not expired and expiration days is within ExpiryCutoffDays
                if ($keyCred.customKeyIdentifier -eq $account.Thumbprint -and (Get-Date $keyCred.endDateTime) -gt (Get-Date) -and $timediff) {
                    Assess-Certificate $account $keyCred
                }
            }
        }
    }
    # if no certificates are found in AAD App (expired cert), can assign new certificate for RunAsAcc
    elseif ($null -ne $resp -and $resp.value.keyCredentials.length -eq 0) {
        $account.IsExpireCert = $true
        $RunAsAutomationAccounts.Add($account) > $null
    }
    else {
        Write-Error "Unable to Assess Account $($account.ResourceId) - Reason: Failed to retrieve metadata from Azure Graph API"
    }
}

# Remove unnecessary new line characters and whitespace in url
Function Trim-Url
{
    param(
        [string]
        $Url
    )

    return $Url -replace '`n','' -replace '\s+', ''
}

# Make MS Graph request with retry and exponential backoff
Function Make-MSGraphRequest
{
    param(
        [string]
        $Url,

        [int]
        $MaxRetryLimit,

        [int]
        $flatMinSeconds = 10,

        [bool]
        $AddConsistencyLevel
    )

    $headers = @{
        "Authorization" = "Bearer $($MsGraphToken)"
    }

    if ($AddConsistencyLevel) {
        $headers["ConsistencyLevel"] = "eventual"
    }

    for ($i=1; $i -le $MaxRetryLimit; $i+=1)
    {
        try
        {
            Write-Verbose "GET $($Url)"
            $result = Invoke-RestMethod -Uri $Url -Headers $headers -Method "GET" -Verbose:$false
            break
        }
        catch
        {
            if ($_.Exception.Response.StatusCode.value__ -eq 429)
            {
                # Sleep then retry (Exponential backoff)
                $sleepDuration = [Math]::Pow(2,$i) + $flatMinSeconds
                Write-Verbose "Retry after sleeping for $($sleepDuration) seconds"
                Start-Sleep -s $sleepDuration
                continue
            }

            if ($_.Exception.Response.StatusCode.value__ -eq 404)
            {
                Write-Warning "AAD Object not found. Query - '$($Url)'"
                break
            }

            if ($_.Exception.Response.StatusCode.value__ -eq 401)
            {
                Write-Warning "UnAuthorized Access Error - '$($Url)'"
                break
            }

            if ($_.Exception.Response.StatusCode.value__ -eq 403)
            {
                Write-Warning "Forbidden Error- '$($Url)'"
                break
            }
        }
    }

    if ($i -gt $MaxRetryLimit)
    {
        $Url = Trim-Url -Url $Url
        Write-Warning "Unexpected error while connecting to the Azure Graph API. URL - '$($Url)'"
    }

    return $result
}


function Assess-Certificate {
    param (
        [AutomationAccount] $account,
        $keyCred
    )

    $automationCertIssuerName = "DC=$($account.Name)_$($account.ResourceGroup)_$($account.SubscriptionId)"

    try {
        $certBytes = [Convert]::FromBase64String($keyCred.key)
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
    }
    catch {
        Write-Error "Unable to assess $($account.ResourceId) - Reason: Issue processing certificate."
    }

    $RunAsAutomationAccounts.Add($account) > $null

    if ($null -ne $cert) {
        if ($cert.Issuer -eq $automationCertIssuerName) {
            Write-Verbose "Account $($account.ResourceId) uses a self-signed cert with thumbprint: $($cert.Thumbprint)."
        }
        else {
            $account.UsesThirdParytCert = $true
            Write-Verbose "Account $($account.ResourceId) uses a third-party certificate with issuer: $($cert.Issuer)."
        }
        Write-Debug "issuer: $($cert.Issuer), subject: $($cert.Subject), expiry: $($cert.NotAfter)"
    }
}

function Renew-RunAsAccounts {
    param (
        $accounts
    )

    if ($accounts.Count -eq 0) {
        Write-Output ""
        Write-Output "No RunAs accounts to renew."
        return
    }

    Write-Output ""
    Write-Output "======================"
    Write-Output "Starting renewal..."
    Write-Output "======================"
    $count = 0
    foreach ($a in $accounts)
    {
        if ($a.UsesThirdParytCert) {
            Write-Output "$($a.ResourceId) uses a third-party certificate."
            $thirdPartyRenew = Read-Host "Do you want to renew this account with a self-signed certificate? (Y/N): "

            if ($thirdPartyRenew -ne "Y" -and $thirdPartyRenew -ne 'y') {
                continue
            }
        }

        Write-Output ""
        if ($a.IsExpireCert) {
            $renew = Read-Host "RunAs certificate for account $($a.ResourceId) has expired. Want to Create New RunAs Certificate (Y/N): "    
        }
        else {
            $renew = Read-Host "Renew RunAs certificate for account $($a.ResourceId) (Y/N): "
        }

        if ($renew -eq "Y" -or $renew -eq 'y') {
            Renew-Account $a
            ++$count
        }
    }

    Write-Output ""
    Write-Output "======================"
    Write-Output "Completed renewal. Total accounts renewed -$($count)"
    Write-Output "======================"    
}

function Renew-Account {
    param ([AutomationAccount]$account)

    Write-Output ""
    Write-Output "Started Rotating certificate for $($account.ResourceId)"
    Select-AzSubscription -SubscriptionId $account.SubscriptionId > $null

    $appId = $account.RunAsAppId
    $subId = $account.SubscriptionId
    $resourceGroup = $account.ResourceGroup
    $accountName = $account.Name

    # To renew AAD App certificate, user should have Automation Contributor role access and Application Administrator permission on AAD App
    # Checking user write access on automation account.
    $writePermission = Check-WriteAccessOnAutomationAccount $account
    if(!$writePermission ) {
        Write-Error "Unable to renew $($account.ResourceId) - Reason: User does not have write permission on the Automation account. Please check prerequisites."
        return
    }

    Write-Verbose "User has write permission on Automation account $($account.ResourceId)"

    Write-Debug "Creating new certificate"
    $certName = "$($accountName)_$($resourceGroup)_$($subId)"
    $cert = New-SelfSignedCertificate -KeyUsageProperty All -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider" -FriendlyName $certName -Subject "DC=$certName" -HashAlgorithm SHA256 -KeyLength 2048 -KeyExportPolicy ExportableEncrypted
    $certString = [convert]::tobase64string($cert.RawData)

    Add-Type -AssemblyName System.Web
    $securePassword = ConvertTo-SecureString $([System.Web.Security.Membership]::GeneratePassword(25, 10)) -AsPlainText -Force
    Export-PfxCertificate -FilePath "$pwd\$certName.pfx" -Cert $cert -Password $securePassword -NoProperties > $null    

    try {
        Write-Verbose "Adding the new certificate on the AAD application"
        New-AzADAppCredential -ApplicationId $appId -CertValue $certString -StartDate $cert.NotBefore -EndDate $cert.NotAfter > $null
        if (!$?) {
            Write-Error "Unable to renew $($account.ResourceId) - Reason: Failed to add new certificate to the AAD application. Please check prerequisites."
            return
        }        
    }
    catch {
        Write-Error -Message "Unable to renew, error while accessing the App. Error Message: $($Error[0].Exception.Message)"
        return        
    }

    Write-Verbose "Creating the RunAs certificate asset"
    Remove-AzAutomationCertificate -AutomationAccountName $accountName -ResourceGroupName $resourceGroup -Name "AzureRunAsCertificate" -ErrorAction SilentlyContinue > $null
    New-AzAutomationCertificate -AutomationAccountName $accountName -ResourceGroupName $resourceGroup -Name "AzureRunAsCertificate" -Exportable -Path "$pwd\$certName.pfx" -Password $securePassword > $null
    if (!$?) {
        Write-Error "Unable to renew $($account.ResourceId) - Reason: Failed to update automation account with new runas certificate, may be due to Network or Permission issue."
        Write-Error "Please check prerequisites and rerun the script or renew manually."
        return
    }

    Write-Verbose "Update the RunAs connection"
    Set-AzAutomationConnectionFieldValue -AutomationAccountName $accountName -ResourceGroupName $resourceGroup -Name "AzureRunAsConnection" -ConnectionFieldName CertificateThumbprint -Value $cert.Thumbprint > $null
    if (!$?) {
        Write-Error "Unable to renew $($account.ResourceId) - Reason: Failed to update automation account with new runas certificate, may be due to Network or Permission issue."
        Write-Error "Please check prerequisites and rerun the script or renew manually."
        return
    }

    Write-Output "Successfully renewed account $($account.ResourceId) . "
    Write-Output ""
}

function Check-WriteAccessOnAutomationAccount {
    param ([AutomationAccount]$account)

    $resourceGroup = $account.ResourceGroup
    $accountName = $account.Name

    #To renew AAD App cert,user should have Automation Contributor role access and admin permission on AAD App
    # Checking user write access on automation account.
    $VariableName = "Renew_AAD"+ $(Get-Random)
    $var = Get-AzAutomationVariable -ResourceGroupName $resourceGroup -AutomationAccountName $accountName -Name $VariableName -ErrorAction SilentlyContinue > $null
    while( $null -ne $var)
    {
        $VariableName = "Renew_AAD"+ $(Get-Random)
        $var = Get-AzAutomationVariable -ResourceGroupName $resourceGroup -AutomationAccountName $accountName -Name $VariableName -ErrorAction SilentlyContinue > $null
    }

    if( $null -eq $var) {
        $var = New-AzAutomationVariable -ResourceGroupName $resourceGroup -AutomationAccountName $accountName -Name $VariableName -Value $VariableName -Encrypted $false
        if( $null -ne $var) {
            Remove-AzAutomationVariable -ResourceGroupName $resourceGroup -AutomationAccountName $accountName -Name $VariableName
            return $true;
        }
    }

    return $false
}

function ParseResourceId {
    param (
       [string]$resourceID
   )
   $array = $resourceID.Split('/')
   $indexSubscriptionId = 0..($array.Length -1) | where {$array[$_] -ieq 'subscriptions'}
   $indexResourceGroup = 0..($array.Length -1) | where {$array[$_] -ieq 'resourcegroups'}
   $result = $array.get($indexSubscriptionId+1), $array.get($indexResourceGroup+1), $array.get($array.Length -1)
   return $result
}


# Start point for the script
Show-Description

Connect-AzAccount -Environment $Env -ErrorAction Stop > $null
$MsGraphEndpoint = Get-MSGraphEndpoint $Env
$MsGraphToken = (Get-AzAccessToken -ResourceUrl $MsGraphEndpoint).Token

    Write-Output "Start Assessment for given Subscriptions."
    # Assess all the given subscriptions and renew all the App Id's certs belonging to Azure automation
    Assess-Accounts

    Renew-RunAsAccounts $RunAsAutomationAccounts



