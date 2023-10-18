<#
.SYNOPSIS
    This script is used to check which automation accounts have classic run as account configured and renew the classic run as certificate

.DESCRIPTION
    This script will assess automation account which has configured classic RunAs accounts and renews the certificate if the user chooses to do so. On confirmation 
    it will renew the Management certificate on subscription,

    Prerequisites: 
    1. .NET framework 4.7.2 or later installed.
    2. Windows PowerShell version 5.1(64-bit) or later installed and run with Administrator permissions.
    3. Azure Az PowerShell module latest version installed, having minimum version Az.Accounts (2.5.4)`, `Az.Resources (4.4.0)` & `Az.Automation (1.7.1)` cmdlets
    4. You need the following permissions on the Azure user account:
        a. Owner permissions on Subscription

    Example to run :
        Ex: .\ClassicRunAsAccountAssessAndRenew.ps1 -SubscriptionId subId

.PARAMETER SubscriptionId
    [Optional] SubId for which you want to assess automation accounts.

.PARAMETER Env
    [Optional] Cloud environment name. 'AzureCloud' by default.

.PARAMETER Verbose
    [Optional] Enable verbose logging

.EXAMPLE
    PS> .\ClassicRunAsAccountAssessAndRenew.ps1 -SubscriptionId subId

.AUTHOR Microsoft

.VERSION 1.0
#>

#Requires -Modules @{ ModuleName="Az.Accounts"; ModuleVersion="2.5.4" },@{ ModuleName="Az.Resources"; ModuleVersion="4.4.0" },@{ ModuleName="Az.Automation"; ModuleVersion="1.7.1" }
#Requires -PSEdition Desktop
#Requires -RunAsAdministrator

[CmdletBinding()]
Param(
    [string[]]
    $SubscriptionId,

    # Cut off days for expiry upto which classic runascertificate can be renewed
    [int]
    $ExpiryCutOffDays = 30,

    [ValidateSet("AzureCloud", "AzureUSGovernment", "AzureChinaCloud")]
    [Parameter(Mandatory = $false, HelpMessage = "Cloud environment name. 'AzureCloud' by default")]
    [string]
    $Env = "AzureCloud"
)

function Show-Description {
    Write-Warning "" 
    Write-Warning "Please note that the script will work for Automation managed Classic RunAs Management certificate, and if you are using Third-party/CA-signed certificates, please follow manual renewal steps."
    Write-Warning ""

    Write-Warning "Prerequisites:"
    Write-Warning "1. .NET framework 4.7.2 or later installed."
    Write-Warning "2. Windows PowerShell version 5.1(64-bit) or later installed and run with Administrator permissions."
    Write-Warning "3. Azure Az PowerShell module latest version installed, having minimum version Az.Accounts (2.5.4)`, `Az.Resources (4.4.0)` & `Az.Automation (1.7.1)` cmdlets"
    Write-Warning "4. You need the following permissions on the Azure user account:"
    Write-Warning "    Owner permissions on the subscription"
}

