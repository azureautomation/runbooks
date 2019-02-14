  <#
.SYNOPSIS 
    This sample automation runbook creates a weekly update deployment each Sunday for VMs in a specific Azure resource group
    or an individual VM in a resource group. It assumes that the VM's are already onboarded to Update Management in the automation
    account that this runbook runs in.

.DESCRIPTION
    This sample automation runbook creates a weekly update deployment each Sunday for VMs in a specific Azure resource group
    or an individual VM in a resource group.

.PARAMETER UpdateDeploymentName
    Required. The name of the update deployment

.PARAMETER VMResourceGroup
    Required. The name of resource group that the virtual machines are contained in

.PARAMETER VMName
    Optional. The name of a specific VM in the above resource group

.Example
    .\New-WeeklyUpdateDeployment -UpdateDeploymentName "EverySunday" -VMResourceGroup "Contoso"
 
.NOTES
    AUTHOR: Automation Team
    LASTEDIT: October 20th, 2017 
#>

Param
(
    [Parameter(Mandatory=$True)]
    [String] $UpdateDeploymentName,

    [Parameter(Mandatory=$True)]
    [String] $VMResourceGroup,

    [Parameter(Mandatory=$False)]
    [String] $VMName   
) 

# Stop on errors
$ErrorActionPreference = 'stop'

# Management URI for Azure resource manager
$ResourceAppIdURI = "https://management.core.windows.net/"

# Login uri for Azure AD
$LoginURI = "https://login.windows.net/"

# Import AzureRM.prifle module and load the Azure AD client library that lives in its folder
Import-Module AzureRM.profile | Write-Verbose
$ProfileModule = Get-Module AzureRM.profile
$ProfileModulePath = Split-Path -Parent $ProfileModule.Path
Add-Type -Path (Join-Path $ProfileModulePath "Microsoft.IdentityModel.Clients.ActiveDirectory.dll")

# Get RunAsConnection
$RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
$Certifcate = Get-AutomationCertificate -Name "AzureRunAsCertificate"

# Set subscription to work against
$SubscriptionId = $RunAsConnection.SubscriptionId

# Set up authentication using service principal client certificate
$Authority = $LoginURI + $RunAsConnection.TenantId
$AuthContext = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext" -ArgumentList $Authority
$ClientCertificate = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.ClientAssertionCertificate" -ArgumentList $RunAsConnection.ApplicationId, $Certifcate
$AuthResult = $AuthContext.AcquireToken($ResourceAppIdURI, $ClientCertificate)

# Set up header with authorization token
$AuthToken = $AuthResult.CreateAuthorizationHeader()
$RequestHeader = @{
  "Content-Type" = "application/json";
  "Authorization" = "$AuthToken"
}

# Authenticate to Azure resources to find resource group and account name
Add-AzureRmAccount `
    -ServicePrincipal `
    -TenantId $RunAsConnection.TenantId `
    -ApplicationId $RunAsConnection.ApplicationId `
    -CertificateThumbprint $RunAsConnection.CertificateThumbprint | Write-Verbose

Select-AzureRmSubscription -SubscriptionId $RunAsConnection.SubscriptionID  | Write-Verbose 

# Find out the resource group and account name
$AutomationResource = Get-AzureRmResource -ResourceType Microsoft.Automation/AutomationAccounts
foreach ($Automation in $AutomationResource)
{
    $Job = Get-AzureRmAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
    if (!([string]::IsNullOrEmpty($Job)))
    {
        $AutomationResourceGroup = $Job.ResourceGroupName
        $AutomationAccount = $Job.AutomationAccountName
        break;
    }
}

# Get VMs to set up update deployment for
if ([string]::IsNullOrEmpty($VMName))
{
    $VMs = Get-AzureRMVM -ResourceGroupName $VMResourceGroup 
}
else
{
    $VMs = Get-AzureRMVM -ResourceGroupName $VMResourceGroup -Name $VMName  
}

# Create list of VMs to update based on the VM resource id
$VMlist = $null
foreach ($VM in $VMs)
{
    $VMList = $VMlist +  '"' + $VM.Id + '",'
}
$VMList = $VMList.TrimEnd(",")


# Set up new Update deployment
$URI =  “https://management.azure.com/subscriptions/$SubscriptionId/"`
     +"resourceGroups/$($AutomationResourceGroup)/providers/Microsoft.Automation/"`
     +"automationAccounts/$AutomationAccount/softwareUpdateConfigurations/" + $UpdateDeploymentName + "?api-version=2017-05-15-preview"
 

# Set the next run for Sunday at 3 am.
$NextSunday = ((Get-Date).Date).AddHours(3)
while ($NextSunday.DayOfWeek -ne "Sunday")
{
    $NextSunday = $NextSunday.AddDays(1)
}
$StartDate = Get-Date $NextSunday -Format "s"

# End date is 1 year from now
$ExpireRun = (Get-Date).AddYears(1)
$EndDate = Get-Date $ExpireRun -Format "s"

# Modify the below values as needed for your specific update deployment.
# Review https://docs.microsoft.com/en-us/rest/api/automation/schedule for schedule options
$Body = @"
{  
   "properties":{  
      "updateConfiguration":{  
         "operatingSystem":"Windows",
         "duration":"PT1H30M",
         "windows":{  
            "excludedKBNumbers":[  
               "12345",
               "6789"
            ],
            "includedUpdateClassifications":"Critical,Definition,FeaturePack,Security,ServicePack,Tools,UpdateRollup,Updates"
         },
         "azureVirtualMachines":[  
            $VMlist
         ],
         "nonAzureComputerNames":[  
         ]
      },
      "scheduleInfo":{  
         "frequency":3,
         "startTime":"$StartDate",
         "timeZone":"America/Los_Angeles",
         "interval":1,
         "expiryTime":"$EndDate",
         "advancedSchedule":{  
            "weekDays":[  
               "Sunday"
            ]
         }
      }
   }
}
"@

# Create update deployment job
$UpdateDeploymentJob = Invoke-RestMethod -Uri $URI -Method Put -Body $Body  -Headers $RequestHeader

# Wait for update provisioning job to complete 
While ($UpdateDeploymentJob.properties.provisioningState -eq "Provisioning") {
    Start-Sleep 5
    $UpdateDeploymentJob = Invoke-RestMethod -Uri $URI -Method GET -Headers $RequestHeader
}

if ($UpdateDeploymentJob.properties.provisioningState -eq "Failed")
{
    throw ("Error creating update deployment:" + $UpdateDeploymentJob.properties.error)
}
else
{
    Write-Output ("Update deployment succeeded for the following computers:")
    Write-Output $VMs.Name
}
 

