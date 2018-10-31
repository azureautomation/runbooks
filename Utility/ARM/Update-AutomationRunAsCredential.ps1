 <#
.SYNOPSIS 
    This sample automation runbook checks if the RunAs service principal certificate authentication is about to expire, and 
    automatically updates it with a new certificate.

.DESCRIPTION
    This sample automation runbook checks if the RunAs service principal certificate authentication is about to expire, and 
    automatically updates it with a new certificate. You need to perform the following tasks before you can put this on a schedule
    within the Azure Automation account.

    1. Add the RunAs service principal as an owner of the application created during Automation Account creation. You can get the application
    id from the RunAs page in the Automation account and run the following commands locally after installly the AzureAD module from the PowerShellGallery.

    Connect-AzureAD
    $Application = Get-AzureADApplication -Filter "AppId eq '123456789'"
    $ServicePrincipal = Get-AzureADServicePrincipal -Filter "AppId eq '123456789'"
    Add-AzureADApplicationOwner -ObjectId $Application.ObjectId -RefObjectId $ServicePrincipal.ObjectId

    2. Grant permissions to the Application to be able to update itself. Go to Azure AD in the portal and search for the RunAs application
    in the App Registrations page (select all apps). 

    3. Select the application and click Settings button -> Required Permissions -> Add button
    Add the "Manage apps that this app creates or owns" permission from Windows Azure Active Directory.

    4. Select Grant permissions (You may need to be an administrator in Azure AD to be able to perform this task).

    Once the below tasks are done, you can import this runbook into the Automation account, update the Azure modules from the modules page,
    and schedule this to run weekly.

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: October 30th 2018
#>

$ErrorActionPreference = 'stop'

$CertifcateAssetName = "AzureRunAsCertificate"
$ConnectionAssetName = "AzureRunAsConnection"
$ConnectionTypeName = "AzureServicePrincipal"

Function ImportAutomationModule
{   
param(

    [Parameter(Mandatory=$true)]
    [String] $ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [String] $AutomationAccountName,

    [Parameter(Mandatory=$true)]
    [String] $ModuleName,

    [Parameter(Mandatory=$false)]
    [String] $ModuleVersion

)

    $Url = "https://www.powershellgallery.com/api/v2/Search()?`$filter=IsLatestVersion&searchTerm=%27$ModuleName%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40"
    $SearchResult = Invoke-RestMethod -Method Get -Uri $Url -UseBasicParsing

    if($SearchResult.Length -and $SearchResult.Length -gt 1) {
        $SearchResult = $SearchResult | Where-Object -FilterScript {

            return $_.properties.title -eq $ModuleName

        }
    }

    $PackageDetails = Invoke-RestMethod -Method Get -UseBasicParsing -Uri $SearchResult.id 

    if(!$ModuleVersion) {

        $ModuleVersion = $PackageDetails.entry.properties.version
    }

    $ModuleContentUrl = "https://www.powershellgallery.com/api/v2/package/$ModuleName/$ModuleVersion"

    do {

        $ActualUrl = $ModuleContentUrl
        $ModuleContentUrl = (Invoke-WebRequest -Uri $ModuleContentUrl -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore).Headers.Location 

    } while(!$ModuleContentUrl.Contains(".nupkg"))

    $ActualUrl = $ModuleContentUrl

    $AutomationModule = New-AzureRmAutomationModule `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $ModuleName `
        -ContentLink $ActualUrl -AzureRmContext $Context

    while(

        (!([string]::IsNullOrEmpty($AutomationModule))) -and
        $AutomationModule.ProvisioningState -ne "Created" -and
        $AutomationModule.ProvisioningState -ne "Succeeded" -and
        $AutomationModule.ProvisioningState -ne "Failed"

    ){
        Write-Verbose -Message "Polling for module import completion"
        Start-Sleep -Seconds 10
        $AutomationModule = $AutomationModule | Get-AzureRmAutomationModule -AzureRmContext $Context
    }


    if($AutomationModule.ProvisioningState -eq "Failed") {

        Write-Error "     Importing $ModuleName module to Automation failed."

    } else {
        $ActualUrl
    }
}

# Get RunAs certificate and check for expiration date. If it is about to expire in less than a week, update it.
$RunAsCert = Get-AutomationCertificate -Name $CertifcateAssetName
if ($RunAsCert.NotAfter -gt (Get-Date).AddDays(8))
{
    Write-Output ("Certificate will expire at " + $RunAsCert.NotAfter)
    Exit(1)
}


# Authenticate with RunAs Account
$RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
Add-AzureRmAccount `
    -ServicePrincipal `
    -TenantId $RunAsConnection.TenantId `
    -ApplicationId $RunAsConnection.ApplicationId `
    -CertificateThumbprint $RunAsConnection.CertificateThumbprint | Write-Verbose
 
