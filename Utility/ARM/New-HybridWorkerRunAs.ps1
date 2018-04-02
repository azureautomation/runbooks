<#
.SYNOPSIS 
    This sample automation runbook creates a new certificate on the local machine and adds
    it to the existing RunAs service principal in the Automation account so it can be used on hybrid workers
    that require authentication to Azure. It is designed to be run on a Windows Server 2016 machine and
	then have the generated certificate installed manually on all hybrid workers in a hybrid worker group
	that need to authenticate with Azure using the RunAs account.

.DESCRIPTION
    This sample automation runbook creates a new certificate on the local machine and adds
    it to the existing RunAs service principal in the account so it can be used on hybrid workers
    that require authentication to Azure. It is designed to be run on a Windows Server 2016 machine and
	then have the generated certificate installed manually on all hybrid workers in a hybrid worker group
	that need to authenticate with Azure using the RunAs account.

    You need to run Add-AzureRMAccount and Connect-AzureAD (install module AzureAD from gallery) 
    before you run this script on the hybrid worker so that the new certificate can be added. A 
    new RunAsConnection will be created in the Automtaion account that will be used for authentication.

    You need to run the script as an administrator since it installs a new certificate in the local machine.

.PARAMETER AutomationResourceGroupName
    Required. Resource group the automation account is in.

.PARAMETER AutomationAccountName
    Required. Name of the Automation account

.PARAMETER Password
    Required. The password for the PFX certificate that will be created

.PARAMETER CertPath
    Required. The path on the local machine that the certificate will be saved to.
    You can use this certificate on all of the hybrid workers in a group by
    copying and installing to the local machine certificate store on that worker.

.PARAMETER CertExpirationLengthInMonths
    Optional. The length in months from today before the certificate expires.

.PARAMETER HybridWorkerGroupName
    Required. The name of the hybrid worker group that this machine.
    This will be used to create a new RunAs connection with this name for authentication.

.Example
    .\New-HybridWorkerRunAs -AutomationResourceGroupName contosogroup -AutomationAccountName contoso -Password "StrongPassword" -CertPath c:\temp -HybridWorkerGroupName "financegroup"

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: April 2nd 2018
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    $AutomationResourceGroupName,

    [Parameter(Mandatory=$true)]
    $AutomationAccountName,

    [Parameter(Mandatory=$true)]
    $Password,

    [Parameter(Mandatory=$true)]
    $CertPath,

    [Parameter(Mandatory=$false)]
    $CertExpirationLengthInMonths = 24,

    [Parameter(Mandatory=$true)]
    $HybridWorkerGroupName

)
$ErrorActionPreference = 'stop'

# Name of certificate to create
$CertificateName = "LocalRunAs" + $HybridWorkerGroupName

$CertPassword = ConvertTo-SecureString $Password -AsPlainText -Force

# Check if user is authenticated to Azure
if (!(Get-AzureRmContext).Account)
{
    Write-Output "You need to authenticate with Azure. Launching window..."
    Login-AzureRmAccount
}

# Get existing RunAs connection from the Automation account.
$RunAsConnection = Get-AzureRMAutomationConnection -ResourceGroupName $AutomationResourceGroupName `
                    -AutomationAccountName $AutomationAccountName -Name "AzureRunAsConnection"

# Check that AzureAD module is installed on the machine as it is needed to interact with the AzureAD service principal
try {
    Import-Module AzureAD -ErrorAction Stop
}
catch {
    throw "You need to install the AzureAD module from PowerShellGallery. You can use Install-Module AzureAD to install from the gallery."  
}

# Find the object id for the service principal.
try {
    $ObjectId = Get-AzureADServicePrincipal -Filter ("appId eq '" + $RunAsConnection.FieldDefinitionValues.ApplicationId + "'") 
}
catch {
    Write-Output "You need to authenticate with Azure Active Directory. Launching window..."
    Connect-AzureAD
    $ObjectId = Get-AzureADServicePrincipal -Filter ("appId eq '" + $RunAsConnection.FieldDefinitionValues.ApplicationId + "'")
}

# Create a new certificate that will expire in in $CertExpirationLengthInMonths months and store in local machine personal location.
$RunAsCert = New-SelfSignedCertificate -DnsName $CertificateName -CertStoreLocation cert:\LocalMachine\My `
                                        -KeyExportPolicy Exportable -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider" `
                                        -NotAfter (Get-Date).AddMonths($CertExpirationLengthInMonths) -HashAlgorithm SHA256

