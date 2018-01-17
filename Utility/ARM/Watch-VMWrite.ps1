<#
.SYNOPSIS 
    This sample Automation runbook integrates with Azure event grid subscriptions to get notified when a 
    write command is performed against an Azure VM.
    The runbook adds a cost tag to the VM if it doesn't exist. It also sends an optional notification 
    to a Microsoft Teams channel indicating that a new VM has been created and that it is set up for 
    automatic shutdown / start up tags.
    
.DESCRIPTION
    This sample Automation runbook integrates with Azure event grid subscriptions to get notified when a 
    write command is performed against an Azure VM.
    The runbook adds a cost tag to the VM if it doesn't exist. It also sends an optional notification 
    to a Microsoft Teams channel indicating that a new VM has been created and that it is set up for 
    automatic shutdown / start up tags.
    A RunAs account in the Automation account is required for this runbook.

.PARAMETER WebhookData
    Optional. The information about the write event that is sent to this runbook from Azure Event grid.
  
.PARAMETER ChannelURL
    Optional. The Microsoft Teams Channel webhook URL that information will get sent.

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: November 29th, 2017 
#>
 
Param(
    [parameter (Mandatory=$false)]
    [object] $WebhookData,

    [parameter (Mandatory=$false)]
    $ChannelURL
)

$RequestBody = $WebhookData.RequestBody | ConvertFrom-Json
$Data = $RequestBody.data

if($Data.operationName -match "Microsoft.Compute/virtualMachines/write" -and $Data.status -match "Succeeded")
{
    # Authenticate to Azure
    $ServicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
    Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $ServicePrincipalConnection.TenantId `
        -ApplicationId $ServicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint | Write-Verbose
    
    # Set subscription to work against
    Set-AzureRmContext -SubscriptionID $ServicePrincipalConnection.SubscriptionId | Write-Verbose
   
    # Set tags names
    $TagName = "Cost"
    $TagValue = '{"AutoShutdownStartup":  true}'

    # Get resource group and vm name
    $Resources = $Data.resourceUri.Split('/')
    $VMResourceGroup = $Resources[4]
    $VMName = $Resources[8]

    # Check if tag name exists in subscription and create if needed.
    $TagExists = Get-AzureRmTag -Name $TagName -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($TagExists))
    {
        New-AzureRmTag -Name $TagName | Write-Verbose
    }

    # Check if this VM already has the tag set.
    $VM = Get-AzureRmVM -ResourceGroupName $VMResourceGroup -Name $VMName
    if (!($VM.Tags.ContainsKey($TagName)))
    {
        $Tag = @{"$TagName"=$TagValue}
        # Add Cost tag to VM
        Update-AzureRmVM -ResourceGroupName $VMResourceGroup -VM $VM -Tags $Tag | Write-Verbose

        #Post to teams if the channel webhook is present.   
        if (!([string]::IsNullOrEmpty($ChannelURL)))
        {
            $TargetURL = "https://portal.azure.com/#resource" + $Data.resourceUri + "/overview"   
            
            $Body = ConvertTo-Json -Depth 4 @{
            title = 'Azure VM Creation Notification' 
            text = 'A new Azure VM is available'
            sections = @(
                @{
                activityTitle = 'Azure VM'
                activitySubtitle = 'VM ' + $VM.Name + ' has been created'
                activityText = 'VM was created in the subscription ' + $ServicePrincipalConnection.SubscriptionId + ' and resource group ' + $VM.ResourceGroupName
                activityImage = 'https://azure.microsoft.com/svghandler/automation/'
                }
            )
            potentialAction = @(@{
                '@context' = 'http://schema.org'
                '@type' = 'ViewAction'
                name = 'Click here to manage the VM'
                target = @($TargetURL)
                })
            }
            
            # call Teams webhook
            Invoke-RestMethod -Method "Post" -Uri $ChannelURL -Body $Body | Write-Verbose
        }
    }
}
else
{
    Write-Error "Could not find VM write event"
}



 