$Context = Set-AzureRmContext -SubscriptionId $RunAsConnection.SubscriptionID 

$AutomationResource = Get-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts -AzureRmContext $Context

foreach ($Automation in $AutomationResource)
{
    $Job = Get-AzureRmAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name `
                -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue -AzureRmContext $Context 
    if (!([string]::IsNullOrEmpty($Job)))
    {
        $AutomationResourceGroupName = $Job.ResourceGroupName
        $AutomationAccountName = $Job.AutomationAccountName
        break;
    }
}

# Import AzureAD module if it is not in the Automation account.
$ADModule = Get-AzureRMAutomationModule -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName `
                         -Name "AzureAD" -AzureRmContext $Context -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($ADModule))
{
    $AzureADGalleryURL = ImportAutomationModule -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName -ModuleName "AzureAD"

    # Donload locally and import the AzureAD module
    $LocalFolder = 'C:\AzureAD'
    New-Item -ItemType directory $LocalFolder -Force -ErrorAction SilentlyContinue | Write-Verbose
    (New-Object System.Net.WebClient).DownloadFile($AzureADGalleryURL, "$LocalFolder\AzureAD.zip")
    Unblock-File $LocalFolder\AzureAD.zip
    Expand-Archive -Path $LocalFolder\AzureAD.zip -DestinationPath $LocalFolder\AzureAD -force
    Import-Module $LocalFolder\AzureAD\AzureAD.psd1
}

# Create RunAs certificate
$SelfSignedCertNoOfMonthsUntilExpired = 12
$SelfSignedCertPlainPassword = (New-Guid).Guid
$CertificateName = $AutomationAccountName + $CertifcateAssetName
$PfxCertPathForRunAsAccount = Join-Path $env:TEMP ($CertificateName + ".pfx")
$CerCertPathForRunAsAccount = Join-Path $env:TEMP ($CertificateName + ".cer")

$Cert = New-SelfSignedCertificate -DnsName $CertificateName -CertStoreLocation Cert:\LocalMachine\My `
                    -KeyExportPolicy Exportable -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider" `
                    -NotBefore (Get-Date).AddDays(-1) -NotAfter (Get-Date).AddMonths($SelfSignedCertNoOfMonthsUntilExpired) -HashAlgorithm SHA256

$CertPassword = ConvertTo-SecureString $SelfSignedCertPlainPassword -AsPlainText -Force
Export-PfxCertificate -Cert ("Cert:\LocalMachine\My\" + $Cert.Thumbprint) -FilePath $PfxCertPathForRunAsAccount -Password $CertPassword -Force | Write-Verbose
Export-Certificate -Cert ("Cert:\LocalMachine\My\" + $Cert.Thumbprint) -FilePath $CerCertPathForRunAsAccount -Type CERT | Write-Verbose

# Connect to Azure AD to manage the application
Connect-AzureAD -CertificateThumbprint $RunAsConnection.CertificateThumbprint -TenantId $RunAsConnection.TenantId -ApplicationId $RunAsConnection.ApplicationId | Write-Verbose

# Find the application
$Filter = "AppId eq '" + $RunasConnection.ApplicationId + "'"
$Application = Get-AzureADApplication -Filter $Filter 

# Add new certificate to application
New-AzureADApplicationKeyCredential -ObjectId $Application.ObjectId -CustomKeyIdentifier ([System.Convert]::ToBase64String($cert.GetCertHash())) `
         -Type AsymmetricX509Cert -Usage Verify -Value ([System.Convert]::ToBase64String($cert.GetRawCertData())) -StartDate $cert.NotBefore -EndDate $cert.NotAfter | Write-Verbose

# Update the certificate with the new one in the Automation account
$CertPassword = ConvertTo-SecureString $SelfSignedCertPlainPassword -AsPlainText -Force   
Set-AzureRmAutomationCertificate -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName -Path $PfxCertPathForRunAsAccount -Name $CertifcateAssetName `
             -Password $CertPassword -Exportable:$true -AzureRmContext $Context | Write-Verbose


# Update the RunAs connection with the new certificate information
$ConnectionFieldValues = @{"ApplicationId" = $RunasConnection.ApplicationId ; "TenantId" = $RunAsConnection.TenantId; "CertificateThumbprint" = $Cert.Thumbprint; "SubscriptionId" = $RunAsConnection.SubscriptionId }

# Can't just update the thumbprint value due to bug https://github.com/Azure/azure-powershell/issues/5862 so deleting / creating connection 
Remove-AzureRmAutomationConnection -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName -Name $ConnectionAssetName -Force
New-AzureRMAutomationConnection -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName -Name $ConnectionAssetName `
              -ConnectionFieldValues $ConnectionFieldValues -ConnectionTypeName $ConnectionTypeName -AzureRmContext $Context | Write-Verbose

Write-Output ("RunAs certificate credentials have been updated")


