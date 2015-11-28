<# 
.SYNOPSIS  
    Creates a number of Azure Environment Resources (in sequence) based on the following input parameters: 
        "Azure Connection Name", "Project Name", "VM Name", "VM Instance Size" 
        (and optionally "Storage Account Name") 
 
.DESCRIPTION 
    This runbook leverages an existing connection to an Azure subscription (requires Connect-Azure runbook) 
    to create the following Azure Environment Resources: Azure Affinity Group, Azure Cloud Service, 
        Azure Storage Account, and Azure VM from an existing Azure VM Image 
 
    The entire runbook is heavily checkpointed and can be run multiple times without resource recreation. 
 
    It relies on five (5) Automation Assets (to be configured in the Assets tab). These are 
    suggested, not required. Replacing the "Get-AutomationVariable" calls within this runbook with static 
    or parameter variables is an alternative method. For this example though, the following dependencies exist: 
    VARIABLES SET WITH AUTOMATION ASSETS: 
        $AGLocation = Get-AutomationVariable -Name 'AGLocation' 
        $VMImage = Get-AutomationVariable -Name 'VMImage' 
            Example Image: a699494373c04fc0bc8f2bb1389d6106__Windows-Server-2012-R2-201404.01-en.us-127GB.vhd 
        $VMImageOS = Get-AutomationVariable -Name 'VMImageOS' 
        $AdminUsername = Get-AutomationVariable -Name 'AdminUsername' 
        $Password = Get-AutomationVariable -Name 'Password' 
 
.PARAMETER AzureConnectionName 
    REQUIRED. Name of the Azure connection setting that was created in the Automation service. 
    This connection setting contains the subscription id and the name of the certificate setting that  
    holds the management certificate. It will be passed to the requied and nested Connect-Azure runbook. 
 
.PARAMETER ProjectName 
    REQUIRED. Name of the Project for the deployment of Azure Environment Resources. This name is leveraged 
    throughout the runbook to derive the names of the Azure Environment Resources created. 
 
.PARAMETER VMName 
    REQUIRED. Name of the Virtual Machine to be created as part of the Project. 
 
.PARAMETER VMInstanceSize 
   REQUIRED. Specifies the size of the instance. Supported values are as below with their (cores, memory)  
   "ExtraSmall" (shared core, 768 MB), 
   "Small"      (1 core, 1.75 GB), 
   "Medium"     (2 cores, 3.5 GB), 
   "Large"      (4 cores, 7 GB), 
   "ExtraLarge" (8 cores, 14GB), 
   "A5"         (2 cores, 14GB) 
   "A6"         (4 cores, 28GB) 
   "A7"         (8 cores, 56 GB) 
 
.PARAMETER StorageAccountName 
    OPTIONAL. This parameter should only be set if the runbook is being re-executed after an existing 
    and unique Storage Account Name has already been created, or if a new and unique Storage Account Name 
    is desired. If left blank, a new and unique Storage Account Name will be created for the Project. The 
    format of the derived Storage Account Names is: 
        $ProjectName (lowercase) + [Random lowercase letters and numbers] up to a total Length of 23 
 
.EXAMPLE 
    New-AzureEnvironmentResources -AzureConnectionName "Azure Subscription" ` 
        -ProjectName "MyProject001" -VMName "MyVM001" -VMInstanceSize "ExtraSmall" 
         
.EXAMPLE 
    New-AzureEnvironmentResources -AzureConnectionName "Azure Subscription" -ProjectName "MyProject001" ` 
        -VMName "MyVM001" -VMInstanceSize "ExtraSmall" -StorageAccountName "myproject001n3o3m5u0u1l" 
 
.NOTES 
    AUTHOR: Charles Joy, WSSC CAT Team, Microsoft 
    BLOG: Building Cloud Blog - http://aka.ms/BuildingClouds 
    LAST EDIT: May 19, 2014 
#> 
 
