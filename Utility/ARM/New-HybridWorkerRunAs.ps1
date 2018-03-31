<#
.SYNOPSIS 
    This sample automation runbook creates a new certificate on the local machine and adds
    it to the existing RunAs service principal in the Automation account so it can be used on hybrid workers
    that require authentication to Azure.

.DESCRIPTION
    This sample automation runbook creates a new certificate on the local machine and adds
    it to the existing RunAs service principal in the account so it can be used on hybrid workers
    that require authentication to Azure.

    You need to run Add-AzureRMAccount and Connect-AzureAD (install module AzureADPreview from gallery) 
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

.PARAMETER HybridWorkerGroupName
    Required. The name of the hybrid worker group that this machine.
    This will be used to create a new RunAs connection with this name for authentication.

.Example
    .\New-HybridWorkerRunAs -AutomationResourceGroupName contosogroup -AutomationAccountName contoso -Password "StrongPassword" -CertPath c:\temp\runasfinancegroup.pfx -HybridWorkerGroupName "financegroup"

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: March 30th 2018
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

    [Parameter(Mandatory=$true)]
    $HybridWorkerGroupName

)
$ErrorActionPreference = 'stop'

# Name of certificate to create
$CertificateName = "LocalRunAs" + $HybridWorkerGroupName

$CertPassword = ConvertTo-SecureString $Password -AsPlainText -Force

# Get existing RunAs connection from the Automation account.
$RunAsConnection = Get-AzureRMAutomationConnection -ResourceGroupName $AutomationResourceGroupName `
                    -AutomationAccountName $AutomationAccountName -Name "AzureRunAsConnection"

# Create a new certificate that will expire in 2 years and store in local machine personal location.
$RunAsCert = New-SelfSignedCertificate -DnsName $CertificateName -CertStoreLocation cert:\LocalMachine\My `
                                        -KeyExportPolicy Exportable -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider" `
                                        -NotAfter (Get-Date).AddMonths(24) -HashAlgorithm SHA256

# Save certificate so it can be installed on other hybrid workers in the same group
$Cert = $RunAsCert.Export("pfx",$CertPassword)
if (!(Test-Path -Path $CertPath))
{
    New-Item -Path (Split-Path $CertPath -Parent) -ItemType Directory | Write-Verbose
}
Set-Content -Value $Cert -Path $CertPath -Force -Encoding Byte | Write-Verbose

Write-Output ("Certificate is saved to " + $CertPath + " for use on other hybrid workers in the same group")

# Find the object id for the service principal and add the certificate to it
$ObjectId = Get-AzureADServicePrincipal -Filter ("appId eq '" + $RunAsConnection.FieldDefinitionValues.ApplicationId + "'")
$keyValue = [System.Convert]::ToBase64String($RunAsCert.GetRawCertData())
New-AzureADServicePrincipalKeyCredential -ObjectId $ObjectId.ObjectId  -Value $keyValue -Usage Verify  -Type AsymmetricX509Cert | Write-Verbose

# Create a new RunAs connection for use in this hybrid worker group
# with the certificate thumbprint and keep the existing service principal values.
$FieldValues = @{}
$FieldValues = $RunAsConnection.FieldDefinitionValues
$FieldValues.CertificateThumbprint = $RunAsCert.Thumbprint

New-AzureRmAutomationConnection -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName `
                                -ConnectionTypeName $RunAsConnection.ConnectionTypeName -ConnectionFieldValues $FieldValues `
                                -Name $HybridWorkerGroupName | Write-Verbose

<#
# Use the below sample for all runbook jobs on the hybrid worker group where this new certificate is installed.
$ServicePrincipalConnection = Get-AutomationConnection -Name $HybridWorkerGroupName
Add-AzureRmAccount `
    -ServicePrincipal `
    -TenantId $ServicePrincipalConnection.TenantId `
    -ApplicationId $ServicePrincipalConnection.ApplicationId `
    -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint
#>
