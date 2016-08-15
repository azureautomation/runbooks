
<#
.SYNOPSIS 
    Runbook to configure a new or existing Azure Scheduler job to call an Automation runbook job
    
.DESCRIPTION
    This runbook configures a new or existing Azure Scheduler job that calls an Automation runbook. 
    This enables more advanced scheduling capabilities within Azure Scheduler to be used to trigger runbooks
    that are not enabled in the current Automation scheduler functionality. 
    The scheduler job that is created is disabled so you can change the
    scheduler properties to meet your specific needs after it is created or updated.

.PARAMETER SchedulerJobCollection
    Name of job collection to create the scheduler job

.PARAMETER SchedulerJobName
    Name of scheduler job to create or update
    
.PARAMETER SchedulerLocation
    Name of the location that the Azure Scheduler job collection is located. 
	You can get a list of locations by running Get-AzureSchedulerLocation or looking 
	up in the portal where the job collection is created.
    
.PARAMETER AzureCertificateAssetName
    A certificate asset name containing the management certificate that has access to this Azure subscription.
    This certificate must be marked as exportable when adding to the Automation service.
    
.PARAMETER AzureCertificatePasswordAssetName
    An Automation variable asset name containing the password to the management certificate

.PARAMETER Runbook
    The name of the runbook you want to start on the Azure Scheduler schedule
    
.PARAMETER Parameters
    An optional hashtable of parameters to pass when starting this runbook on the schedule   
    
 .PARAMETER AzureADCredentialAssetName
    A credential asset name containing an Org Id username / password with access to the Azure subscription.
        
.PARAMETER AccountName
    Name of the Azure automation account containing the runbook to start
    
.PARAMETER SubscriptionName
    Optional name of the Azure subscription. If a subscription is not specified, the default subscription is used. 

.EXAMPLE

    $RunbookName = "Get-IsWorkHours"
    
	$RunbookParameters = @{"MyWeekDayEndHour"=18;"MyWeekDayStartHour"=6}

    Set-AzureScheduleWithRunbook `
        -AccountName finance `
        -AzureCertificatePasswordAssetName CertPassword `
        -AzureCertificateAssetName AzureCert `
        -AzureADCredentialAssetName AzureCred `
        -Runbook $RunbookName `
        -Parameters $RunbookParameters `
        -SchedulerJobCollectionName FinanceJobCollection `
        -SchedulerJobName FinanceDaily `
        -SchedulerLocation "South Central US" `
        -SubscriptionName "Visual Studio Ultimate with MSDN"
        
.NOTES
    AUTHOR: System Center Automation Team
    LASTEDIT: Jan 19, 2015 