Function Get-MSCoreARMEndpoint
{
    param(
        [string]
        $Env
    )

    switch ($Env)
    {
        "AzureCloud" { return "https://management.core.windows.net/" }
        "AzureChinaCloud" { return "https://management.core.chinacloudapi.cn/" }
        "AzureUSGovernment" { return "https://management.core.usgovcloudapi.net/" }
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
        subscriptions = $SubscriptionId
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
    
    $runAsCert = Get-AzAutomationCertificate -ResourceGroupName $account.ResourceGroup -AutomationAccountName $account.Name -Name "AzureClassicRunAsCertificate" -ErrorAction SilentlyContinue
    $reqdiff = New-TimeSpan -Days $ExpiryCutOffDays
    if ($null -ne $runAsCert) {
        Write-Verbose "Account $($a.ResourceId) is using Classic RunAsAccount"
        $timediff = ($runAsCert.ExpiryTime - (Get-Date)) -lt $reqdiff
        if ($timediff)
        {
            Write-Verbose "Account $($a.ResourceId) is using Classic RunAsAccount and approaching expiry or already expired."
            $account.IsExpireCert = $true
            $RunAsAutomationAccounts.Add($account) > $null
        }
    }
    else {
        Write-Verbose "Account $($a.ResourceId) is not using RunAsAccount"
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

# Make MS Cert request with retry and exponential backoff
Function Make-CertificateManagementRequest
{
    param(
        [string]
        $Url,

        [string]
        $Content
    )

    $headers = @{
        "Authorization" = "Bearer $($MsCoreToken)"
        "x-ms-aad-authorization" = "Bearer $($MsCoreToken)"
        "x-ms-version" = "2014-11-01"
        "Content-Type" = "application/xml; charset=utf-8"
    }

    $result = Invoke-RestMethod -Uri $Url -Headers $headers -Body $Content -Method "POST" -Verbose:$false
    return $result
}

function Renew-RunAsAccounts {
    param (
        $accounts
    )

    if ($accounts.Count -eq 0) {
        Write-Output ""
        Write-Output "No ClassicRunAs accounts to renew."
        return
    }

    Write-Output ""
    Write-Output "======================"
    Write-Output "Starting renewal..."
    Write-Output "======================"
    $count = 0
    
    foreach ($a in $accounts)
    {
        if ($a.IsExpireCert) {
            $renew = Read-Host "ClassicRunAs certificate for account $($a.ResourceId) has expired. Want to Create New ClassicRunAs Certificate (Y/N): "    
        }
        else {
            $renew = Read-Host "Renew ClassicRunAs certificate for account $($a.ResourceId) (Y/N): "
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

function Check-WriteAccessOnAutomationAccount {
    param ([AutomationAccount]$account)

    $resourceGroup = $account.ResourceGroup
    $accountName = $account.Name

    # Checking user write access on automation account.
    $VariableName = "Renew_Classic"+ $(Get-Random)
    $var = Get-AzAutomationVariable -ResourceGroupName $resourceGroup -AutomationAccountName $accountName -Name $VariableName -ErrorAction SilentlyContinue > $null
    while( $null -ne $var)
    {
        $VariableName = "Renew_Classic"+ $(Get-Random)
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

function Renew-Account {
    param ([AutomationAccount]$account)

    Write-Output ""
    Write-Output "Started Rotating certificate for $($account.ResourceId)"
    Select-AzSubscription -SubscriptionId $account.SubscriptionId > $null

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
    $certName = "$($accountName)_$($resourceGroup)_$($subId)_AzureClassic"
    $cert = New-SelfSignedCertificate -KeyUsageProperty All -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider" -FriendlyName $certName -Subject "DC=$certName" -HashAlgorithm SHA256 -KeyLength 2048 -KeyExportPolicy ExportableEncrypted
    $certString = [convert]::tobase64string($cert.RawData)

    Add-Type -AssemblyName System.Web
    $securePassword = ConvertTo-SecureString $([System.Web.Security.Membership]::GeneratePassword(25, 10)) -AsPlainText -Force
    Export-PfxCertificate -FilePath "$pwd\$certName.pfx" -Cert $cert -Password $securePassword -NoProperties > $null

    try {
        Write-Verbose "Adding the new certificate on the certificate management"

        $publicKeyString = Convert-HexToBase64 -hexString $cert.GetPublicKeyString()
        $thumbprint = $cert.Thumbprint

        $xmlDocument = New-Object System.Xml.XmlDocument
        $root = $xmlDocument.CreateElement("SubscriptionCertificate")
        $root.SetAttribute("xmlns", "http://schemas.microsoft.com/windowsazure")
        $root.SetAttribute("xmlns:i", "http://www.w3.org/2001/XMLSchema-instance")

        $publicKeyElement = $xmlDocument.CreateElement("SubscriptionCertificatePublicKey")
        $thumbprintElement = $xmlDocument.CreateElement("SubscriptionCertificateThumbprint")
        $dataElement = $xmlDocument.CreateElement("SubscriptionCertificateData")

        $publicKeyElement.InnerText = $publicKeyString
        $thumbprintElement.InnerText = $thumbprint
        $dataElement.InnerText = $certString

        $root.AppendChild($publicKeyElement)
        $root.AppendChild($thumbprintElement)
        $root.AppendChild($dataElement)

        $xmlDocument.AppendChild($root)

        $url = "$MsCoreEndpoint$subId/certificates"
        Make-CertificateManagementRequest -Url $url -Content $xmlDocument.OuterXml
    }
    catch {
        Write-Error -Message "Unable to renew, error while accessing the subscription certificate management. Error Message: $($Error[0].Exception.Message)"
        return        
    }

    Write-Verbose "Creating the ClassicRunAs certificate asset"
    Remove-AzAutomationCertificate -AutomationAccountName $accountName -ResourceGroupName $resourceGroup -Name "AzureClassicRunAsCertificate" -ErrorAction SilentlyContinue > $null
    New-AzAutomationCertificate -AutomationAccountName $accountName -ResourceGroupName $resourceGroup -Name "AzureClassicRunAsCertificate" -Exportable -Path "$pwd\$certName.pfx" -Password $securePassword > $null
    if (!$?) {
        Write-Error "Unable to renew $($account.ResourceId) - Reason: Failed to update automation account with new classic runas certificate, may be due to Network or Permission issue."
        Write-Error "Please check prerequisites and rerun the script or renew manually."
        return
    }

    Write-Output "Successfully renewed account $($account.ResourceId) . "
    Write-Output ""
}

function Convert-HexToBase64 {
    param (
        [string]$hexString
    )

    $bytes = [byte[]]::new($hexString.Length / 2)
    for ($i = 0; $i -lt $hexString.Length; $i += 2) {
        $bytes[$i / 2] = [System.Convert]::ToByte($hexString.Substring($i, 2), 16)
    }

    $base64String = [System.Convert]::ToBase64String($bytes)
    return $base64String
}

# Start point for the script
Show-Description

Connect-AzAccount -Environment $Env -ErrorAction Stop > $null
$MsCoreEndpoint = Get-MSCoreARMEndpoint $Env
$MsCoreToken = (Get-AzAccessToken -ResourceUrl $MsCoreEndpoint).Token

Write-Output "Start Assessment for given Subscriptions."
# Assess all the given subscriptions and renew all the App Id's certs belonging to Azure automation
Assess-Accounts

Renew-RunAsAccounts $RunAsAutomationAccounts
