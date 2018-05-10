<#PSScriptInfo

.VERSION 1.2

.GUID 02c1b8eb-28ff-4b7f-9935-3c9285370cd7

.AUTHOR Azure Automation Team

.COMPANYNAME Microsoft Corporation

.COPYRIGHT Microsoft Corporation. All rights reserved.

.TAGS Azure, Azure Automation, Change Tracking, Email, Report

.LICENSEURI https://github.com/azureautomation/runbooks/blob/master/LICENSE

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/New-ChangeReportEmail.ps1

.ICONURI 

.EXTERNALMODULEDEPENDENCIES

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES 

1.2 - 5/10/2018

 -- EDITED BY Jenny Hunter

 -- previous version was outdated and missed key bug fixes


1.1 - 5/9/2018

 -- EDITED BY Jenny Hunter

 -- modified to use the new Log Analytyics module in the AzureRM.OperationalInsights module


1.0 - 4/5/2018

 -- CREATED BY Jenny Hunter

 -- added base script to send email report and to include link to dashboard if AA info is provided


#>

#Requires -Module @{ModuleName = 'AzureRM.Profile'; ModuleVersion = '4.6.0';}

#Requires -Module @{ModuleName = 'AzureRM.OperationalInsights'; ModuleVersion = '4.3.2';}

<#

.SYNOPSIS 

    This Azure Automation runbook generates and sends an email report based on changes in Log Analytics from Change Tracking.


.DESCRIPTION

    This runbook generates a report of changes from the past week and emails it. Note: This script requires two modules:
    the AzureRM.OperationalInsights module. In order for the script to work, both modules must first be imported into 
    the Automation account.
    
    The major steps of the script are outlined below. 

    1) Define parsing function
    2) Connect to the Azure account
    3) Set the subscription context
    4) Prepare email HTML
    5) Define, run, and parse Log Analytics queries for the report
    6) Send the email


.PARAMETER WorkspaceID

    Mandatory. The ID of the OMS Workspace to be referenced. 


.PARAMETER AAName

    Optional. The name of the Azure Automation account to be referenced for the dashboard link. If not specified, the

    value will remain null, and no link to the Change Tracking dashboard will be created.


.PARAMETER AAResourceGroupName

    Optional. The name of the Azure Automation account resource group to be referenced for the dashboard link. If not specified,

    the value will remain null, and no link to the Change Tracking dashboard will be created.


.PARAMETER AASubscriptionID

    Optional. A string containing the SubscriptionID of the Azure Automation account to be referenced for the dashboard 

    link. If not specified, the value will remain null, and no link to the Change Tracking dashboard will be created.

    
.PARAMETER CredentialName

    Mandatory. Credential to use for email


.PARAMETER EmailTo

    Mandatory. Destination email address


.PARAMETER EmailFrom

    Mandatory. Source email address


.PARAMETER SmtpServer

    Optional. SMTP Server url to use for sending out the email. If not specified, "smtp.outlook.com" will be used.



.EXAMPLE

    New-ChangeReportEmail -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxx" -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -CredentialName "AAEmailCred" -EmailTo "jenny@contoso.com" -EmailFrom "it@contoso.com"


.NOTES

    AUTHOR: Jenny Hunter, Azure Automation Team

    LASTEDIT: May 10, 2018

    EDITBY: Jenny Hunter

#>

Param (
# OMS Workspace
[Parameter(Mandatory=$true)]
[String] $WorkspaceId,

# Automation Account
[Parameter(Mandatory=$false)]
[String] $AAName,

[Parameter(Mandatory=$false)]
[String] $AAResourceGroupName,

[Parameter(Mandatory=$false)]
[String] $AASubscriptionID,


# Email
[Parameter(Mandatory=$true)]
[String] $CredentialName,

[Parameter(Mandatory=$true)]
[String] $EmailTo,

[Parameter(Mandatory=$true)]
[String] $EmailFrom,

[Parameter(Mandatory=$false)]
[String] $SmtpServer = "smtp.outlook.com"

)

# Stop the runbook if any errors occur
$ErrorActionPreference = "Stop"

# Define function to parse the query results into read-able HTML
function Get-ParsedResult {
param (
[Parameter(Mandatory=$true)]
[System.Object] $Results
)
    $b = ""
   foreach ($row in $Results.'<>3__rows') {
        $b += "<p>" + $row.Values + "</p>"
   }

    Return ($b -replace " ", " : ")
}

# Connect to the current Azure account
$Conn = Get-AutomationConnection -Name AzureRunAsConnection 
$null = Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationID $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint 

# Timespan
$now = Get-Date
$week = $now.AddDays(-7)

# Create the HTML
$a = '<table align="center" style="border: 1px solid #cccccc; "border="0" cellpadding="0" cellspacing="0" width="600"> <tr> <td bgcolor="#26619C" align="center" style="padding: 20px 0 30px 0; color: #ffffff; font-family: Arial, sans-serif; font-size: 24px;"> <b>Azure Change Tracking </b> <p style="font-size: 20px;">Change Report for ' + $week.ToShortDateString() + " - " + $now.ToShortDateString() + '</p> </td> </tr> <tr> <td bgcolor="#ffffff">'