#>
Workflow Set-AzureScheduleWithRunbook
{
    param
    (
        [parameter(Mandatory=$true)]
        [String] $SchedulerJobCollectionName,
 
        [parameter(Mandatory=$true)]
        [String] $SchedulerJobName,
        
        [parameter(Mandatory=$true)]
        [String] $SchedulerLocation,
        
        [parameter(Mandatory=$true)]
        [String] $AzureCertificateAssetName,
        
        [parameter(Mandatory=$true)]
        [String] $AzureCertificatePasswordAssetName,   
        
        [parameter(Mandatory=$true)]
        [String] $Runbook,
        
        [parameter(Mandatory=$false)]
        [Hashtable] $Parameters,         
        
        [parameter(Mandatory=$true)]
        [String] $AzureADCredentialAssetName,
        
        [parameter(Mandatory=$true)]
        [String] $AccountName,
        
        [parameter(Mandatory=$false)]
        [String] $SubscriptionName                         
        )

    # Set up ability to manage the Azure subscription
    $OrgIDCredential = Get-AutomationPSCredential -Name $AzureADCredentialAssetName
    if ($OrgIDCredential -eq $null)
    {
        throw "Could not retrieve '$AzureADCredentialAssetName' credential asset. Check that you created this first in the Automation service."
    }
    
    Add-AzureAccount -Credential $OrgIDCredential | Write-Verbose
    
    # Select the specific subscription if it was passed in, otherwise the default will be used  
    if ($SubscriptionName -ne $Null)
    {
        Select-AzureSubscription -SubscriptionName $SubscriptionName | Write-Verbose
    }

    # Get the management certificate from the asset store that will allow the Azure Scheduler service 
    # to call a runbook. This certificate must be marked as exportable so the .pfx can be sent to the scheduler job.
    $AzureCert = Get-AutomationCertificate -Name $AzureCertificateAssetName
    if ($AzureCert -eq $null)
    {
        throw "Could not retrieve '$AzureCertificateAssetName' certificate asset. Check that you created this first in the Automation service."
    }
       
    # Get the password used for this certificate so that the Scheduler cmdlet can set this on the new scheduler job
    $Password = Get-AutomationVariable -Name $AzureCertificatePasswordAssetName
    if ($Password -eq $null)
    {
        throw "Could not retrieve '$AzureCertificatePasswordAssetName' variable asset. Check that you created this first in the Automation service."
    }
    
    # location to store temporary certificate in the Automation service host
    $CertGuid = InlineScript { [guid]::NewGuid()}
    $CertPath = "C:\"  + $CertGuid + ".pfx"
   
    # Save the certificate to the Automation service host so it can be referenced by the scheduler cmdlet
    $Cert = $AzureCert.Export("pfx",$Password)
    Set-Content -Value $Cert -Path $CertPath -Force -Encoding Byte | Write-Verbose
    
    # Set up the required headers for calling into the Automation service
	$AzureHeaders = @{"x-ms-version"="2013-03-01";"Content-Type"="application/json"}
    
    # Get the SubscriptionID for this subscription. If there are multiple, take the first one
    $SubID = Get-AzureSubscription | Select SubscriptionID -first 1
    $ID = $SubID.SubscriptionID
    
    # Get the list of runbooks in Azure Automation
    $RunbookList = InlineScript
    {
        $AzureCertPassword = ConvertTo-SecureString -String $Using:Password -Force –AsPlainText
        $AzureCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 
        $AzureCert.Import($Using:CertPath,$AzureCertPassword,"Exportable,PersistKeySet")       
        Invoke-RestMethod -Method Get -Uri "https://management.core.windows.net:8443/$Using:ID/cloudservices/OaaSCS/resources/automation/~/accounts/$Using:AccountName/Runbooks/?api-version=2014-03-13_Preview" -Certificate $AzureCert -Headers $Using:AzureHeaders
    }
    # Get the Runbook ID for the passed in runbook
    $RunbookId = $Null
    foreach ($RunbookProps in $RunbookList)
    { 
        if ($RunbookProps.Content.Properties.RunbookName -eq $Runbook) {$RunbookId = $RunbookProps.Content.Properties.RunbookID.'#text'}
    }
    
    # If the runbook does not exist in the automation account, throw an error
    if ($RunbookID -eq $null)
    {
        throw "Runbook '$Runbook' not found. Please check that the runbook is published in the automation account Azure Automation"
    }

    # Create the parameters in the format needed for the request body that is sent to the Scheduler job
    $RunbookParameters = ""
    foreach ($Param in $Parameters.Keys)
    {
        $RunbookParameters = $RunbookParameters + '{' + '"Name":' + '"' + $Param + '"' + ','  + '"Value' + '"' + ':' + '"' + $Parameters[$Param] + '"' + '}' + ","
    }
    # Remove trailing comma if parameters are set
    $RunbookParameters = $RunbookParameters.TrimEnd(",")
    
	# Create the request body for the new Scheduler job
    $RunbookWithParams = @"
    {
                "parameters": [
                    $RunbookParameters
                ]
    }
"@

    # Set the Job URI with the subscription ID, account name, and job id
    $JobURI = "https://management.core.windows.net:8443/$ID/cloudservices/OaaSCS/resources/automation/~/accounts/$AccountName/Runbooks(guid'$RunbookID')/Start?api-version=2014-03-13_Preview"

    # Check if the Azure scheduler job collection already exists or create a new one
    if ((Get-AzureSchedulerJobCollection -Location $SchedulerLocation -JobCollectionName $SchedulerJobCollectionName) -eq $null)
     {
        Write-Verbose ("Scheduler job collection $SchedulerJobCollectionName does not exist. Creating it") 
        New-AzureSchedulerJobCollection -Location $SchedulerLocation -JobCollectionName $SchedulerJobCollectionName | Write-Verbose  
     }
     
    # Call the Azure scheduler cmdlet to create / update a scheduled job to call an automation runbook job
    New-AzureSchedulerHttpJob -Location $SchedulerLocation -JobCollectionName $SchedulerJobCollectionName -JobName $SchedulerJobName `
                                -Method POST -Headers $AzureHeaders -URI $JobURI -RequestBody $RunbookWithParams -JobState "Disabled" `
                                -HttpAuthenticationType ClientCertificate -ClientCertificatePfx $CertPath -ClientCertificatePassword $Password 

}