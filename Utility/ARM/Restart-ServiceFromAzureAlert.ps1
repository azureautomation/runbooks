<#
.SYNOPSIS 
    This sample automation runbook is designed to take the payload from an Azure Alert based on a Log Analytics
    query for stopped services. It leverages the change tracking capabilities in Azure Automation to identify services that 
    are stopped in your environment.
    
    This runbook parses out the comptuter name and service name so that it could be extended to start the service
    on the machine using a hybrid worker, collect more informaiton from the machine on what might have caused the issue, or
    escalte the alert to the right system for triage.


.DESCRIPTION
    This sample automation runbook is designed to take the payload from an Azure Alert based on a Log Analytics
    query for stopped services. It leverages the change tracking capabilities in Azure Automation to identify services that 
    are stopped in your environment.
    
    This runbook parses out the comptuter name and service name so that it could be extended to actually start the service
    on the machine using a hybrid worker, collect more informaiton from the machine on what might have caused the issue, or
    escalte the alert to the right system for triage.

    The query used from Log Analytics Azure Alert is: 

    ConfigurationChange
    | where ( ConfigChangeType == "WindowsServices" )
    | where ( SvcChangeType == "State" )
    | where ( SvcState == "Stopped" )
    | where ( SvcDisplayName == "Print Spooler")
    
    The runbook to start on the hybrid worker is called Restart-ServiceOnHybridWorker with the following code.

    Param(
    $ServiceName
    )
   
    Start-Service -Name $ServiceName
    Get-Service -Name $ServiceName

.PARAMETER WebhookData
    Optional. The Alert will pass in the json body of the above query when it is activated.

.NOTES
    AUTHOR: Automation Team
    RELEASE: August 14th, 2018
    LASTEDIT: September 10th, 2018
        - Updated for schema change

#>

Param(
     $WebhookData
 )


 # Payload comes in as a json object so convert the body into PowerShell friendly object.
$RequestBody = ConvertFrom-Json $WebhookData.RequestBody

# Get the results from the table object
$Result =  $RequestBody.data.SearchResult.tables

$i = -1
$Computer = -1
$ServiceName = -1

# Find the computer and service sent in by the alert
foreach ($val in $Result.columns) 
{
    $i++
    if ($val.name -eq "Computer")
    {         
        $Computer = $i
    }
    if ($val.name -eq "SvcName")
    {         
        $ServiceName = $i
    }  
}

# Check if computer name was found
if ($Computer -eq -1)
{
    throw ("Computer name was not found in the payload sent over from the alert")
}

# Check if service name was found
if ($ServiceName -eq -1)
{
    throw ("Service name was not found in the payload sent over from the alert")
}

# Add service name to runbook parameters
$RunbookParameters = @{}
$RunbookParameters.Add("ServiceName",$Result.rows[$ServiceName])

$ComputerName = $Result.rows[$Computer]

# Authenticate with Azure.
$ServicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
Add-AzureRmAccount `
    -ServicePrincipal `
    -TenantId $ServicePrincipalConnection.TenantId `
    -ApplicationId $ServicePrincipalConnection.ApplicationId `
    -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint | Write-Verbose

$Context = Set-AzureRmContext -SubscriptionId $ServicePrincipalConnection.SubscriptionID | Write-Verbose

# Set the resource group and account where the Restart-ServiceOnHybridWorker is published and start it on the hybrid worker. 
$AutomationAccountResourceGroup = "ContosoGroup"
$AutomationAccountName = "ContsoAccount"

Start-AzureRmAutomationRunbook -ResourceGroupName $AutomationAccountResourceGroup -AutomationAccountName $AutomationAccountName `
                               -Name Restart-ServiceOnHybridWorker -Parameters $RunbookParameters -RunOn $ComputerName -Wait -AzureRmContext $Context