workflow New-AzureEnvironmentResourcesFromGallery 
{ 
    param 
    ( 
        [Parameter(Mandatory=$true)] 
        [string]$AzureConnectionName, 
        [Parameter(Mandatory=$true)] 
        [string]$ProjectName, 
        [Parameter(Mandatory=$true)] 
        [string]$VMName, 
        [Parameter(Mandatory=$true)] 
        [string]$VMInstanceSize, 
        [Parameter(Mandatory=$false)] 
        [string]$StorageAccountName 
    ) 
 
    #################################################################################################### 
    # Set Variables (all non-derived variables are based on Automation Assets) 
     
    # Set Azure Affinity Group Variables 
    $AGName = $ProjectName 
    $AGLocation = Get-AutomationVariable -Name 'AGLocation' 
    $AGLocationDesc = "Affinity group for {0} VMs"  -f $ProjectName 
    $AGLabel = "{0} {1}" -f $AGLocation,$ProjectName 
     
    # Set Azure Cloud Service Variables 
    $CloudServiceName = $ProjectName 
    $CloudServiceDesc = "Service for {0} VMs" -f $ProjectName 
    $CloudServiceLabel = "{0} VMs" -f $ProjectName 
 
    # Set Azure Storage Account Variables 
    if (!$StorageAccountName) { 
        $StorageAccountName = $ProjectName.ToLower() 
        $rand = New-Object System.Random 
        $RandomPadCount = 23 - $StorageAccountName.Length 
        foreach ($r in 1..$RandomPadCount) { if ($r%2 -eq 1) { $StorageAccountName += [char]$rand.Next(97,122) } else { $StorageAccountName += [char]$rand.Next(48,57) } } 
    } 
    $StorageAccountDesc = "Storage account for {0} VMs" -f $ProjectName 
    $StorageAccountLabel = "{0} Storage" -f $ProjectName 
 
    # Set Azure VM Image Variables 
    $VMImage = Get-AutomationVariable -Name 'VMImage' 
    $VMImageOS = Get-AutomationVariable -Name 'VMImageOS' 
 
    #Set Azure VM Variables 
    $ServiceName = $ProjectName 
    $AdminUsername = Get-AutomationVariable -Name 'AdminUsername' 
    $Password = Get-AutomationVariable -Name 'Password' 
    $Windows = $true 
    $WaitForBoot = $true 
 
    #################################################################################################### 
 
    # Call the Connect-Azure Runbook to set up the connection to Azure using the Automation Connection Asset 
    Connect-Azure -AzureConnectionName $AzureConnectionName 
    Select-AzureSubscription -SubscriptionName $AzureConnectionName 
    $AzureSubscription = Get-AzureSubscription -SubscriptionName $AzureConnectionName 
 
    #################################################################################################### 
    # Create/Verify Azure Affinity Group 
 
    if ($AzureSubscription.SubscriptionName -eq $AzureConnectionName) { 
 
        Write-Verbose "Connection to Azure Established - Specified Azure Environment Resource Creation In Progress..." 
 
        $AzureAffinityGroup = Get-AzureAffinityGroup -Name $AGName -ErrorAction SilentlyContinue 
 
        if(!$AzureAffinityGroup) { 
            $AzureAffinityGroup = New-AzureAffinityGroup -Location $AGLocation -Name $AGName -Description $AGLocationDesc -Label $AGLabel 
            $VerboseMessage = "{0} for {1} {2} (OperationId: {3})" -f $AzureAffinityGroup.OperationDescription,$AGName,$AzureAffinityGroup.OperationStatus,$AzureAffinityGroup.OperationId 
        } else { $VerboseMessage = "Azure Affinity Group {0}: Verified" -f $AzureAffinityGroup.Name } 
 
        Write-Verbose $VerboseMessage 
 
    } else { 
        $ErrorMessage = "Azure Connection to $AzureConnectionName could not be Verified." 
        Write-Error $ErrorMessage -Category ResourceUnavailable 
        throw $ErrorMessage 
     } 
 
    # Checkpoint after Azure Affinity Group Creation 
    Checkpoint-Workflow 
     
    # Call the Connect-Azure Runbook after Checkpoint to reestablish the connection to Azure using the Automation Connection Asset 
    Connect-Azure -AzureConnectionName $AzureConnectionName 
    Select-AzureSubscription -SubscriptionName $AzureConnectionName 
 
    #################################################################################################### 
 
    #################################################################################################### 
    # Create/Verify Azure Cloud Service 
 
    if ($AzureAffinityGroup.OperationStatus -eq "Succeeded" -or $AzureAffinityGroup.Name -eq $AGName) { 
     
        $AzureCloudService = Get-AzureService -ServiceName $CloudServiceName -ErrorAction SilentlyContinue 
 
        if(!$AzureCloudService) { 
            $AzureCloudService = New-AzureService -AffinityGroup $AGName -ServiceName $CloudServiceName -Description $CloudServiceDesc -Label $CloudServiceLabel 
            $VerboseMessage = "{0} for {1} {2} (OperationId: {3})" -f $AzureCloudService.OperationDescription,$CloudServiceName,$AzureCloudService.OperationStatus,$AzureCloudService.OperationId 
        } else { $VerboseMessage = "Azure Cloud Serivce {0}: Verified" -f $AzureCloudService.ServiceName } 
 
        Write-Verbose $VerboseMessage 
 
    } else { 
        $ErrorMessage = "Azure Affinity Group Creation Failed OR Could Not Be Verified for: $AGName" 
        Write-Error $ErrorMessage -Category ResourceUnavailable 
        throw $ErrorMessage 
     } 
 
    # Checkpoint after Azure Cloud Service Creation 
    Checkpoint-Workflow 
     
    # Call the Connect-Azure Runbook after Checkpoint to reestablish the connection to Azure using the Automation Connection Asset 
    Connect-Azure -AzureConnectionName $AzureConnectionName 
    Select-AzureSubscription -SubscriptionName $AzureConnectionName 
 
    #################################################################################################### 
 
    #################################################################################################### 
    # Create/Verify Azure Storage Account 
 
    if ($AzureCloudService.OperationStatus -eq "Succeeded" -or $AzureCloudService.ServiceName -eq $CloudServiceName) { 
         
        $AzureStorageAccount = Get-AzureStorageAccount -StorageAccountName $StorageAccountName -ErrorAction SilentlyContinue 
 
        if(!$AzureStorageAccount) { 
            $AzureStorageAccount = New-AzureStorageAccount -AffinityGroup $AGName -StorageAccountName $StorageAccountName -Description $StorageAccountDesc -Label $StorageAccountLabel 
            $VerboseMessage = "{0} for {1} {2} (OperationId: {3})" -f $AzureStorageAccount.OperationDescription,$StorageAccountName,$AzureStorageAccount.OperationStatus,$AzureStorageAccount.OperationId 
        } else { $VerboseMessage = "Azure Storage Account {0}: Verified" -f $AzureStorageAccount.StorageAccountName } 
 
        Write-Verbose $VerboseMessage 
 
    } else { 
        $ErrorMessage = "Azure Cloud Service Creation Failed OR Could Not Be Verified for: $CloudServiceName" 
        Write-Error $ErrorMessage -Category ResourceUnavailable 
        throw $ErrorMessage 
     } 
 
    # Checkpoint after Azure Storage Account Creation 
    Checkpoint-Workflow 
     
    # Call the Connect-Azure Runbook after Checkpoint to reestablish the connection to Azure using the Automation Connection Asset 
    Connect-Azure -AzureConnectionName $AzureConnectionName 
    Select-AzureSubscription -SubscriptionName $AzureConnectionName 
 
    #################################################################################################### 
     
    # Sleep for 60 seconds to ensure Storage Account is fully created 
    Start-Sleep -Seconds 60 
     
    # Set CurrentStorageAccount for the Azure Subscription 
    Set-AzureSubscription -SubscriptionName $AzureConnectionName -CurrentStorageAccount $StorageAccountName 
 
    #################################################################################################### 
    # Verify Azure VM Image 
         
    $AzureVMImage = Get-AzureVMImage -ImageName $VMImage -ErrorAction SilentlyContinue 
 
    if($AzureVMImage) { $VerboseMessage = "Azure VM Image {0}: Verified" -f $AzureVMImage.ImageName } 
    else { 
        $ErrorMessage = "Azure VM Image Could Not Be Verified for: $VMImage" 
        Write-Error $ErrorMessage -Category ResourceUnavailable 
        throw $ErrorMessage 
    } 
 
    Write-Verbose $VerboseMessage 
 
    # Checkpoint after Azure VM Creation 
    Checkpoint-Workflow 
     
    # Call the Connect-Azure Runbook after Checkpoint to reestablish the connection to Azure using the Automation Connection Asset 
    Connect-Azure -AzureConnectionName $AzureConnectionName 
    Select-AzureSubscription -SubscriptionName $AzureConnectionName 
 
    #################################################################################################### 
 
    #################################################################################################### 
    # Create Azure VM 
     
    if ($AzureVMImage.ImageName -eq $VMImage) { 
 
        $AzureVM = Get-AzureVM -Name $VMName -ServiceName $ServiceName -ErrorAction SilentlyContinue 
      
        if(!$AzureVM -and $Windows) { 
            $AzureVM = New-AzureQuickVM -AdminUsername $AdminUsername -ImageName $VMImage -Password $Password ` 
                -ServiceName $ServiceName -Windows:$Windows -InstanceSize $VMInstanceSize -Name $VMName -WaitForBoot:$WaitForBoot 
            $VerboseMessage = "{0} for {1} {2} (OperationId: {3})" -f $AzureVM.OperationDescription,$VMName,$AzureVM.OperationStatus,$AzureVM.OperationId 
        } else { $VerboseMessage = "Azure VM {0}: Verified" -f $AzureVM.InstanceName } 
 
        Write-Verbose $VerboseMessage 
 
    } else { 
        $ErrorMessage = "Azure VM Image Creation Failed OR Could Not Be Verified for: $VMImage" 
        Write-Error $ErrorMessage -Category ResourceUnavailable 
        $ErrorMessage = "Azure VM Not Created: $VMName" 
        Write-Error $ErrorMessage -Category NotImplemented 
        throw $ErrorMessage 
     } 
 
    #################################################################################################### 
 
    if ($AzureVM.OperationStatus -eq "Succeeded" -or $AzureVM.InstanceName -eq $VMName) { 
        $CompletedNote = "All Steps Completed - All Specified Azure Environment Resources Created." 
        Write-Verbose $CompletedNote 
        Write-Output $CompletedNote 
    } else { 
        $ErrorMessage = "Azure VM Creation Failed OR Could Not Be Verified for: $VMName" 
        Write-Error $ErrorMessage -Category ResourceUnavailable 
        $ErrorMessage = "Not Complete - One or more Specified Azure Environment Resources was NOT Created." 
        Write-Error $ErrorMessage -Category NotImplemented 
        throw $ErrorMessage 
     } 
}