<#

.SYNOPSIS 

    This Azure Automation runbook generates an email report based on reported changes in Log Analytics from Change Tracking.


.DESCRIPTION

    This runbook generates a report of changes from the past week and emails it. Note: This script requires two modules:
    the AzureRM.OperationalInsights module and the new Log Analytics custom module. In order for the script to work, both
    modules must first be imported into the Automation account. The Log Analytics module is not currently available from 
    the PS Gallery and must be downloaded from https://dev.loganalytics.io/oms/documentation/4-Tools/LogAnalyticsQuery.psm1 .
    
    The major steps of the script are outlined below. 

    1) Define parsing function
    2) Connect to the Azure account
    3) Set the subscription context
    4) Set query timespan to one week
    5) Prepare email HTML
    6) Define, run, and parse Log Analytics queries for the report
    7) Send the email
    


.PARAMETER OMSResourceGroupName

    Mandatory. The name of the resource group to be referenced for the OMS workspace. If not specified,
    
    the AAResourceGroupName is useed.


.PARAMETER SubscriptionID

    Mandatory. A string containing the SubscriptionID to be used. 


.PARAMETER WorkspaceName

    Mandatory. The name of the OMS Workspace to be referenced. If not specified, a new OMS workspace 

    is created using a unique identifier.


.PARAMETER AAName

    Optional. The name of the Azure Automation account to be referenced for the dashboard link. If not specified, the

    value will remain null, and no link to the Change Tracking dashboard will be created.


.PARAMETER AAResourceGroupName

    Optional. The name of the Azure Automation account resource group to be referenced for the dashboard link. If not specified,

    the value will remain null, and no link to the Change Tracking dashboard will be created.

    
.PARAMETER CredentialName

    Mandatory. Credential to use for email


.PARAMETER EmailTo

    Mandatory. Destination email address


.PARAMETER EmailFrom

    Mandatory. Source email address


.PARAMETER SmtpServer

    Optional. SMTP Server url to use for sending out the email. If not specified, "smtp.outlook.com" will be used.



.EXAMPLE

    New-ChangeReportEmail -WorkspaceName "ContosoAA" -OMSResourceGroupName "ContosoResources" -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -CredentialName "AAEmailCred" -EmailTo "jenny@contoso.com" -EmailFrom "it@contoso.com"


.NOTES

    AUTHOR: Jenny Hunter, Azure Automation Team

    LASTEDIT: April 4, 2018

    EDITBY: Jenny Hunter

#>