# Add link to Chaneg Tracking in Azure if AA info was supplied and is accurate
if ($AAName -and $AAResourceGroupName -and $AASubscriptionID) {
    try {
        $null = Get-AzureRmAutomationAccount -ResourceGroupName $AAResourceGroupName -Name $AAName
        $link = "https://portal.azure.com/#@microsoft.onmicrosoft.com/resource/subscriptions/$AASubscriptionID/resourceGroups/$AAResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AAName/changeTrackingTrackChanges"

        $a += '<p align="center" style="padding: 25px 0 0 25px; color: #153643; font-family: Arial, sans-serif; font-size: 16px; line-height: 20px;""><table border="0" cellpadding="0" cellspacing="0" width="100%"> To view your Change tracking dashboard in the Azure portal, click <a href="' + "$link" +'"><font color="#153643"><u>here</u></font></a>.</p>'

    } catch {
        Write-Output "Automation account credentials were invalid. No link will be generated. Error: $_.ExceptionMessage"
    }

}

# Finish preliminary HTML
$a += '<table border="0" cellpadding="0" cellspacing="0" width="100%"> <tr> <td width="260" valign="top"> <table border="0" cellpadding="0" cellspacing="0" width="100%"> <tr> <td style="padding: 25px 0 0 25px; color: #153643; font-family: Arial, sans-serif; font-size: 16px; line-height: 20px;"">'

# Define queries
$ChangeTypesQuery = "ConfigurationChange | summarize count() by ConfigChangeType | sort by count_ desc"
$TopComputersQuery = "ConfigurationChange | summarize count() by Computer | order by count_ desc | limit 5"
$SoftwareAddedQuery = 'ConfigurationChange | where ConfigChangeType == "Software" and ChangeCategory == "Added" | summarize count() by SoftwareType'
$ServicesStoppedQuery = 'ConfigurationChange | where ConfigChangeType == "WindowsServices" and SvcState == "Stopped" | summarize count() by SvcStartupType'

# Collect results
$ChangeTypesResults = (Invoke-AzureRmOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $ChangeTypesQuery -Timespan (New-TimeSpan -Days 7)).Results
$TopComputersResults = (Invoke-AzureRmOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $TopComputersQuery -Timespan (New-TimeSpan -Days 7)).Results
$SoftwareAddedResults = (Invoke-AzureRmOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $SoftwareAddedQuery -Timespan (New-TimeSpan -Days 7)).Results
$ServicesStoppedResults = (Invoke-AzureRmOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $ServicesStoppedQuery -Timespan (New-TimeSpan -Days 7)).Results

# Add results to HTML table
$body = "<h3> Changes per type</h3>"

# Add the HTML results for the Change Type query
$body += (Get-ParsedResult -Results $ChangeTypesResults)

$body += '</td> </tr> </table> </td> <td style=" line-height: 0; color: #153643; font-family: Arial, sans-serif; font-size: 16px; line-height: 20px;"" width="20"> </td> <td width="260" valign="top"> <table border="0" cellpadding="0" cellspacing="0" width="100%"> <tr> <td style="padding: 25px 25px 0 0; color: #153643; font-family: Arial, sans-serif; font-size: 16px; line-height: 20px;"">'

# Add the HTML results for the Top Computers query
$body += "<h3> Top computers with changes</h3>"
$body += Get-ParsedResult -Results $TopComputersResults

$body += '</td> </tr> </table> </td> </tr> <tr> <td width="260" valign="top"> <table border="0" cellpadding="0" cellspacing="0" width="100%"> <tr> <td style="padding: 25px 0 25px 25px; color: #153643; font-family: Arial, sans-serif; font-size: 16px; line-height: 20px;"">'

# Add the HTML results for the Softawre Added query
$body += "<h3> Software added per type</h3>"
$body += Get-ParsedResult -Results $SoftwareAddedResults

$body += '</td> </tr> </table> </td> <td style=" line-height: 0; color: #153643; font-family: Arial, sans-serif; font-size: 16px; line-height: 20px;"" width="20"> </td> <td width="260" valign="top"> <table border="0" cellpadding="0" cellspacing="0" width="100%"> <tr> <td style="padding: 25px 25px 25px 0; color: #153643; font-family: Arial, sans-serif; font-size: 16px; line-height: 20px;"">'

# Add the HTML results for the last query
$body += "<h3> Windows services stopped per startup type</h3>"
$body += Get-ParsedResult -Results $ServicesStoppedResults

# Add the footer
$body += '</td> </tr> </table> </td> </tr> </table> </td> </tr> <tr> <td bgcolor="#26619C" style="padding: 30px 30px 30px 30px;"> <table border="0" cellpadding="0" cellspacing="0" width="100%"> <td style="color: #ffffff; font-family: Arial, sans-serif; font-size: 14px;" width="75%">To learn more about Azure Change tracking, visit <a href="http://www.aka.ms/changetracking"><font color="#ffffff"><u>our documentation page</u></font></a>.</td> </table> </td> </tr> </table> </table>'

# Add the style and body html 
$c = $a + $body

Write-Output $c

# Reference credential for email
$cred = Get-AutomationPSCredential -Name $CredentialName

# Send email
Send-MailMessage -To $EmailTo -From $EmailFrom -Subject ('Change Report for ' + $week.ToShortDateString() + " - " + $now.ToShortDateString()) -Body $c -BodyAsHtml -SmtpServer $SmtpServer -Credential $cred -UseSSL