# Save certificate so it can be installed on other hybrid workers in the same group
$Cert = $RunAsCert.Export("pfx",$CertPassword)
if (!(Test-Path -Path $CertPath))
{
    New-Item -Path $CertPath -ItemType Directory | Write-Verbose
}
Set-Content -Value $Cert -Path (Join-Path $CertPath ($HybridWorkerGroupName + ".pfx")) -Force -Encoding Byte | Write-Verbose

Write-Output ("Removing certificate from this computer as it should be manually installed on all hybrid workers in a group `r`n")
Get-ChildItem Cert:\LocalMachine\My\$RunAsCert.thumbprint | Remove-Item

Write-Output ("Certificate is saved to " + (Join-Path $CertPath ($HybridWorkerGroupName + ".pfx")) + " for use on hybrid workers in the same group. You can install with `r`n")
Write-Output ("Import-PfxCertificate -FilePath <certpath> -CertStoreLocation Cert:\LocalMachine\My -Exportable -Password (ConvertTo-SecureString '<Password>' -AsPlainText -Force) `r`n")

# Add certificate to service principal.
Write-Output ("Adding certificate to service principal in AzureAD for RunAs account `r`n")
$keyValue = [System.Convert]::ToBase64String($RunAsCert.GetRawCertData())
New-AzureADServicePrincipalKeyCredential -ObjectId $ObjectId.ObjectId  -Value $keyValue -Usage Verify  -Type AsymmetricX509Cert | Write-Verbose

# Create a new RunAs connection for use in this hybrid worker group
# with the certificate thumbprint and keep the existing service principal values.
$FieldValues = @{}
$FieldValues = $RunAsConnection.FieldDefinitionValues
$FieldValues.CertificateThumbprint = $RunAsCert.Thumbprint

$NewRunAsconnection = Get-AzureRmAutomationConnection -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName `
                                -Name $HybridWorkerGroupName -ErrorAction SilentlyContinue
if ($NewRunAsconnection)
{
    Write-Output ("Updating existing connection: " + $HybridWorkerGroupName + " with new thumbprint `r`n")
    Set-AzureRmAutomationConnectionFieldValue -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName `
                                                -Name $HybridWorkerGroupName -ConnectionFieldName "CertificateThumbprint" -Value $RunAsCert.Thumbprint| Write-Verbose
}
else {
    Write-Output ("Creating new RunAs connection with name " + $HybridWorkerGroupName + " for use on hybrid workers that need Azure authentication `r`n" )
    New-AzureRmAutomationConnection -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName `
    -ConnectionTypeName $RunAsConnection.ConnectionTypeName -ConnectionFieldValues $FieldValues `
    -Name $HybridWorkerGroupName | Write-Verbose   
}

# Use the below sample for all runbook jobs on the hybrid worker group
$ConnectionAuthentication = @'
$ServicePrincipalConnection = Get-AutomationConnection -Name $HybridWorkerGroupName
Add-AzureRmAccount `
    -ServicePrincipal `
    -TenantId $ServicePrincipalConnection.TenantId `
    -ApplicationId $ServicePrincipalConnection.ApplicationId `
    -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint
'@

Write-Output ("Use the below sample for all runbook jobs on the hybrid worker group where this new certificate is installed.`r`n ")
Write-Output $ConnectionAuthentication