Param (
# OMS Workspace
[Parameter(Mandatory=$true)]
[String] $WorkspaceName,

[Parameter(Mandatory=$true)]
[String] $OMSResourceGroupName,


# Subscription
[Parameter(Mandatory=$true)]
[String] $SubscriptionID,

# Automation Account
[Parameter(Mandatory=$false)]
[String] $AAName,

[Parameter(Mandatory=$false)]
[String] $AAResourceGroupName,


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
function Parse-Results {
param (
[Parameter(Mandatory=$true)]
[String[]] $Results
)
    $b = ""

   if (($Results.Length -eq 2) -and ($Results[0] -notmatch "\d" )) {
        $b += "<p>" + $Results[0] + " : " + $Results[1] + "</p>"
    } else {
        foreach ($value in $Results) {
            $b += "<p>"
            $b += $value -Replace " ", " : "
            $b += "</p>"
        }
    }
    
    Return $b
}

# Connect to the current Azure account
$Conn = Get-AutomationConnection -Name AzureRunAsConnection 
$null = Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationID $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint 

# Set the active subscription
$null = Set-AzureRmContext -SubscriptionID $SubscriptionID

# Check that the resource groups are valid
$null = Get-AzureRmResourceGroup -Name $OMSResourceGroupName

# Check that the OMS Workspace is valid
$Workspace = Get-AzureRmOperationalInsightsWorkspace -Name $WorkspaceName -ResourceGroupName $OMSResourceGroupName  -ErrorAction Stop

# Timespan
$now = Get-Date
$week = $now.AddDays(-7)
$isotimespan = $week.ToUniversalTime().ToString( "yyyy-MM-ddTHH:mm:ss.fffffffZ") + "/" + $now.ToUniversalTime().ToString( "yyyy-MM-ddTHH:mm:ss.fffffffZ")

# Create the HTML
$a = '<table align="center" style="border: 1px solid #cccccc; "border="0" cellpadding="0" cellspacing="0" width="600"> <tr> <td bgcolor="#26619C" align="center" style="padding: 20px 0 30px 0; color: #ffffff; font-family: Arial, sans-serif; font-size: 24px;"> <b>Azure Change Tracking </b> <p style="font-size: 20px;">Change Report for ' + $week.ToShortDateString() + " - " + $now.ToShortDateString() + '</p> </td> </tr> <tr> <td bgcolor="#ffffff">'

# Add link to Chaneg Tracking in Azure if AA info was supplied and is accurate
if ($AAName -and $AAResourceGroupName) {
    try {
        $null = Get-AzureRmAutomationAccount -ResourceGroupName $AAResourceGroupName -Name $AAName
        $link = "https://portal.azure.com/#@microsoft.onmicrosoft.com/resource/subscriptions/$SubscriptionID/resourceGroups/$AAResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AAName/changeTrackingTrackChanges"

        $a += '<p align="center" style="padding: 25px 0 0 25px; color: #153643; font-family: Arial, sans-serif; font-size: 16px; line-height: 20px;""><table border="0" cellpadding="0" cellspacing="0" width="100%"> To view your Change tracking dashboard in the Azure portal, click <a href="' + "$link" +'"><font color="#153643"><u>here</u></font></a>.</p>'

    } catch {
        Write-Output "Automation account credentials were invalid. No link will be generated. Error: $_.ExceptionMessage"
    }

}

# Finish preliminary HTML
$a += '<table border="0" cellpadding="0" cellspacing="0" width="100%"> <tr> <td width="260" valign="top"> <table border="0" cellpadding="0" cellspacing="0" width="100%"> <tr> <td style="padding: 25px 0 0 25px; color: #153643; font-family: Arial, sans-serif; font-size: 16px; line-height: 20px;"">'

# Define queries
$ChangeTypesQuery = "ConfigurationChange | summarize count() by ConfigChangeType | sort by count_ desc"
$TopComputersQuery = "ConfigurationChange | summarize ChangeCount= count() by Computer | order by ChangeCount desc | limit 5"
$SoftwareAddedQuery = 'ConfigurationChange | where ConfigChangeType == "Software" and ChangeCategory == "Added" | summarize count() by SoftwareType'
$ServicesStoppedQuery = 'ConfigurationChange | where ConfigChangeType == "WindowsServices" and SvcState == "Stopped" | summarize count() by SvcStartupType'

# Collect results
$ChangeTypesResults = (Invoke-LogAnalyticsQuery -WorkspaceName $WorkspaceName -ResourceGroup $OMSResourceGroupName -SubscriptionId $SubscriptionID -Query $ChangeTypesQuery -Timespan $isotimespan).Response.Content
$TopComputersResults = (Invoke-LogAnalyticsQuery -WorkspaceName $WorkspaceName -ResourceGroup $OMSResourceGroupName -SubscriptionId $SubscriptionID -Query $TopComputersQuery -Timespan $isotimespan).Response.Content
$SoftwareAddedResults = (Invoke-LogAnalyticsQuery -WorkspaceName $WorkspaceName -ResourceGroup $OMSResourceGroupName -SubscriptionId $SubscriptionID -Query $SoftwareAddedQuery -Timespan $isotimespan).Response.Content
$ServicesStoppedResults = (Invoke-LogAnalyticsQuery -WorkspaceName $WorkspaceName -ResourceGroup $OMSResourceGroupName -SubscriptionId $SubscriptionID -Query $ServicesStoppedQuery -Timespan $isotimespan).Response.Content


# Convert results into human readable format
$ChangeTypesResults = $ChangeTypesResults | ConvertFrom-Json
$ChangeTypes = $ChangeTypesResults.tables.rows

$TopComputersResults = $TopComputersResults | ConvertFrom-Json
$TopComputers = $TopComputersResults.tables.rows

$SoftwareAddedResults = $SoftwareAddedResults | ConvertFrom-Json
$SoftwareAdded = $SoftwareAddedResults.tables.rows

$ServicesStoppedResults = $ServicesStoppedResults | ConvertFrom-Json
$ServicesStopped = $ServicesStoppedResults.tables.rows

# Add results to HTML table
$body = "<h3> Changes per type</h3>"

# Add the HTML results for the Change Type query
$body += Parse-Results -Results $ChangeTypes

$body += '</td> </tr> </table> </td> <td style=" line-height: 0; color: #153643; font-family: Arial, sans-serif; font-size: 16px; line-height: 20px;"" width="20"> </td> <td width="260" valign="top"> <table border="0" cellpadding="0" cellspacing="0" width="100%"> <tr> <td style="padding: 25px 25px 0 0; color: #153643; font-family: Arial, sans-serif; font-size: 16px; line-height: 20px;"">'

# Add the HTML results for the Top Computers query
$body += "<h3> Top computers with changes</h3>"
$body += Parse-Results -Results $TopComputers

$body += '</td> </tr> </table> </td> </tr> <tr> <td width="260" valign="top"> <table border="0" cellpadding="0" cellspacing="0" width="100%"> <tr> <td style="padding: 25px 0 25px 25px; color: #153643; font-family: Arial, sans-serif; font-size: 16px; line-height: 20px;"">'

# Add the HTML results for the Softawre Added query
$body += "<h3> Software added per type</h3>"
$body += Parse-Results -Results $SoftwareAdded

$body += '</td> </tr> </table> </td> <td style=" line-height: 0; color: #153643; font-family: Arial, sans-serif; font-size: 16px; line-height: 20px;"" width="20"> </td> <td width="260" valign="top"> <table border="0" cellpadding="0" cellspacing="0" width="100%"> <tr> <td style="padding: 25px 25px 25px 0; color: #153643; font-family: Arial, sans-serif; font-size: 16px; line-height: 20px;"">'

# Add the HTML results for the last query
$body += "<h3> Windows services stopped per startup type</h3>"
$body += Parse-Results -Results $ServicesStopped

# Add the footer
$body += '</td> </tr> </table> </td> </tr> </table> </td> </tr> <tr> <td bgcolor="#26619C" style="padding: 30px 30px 30px 30px;"> <table border="0" cellpadding="0" cellspacing="0" width="100%"> <td style="color: #ffffff; font-family: Arial, sans-serif; font-size: 14px;" width="75%">To learn more about Azure Change tracking, visit <a href="http://www.aka.ms/changetracking"><font color="#ffffff"><u>our documentation page</u></font></a>.</td> </table> </td> </tr> </table> </table>'

# Add the style and body html 
$c = $a + $body

Write-Output $c

# Reference credential for email
$cred = Get-AutomationPSCredential -Name $CredentialName

# Send email
Send-MailMessage -To $EmailTo -From $EmailFrom -Subject ('Change Report for ' + $week.ToShortDateString() + " - " + $now.ToShortDateString()) -Body $c -BodyAsHtml -SmtpServer $SmtpServer -Credential $cred -UseSSL