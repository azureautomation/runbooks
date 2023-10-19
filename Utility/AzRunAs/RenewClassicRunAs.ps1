<#
.SYNOPSIS
    This script is used to renew the classic run as certificate for automation account

.DESCRIPTION
    This script renews the certificate for classic run as account. This script needs to be run by user in their own environment (NOT IN AUTOMATION AS A JOB)

    Prerequisites: 
    1. .NET framework 4.7.2 or later installed.
    2. Windows PowerShell version 5.1(64-bit) or later installed and run with Administrator permissions.
    3. Azure Az PowerShell module latest version installed, having minimum version Az.Accounts (2.5.4)`, `Az.Resources (4.4.0)` & `Az.Automation (1.7.1)` cmdlets
    4. You need the following permissions on the Azure user account:
        a. Owner permissions on Subscription

    Example to run :
        Ex: .\ClassicRunAsAccountRenew.ps1 -SubscriptionId subId -ResourceGroup rgName -AccountName accName

.PARAMETER SubscriptionId
    [Optional] SubId of automation account

.PARAMETER ResourceGroup
    [Optional] Resource group of automation account

.PARAMETER AccountName
    [Optional] Account name of automation account

.PARAMETER Env
    [Optional] Cloud environment name. 'AzureCloud' by default.

.PARAMETER Verbose
    [Optional] Enable verbose logging

.EXAMPLE
    PS> .\ClassicRunAsAccountRenew.ps1 -SubscriptionId subId

.AUTHOR Microsoft

.VERSION 1.0
#>

#Requires -Modules @{ ModuleName="Az.Accounts"; ModuleVersion="2.5.4" },@{ ModuleName="Az.Resources"; ModuleVersion="4.4.0" },@{ ModuleName="Az.Automation"; ModuleVersion="1.7.1" }
#Requires -PSEdition Desktop
#Requires -RunAsAdministrator

[CmdletBinding()]
Param(
    [string]
    $SubscriptionId,

    [string]
    $ResourceGroup,

    [string]
    $AccountName,

    [ValidateSet("AzureCloud", "AzureUSGovernment", "AzureChinaCloud")]
    [Parameter(Mandatory = $false, HelpMessage = "Cloud environment name. 'AzureCloud' by default")]
    [string]
    $Env = "AzureCloud"
)
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

function Check-WriteAccessOnAutomationAccount {

    # Checking user write access on automation account.
    $VariableName = "Renew_Classic"+ $(Get-Random)
    $var = Get-AzAutomationVariable -ResourceGroupName $ResourceGroup -AutomationAccountName $AccountName -Name $VariableName -ErrorAction SilentlyContinue > $null
    while( $null -ne $var)
    {
        $VariableName = "Renew_Classic"+ $(Get-Random)
        $var = Get-AzAutomationVariable -ResourceGroupName $ResourceGroup -AutomationAccountName $AccountName -Name $VariableName -ErrorAction SilentlyContinue > $null
    }

    if( $null -eq $var) {
        $var = New-AzAutomationVariable -ResourceGroupName $ResourceGroup -AutomationAccountName $AccountName -Name $VariableName -Value $VariableName -Encrypted $false
        if( $null -ne $var) {
            Remove-AzAutomationVariable -ResourceGroupName $ResourceGroup -AutomationAccountName $AccountName -Name $VariableName
            return $true;
        }
    }

    return $false
}

function Renew-Account {

    Write-Output ""
    Select-AzSubscription -SubscriptionId $SubscriptionId > $null

    $subId = $SubscriptionId
    $resourceGroup = $ResourceGroup
    $accountName = $AccountName

    Write-Output "Assessing account"
    
    $runAsCert = Get-AzAutomationCertificate -ResourceGroupName $ResourceGroup -AutomationAccountName $AccountName -Name "AzureClassicRunAsCertificate" -ErrorAction SilentlyContinue
    if ($null -ne $runAsCert) {
        Write-Output "Account is using Classic RunAsAccount"
    }
    else {
        Write-Output "Account is not using Clasic RunAsAccount"
        return
    }

    # To renew AAD App certificate, user should have Automation Contributor role access and Application Administrator permission on AAD App
    # Checking user write access on automation account.
    $writePermission = Check-WriteAccessOnAutomationAccount
    if(!$writePermission ) {
        Write-Error "Unable to renew - Reason: User does not have write permission on the Automation account. Please check prerequisites."
        return
    }

    Write-Verbose "User has write permission on Automation account "

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
        Write-Error "Unable to renew - Reason: Failed to update automation account with new classic runas certificate, may be due to Network or Permission issue."
        Write-Error "Please check prerequisites and rerun the script or renew manually."
        return
    }

    Write-Output "Successfully renewed account . "
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

Connect-AzAccount -Environment $Env -Subscription $SubscriptionId -ErrorAction Stop > $null
$MsCoreEndpoint = Get-MSCoreARMEndpoint $Env
$MsCoreToken = (Get-AzAccessToken -ResourceUrl $MsCoreEndpoint).Token

Renew-Account
