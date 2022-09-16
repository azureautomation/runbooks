#
.SYNOPSIS
	This PowerShell script is for migration of Automation account assets from the account in primary region to the account in secondary region. This script migrates only Runbooks, Modules, Connections, Credentials, Certificates and Variables.

	Prerequisites:
		1.Ensure that the Automation account in the secondary region is created and available so that assets from primary region can be migrated to it.
		2.System Managed Identities should be enabled in the Automation account in the primary region.
		3.Ensure that Primary Automation account's Managed Identity has Contributor access with read and write permissions to the Automation account in secondary region. You can enable it by providing the necessary permissions in Secondary Automation account’s managed identities. Learn more
		4.This script requires access to Automation account assets in primary region. Hence, it should be executed as a runbook in that Automation account for successful migration.

	.PARAMETER SourceAutomationAccountName
		[Optional] Name of automation account from where assets need to be migrated (Source Account)
	.PARAMETER DestinationAutomationAccountName
		[Optional] Name of automation account to where assets need to be migrated (Destination Account)
	.PARAMETER SourceResourceGroup
		[Optional] Resource group to which the automation account from where assets need to be migrated
	.PARAMETER DestinationResourceGroup
		[Optional] Resource group to which the automation account to where assets need to be migrated
	.PARAMETER SourceSubscriptionId
		[Optional] Id of the Subscription to which the automation account from where assets need to be migrated
	.PARAMETER DestinationSubscriptionId
		[Optional] Id of the Subscription to which the automation account to where assets need to be migrated
	.PARAMETER SourceAutomationAccountResourceId
		[Optional] Resource Id of the automation account from where assets need to be migrated
	.PARAMETER DestinationAutomationAccountResourceId
		[Optional] Resource Id of the automation account to where assets need to be migrated
.AUTHOR Microsoft

.VERSION 1.0
#>
#Requires -module @{ ModuleName="Az.Accounts"; ModuleVersion="	2.8.0" },@{ ModuleName="Az.Resources"; ModuleVersion="	6.0.0" },@{ ModuleName="Az.Automation"; ModuleVersion="1.7.3" },@{ ModuleName="Az.Storage"; ModuleVersion="4.6.0" }
#Requires -psedition Core


$Version="1.0"
Write-Output $Version


try
{
    "Logging in to Azure..."
    Connect-AzAccount -Identity
}
catch {
    Write-Error -Message $_.Exception
    throw $_.Exception
}

$SourceAutomationAccountName
$DestinationAutomationAccountName
$SourceResourceGroup
$DestinationResourceGroup
$SourceSubscriptionId
$DestinationSubscriptionId
$SourceAutomationAcccountResourceId="/subscriptions/430eaafe-fb8f-4014-8deb-1b174430a299/resourceGroups/abhishek/providers/Microsoft.Automation/automationAccounts/MigStart"
$DestinationAutomationAcccountResourceId= "/subscriptions/1e5e7c02-d552-41bc-95fc-bdf8e8478fcf/resourceGroups/abhishek1/providers/Microsoft.Automation/automationAccounts/MigEndPoint"
$Types= @("Certificates", "Connections", "Credentials", "Modules", "Runbooks", "Variables")

Function ParseReourceID($resourceID)
{
	$array = $resourceID.Split('/') 
	$indexRG = 0..($array.Length -1) | where {$array[$_] -eq 'resourcegroups'}
	$indexSub = 0..($array.Length -1) | where {$array[$_] -eq 'subscriptions'}
	$indexAA =0..($array.Length -1) | where {$array[$_] -eq 'automationAccounts'}
	$result = $array.get($indexRG+1),$array.get($indexSub+1),$array.get($indexAA+1)
	return $result
}

Function CheckifInputIsValid($In)
{
	if ([string]::IsNullOrWhiteSpace($In))
    {
       return $False
    }
	return $True
}

Function Test-IsGuid
{
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$StringGuid
    )
 
   $ObjectGuid = [System.Guid]::empty
   return [System.Guid]::TryParse($StringGuid,[System.Management.Automation.PSReference]$ObjectGuid) # Returns True if successfully parsed
}

#Get bearer token for authentication
Function Get-AzCachedAccessToken() 
{
	$token=Get-AzAccessToken 
    return [String]$token.Token
}


#Module transfer helper functions

Function StoreModules($Modules_Custom)
{

	Foreach($Module in $Modules_Custom)
	{
		
	
		$ModuleName = $Module
		$ModulePath="C:\Modules\User\"+$ModuleName
		$ModuleZipPath="C:\"+ $tempFolder+"\"+$ModuleName+".zip"
		try
		{
			Compress-Archive -LiteralPath $ModulePath -DestinationPath $ModuleZipPath
		}
		catch
		{
			Write-Error -Message "Unable to store custom modules, error while accessing the temprary memory. Error Message: $($Error[0].Exception.Message)"
		}
	}

}


Function CreateStorageAcc($StorageAccountName, $storageAccountRG)
{
	New-AzStorageAccount -ResourceGroupName $storageAccountRG -Name $StorageAccountName -Location westus -SkuName Standard_LRS
	$storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $storageAccountRG -AccountName $storageAccountName).Value[0]
	$secureStorageAccountKey=ConvertTo-SecureString [String]$storageAccountKey -AsPlainText -Force
	return $secureStorageAccountKey
	
}

Function CreateContainer($Context,$storageContainerName)
{
	New-AzStorageContainer -Name $storageContainerName -Context $Context -Permission Container
}


Function SendToBlob($Modules)
{

	# Set AzStorageContext
	[String]$storageAccountKey = CreateStorageAcc $StorageAccountName $storageAccountRG
	if($null -ne $storageAccountKey)
	{
		$Context = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey
		try
		{
			CreateContainer $Context $storageContainerName
			Foreach($Module in $Modules)
			{
				$ModuleName = $Module
				$ModuleZipPath="C:\"+$tempFolder+"\"+$ModuleName+".zip"
				"Retrieving files from module: $ModuleName to save to container: $storageContainerName"
				Set-AzStorageBlobContent -File $ModuleZipPath -Container $storageContainerName -Context $Context	
			}
		}
		catch
		{
			Write-Error -Message "Unable to store custom modules, error while creating and transfering modules to temprory storage account. Error Message: $($Error[0].Exception.Message)"
		}

	}
	else
	{
		Write-Error "Unable to create a new temprory storage account for transfer of modules, please ensure you have appropriate permissions for the subscription- $SourceSubscriptionId "
	}



}

Function RemoveStorageAcc($StorageAccountName, $StorageAccountRG, $SubscriptionId)
{
	Set-Context($SubscriptionId)
	Remove-AzStorageAccount -ResourceGroupName $StorageAccountRG  -Name $StorageAccountName
}

#setting context
Function Set-Context($SubscriptionId)
{
	try
	{
		Set-AzContext -SubscriptionId $SubscriptionId
	}
	catch 
	{
		Write-Error -Message $_.Exception
		throw $_.Exception
	}
	Set-AzContext -SubscriptionId $SubscriptionId
}

#-----------------------------------------------------------------------------------------------------------------------
# Import Asset functions


Function Import-RunbooksFromOldAccount{
	$Runbooks = Get-AzAutomationRunbook -ResourceGroupName $SourceResourceGroup -AutomationAccountName $SourceAutomationAccountName
	if(!$?)
	{
		Write-Error "Failed to retrieve runbooks from automation account \' $SourceAutomationAccountName \'"
	}
	# $Runbooks | Export-AzAutomationRunbook -OutputFolder $LocalStoragePath -Force ;
	return $Runbooks
}

Function Import-VariablesFromOldAccount{
	$Variables=Get-AzAutomationVariable -AutomationAccountName $SourceAutomationAccountName -ResourceGroupName $SourceResourceGroup
	if(!$?)
	{
		Write-Error "Failed to retrieve variables from automation account \' $SourceAutomationAccountName \'"
	}
	return $Variables
}

Function Import-CredentialsFromOldAccount{
	$Credentials=Get-AzAutomationCredential -ResourceGroupName $SourceResourceGroup -AutomationAccountName $SourceAutomationAccountName 
	if(!$?)
	{
		Write-Error "Failed to retrieve credentials from automation account \' $SourceAutomationAccountName \'"
	}
	return $Credentials
}

Function Import-CertificatesFromOldAccount
{
	$Certificates=Get-AzAutomationCertificate -ResourceGroupName $SourceResourceGroup -AutomationAccountName $SourceAutomationAccountName 
	if(!$?)
	{
		Write-Error "Failed to retrieve certificates from automation account \' $SourceAutomationAccountName \'"
	}
	return $Certificates
}

Function Import-ConnectionsFromOldAccount{
	$Connections=Get-AzAutomationConnection -ResourceGroupName $SourceResourceGroup -AutomationAccountName $SourceAutomationAccountName 
	if(!$?)
	{
		Write-Error "Failed to retrieve connections from automation account \' $SourceAutomationAccountName \'"
	}
	return $Connections
}

Function Import-PwshModulesFromOldAccount
{
	$AllModules= Get-AzAutomationModule -AutomationAccountName $SourceAutomationAccountName -ResourceGroupName $SourceResourceGroup 
	if(!$?)
	{
		Write-Error "Failed to retrieve modules from automation account ' $SourceAutomationAccountName '"
	}
	# $AllModules.name | Import-Module
	$ModulesRequired = $AllModules.name
	$Modules_Custom = Get-ChildItem -Path "C:\Modules\User\" | ?{$_.Attributes -eq "Directory"} | where Name -match $($ModulesRequired -join '|') 
	return $Modules_Custom
	
}

#-------------------------------------------------------------------------------------------------------------------------------------------


#Export Assets functions
Function Export-RunbooksToNewAccount($Runbooks)
{
	foreach($Runbook in $Runbooks)
	{
		[string]$TempName=$Runbook.Name+".*"
		$CurrentFilePaths=Get-ChildItem -Path $LocalStoragePath -Filter $TempName -Recurse | %{$_.FullName}
		[string]$CurrentRunbookType=$Runbook.RunbookType
		if($CurrentFilePaths -ne 0)
		{
			if($CurrentRunbookType[0]-eq'G')
			{
				if($CurrentRunbookType -eq "GraphPowerShell") {$CurrentRunbookType="GraphicalPowerShell"}
				else { $CurrentRunbookType="GraphicalPowerShellWorkflow"}
			}
			if($CurrentRunbookType -eq "PowerShell7")
			{
				$CurrentRunbookType="PowerShell"
			}
			Import-AzAutomationRunbook -Path $CurrentFilePaths -ResourceGroupName $DestinationResourceGroup -AutomationAccountName $DestinationAutomationAccountName -Type $CurrentRunbookType -Tags $Runbook.Tags -erroraction 'silentlycontinue';
					
		}
		else
		{
			Write-Error "Unable to find runbook named $Runbook.Name on the temporary storage - Reason: Issue with import of runbook $Runbook.Name from automation account $SourceAutomationAccountName"
		}

		# Publish-AzAutomationRunbook -AutomationAccountName $DestinationAutomationAccountName -Name $Runbook.Name -ResourceGroupName $DestinationResourceGroup;
	}
}

Function Export-VariablesToNewAccount($Variables)
{
	foreach($Variable in $Variables)
	{
		[string]$VariableName=$Variable.Name
		$VariableEncryption=$Variable.Encrypted
		$VariableValue=Get-AutomationVariable -Name $VariableName
		New-AzAutomationVariable -AutomationAccountName $DestinationAutomationAccountName -Name $VariableName -Value $VariableValue -ResourceGroupName $DestinationResourceGroup -Encrypted $VariableEncryption

	}
}

Function Export-CredentialsToNewAccount($Credentials)
{
	foreach($Credential in $Credentials)
	{
		$getCredential = Get-AutomationPSCredential -Name $Credential.Name
		New-AzAutomationCredential -AutomationAccountName $DestinationAutomationAccountName -Name $Credential.Name -Value $getCredential -ResourceGroupName $DestinationResourceGroup
	}
}

Function Export-ConnectionsToNewAccount($Connections)
{
	foreach($Connection in $Connections)
	{
		$ConnectionType=$Connection.ConnectionTypeName
		$ConnectionFieldValues
		$getConnection= Get-AutomationConnection $Connection.Name
		if($ConnectionType -eq "AzureClassicCertificate")
		{
			$SubscriptionName = $getConnection.SubscriptionName
			$SubscriptionId = $getConnection.SubscriptionId
			$ClassicRunAsAccountCertifcateAssetName = $getConnection.CertificateAssetName
			$ConnectionFieldValues = @{"SubscriptionName" = $SubscriptionName; "SubscriptionId" = $SubscriptionId; "CertificateAssetName" = $ClassicRunAsAccountCertifcateAssetName}
		}
		if($ConnectionType -eq "AzureServicePrincipal")
		{
			
			$Thumbprint = $getConnection.CertificateThumbprint
			$TenantId = $getConnection.TenantId
			$ApplicationId = $getConnection.ApplicationId
			$SubscriptionId = $getConnection.SubscriptionId
			$ConnectionFieldValues = @{"ApplicationId" = $ApplicationId; "TenantId" = $TenantId; "CertificateThumbprint" = $Thumbprint; "SubscriptionId" = $SubscriptionId}

		}

		if($ConnectionType -eq "Azure")
		{
			$ConnectionFieldValues = @{"AutomationCertificateName"=$getConnection.AutomationCertificateName;"SubscriptionID"=$getConnection.SubscriptionId}
		}

		New-AzAutomationConnection -Name $Connection.Name -ConnectionTypeName $ConnectionType  -ConnectionFieldValues $ConnectionFieldValues -ResourceGroupName $DestinationResourceGroup -AutomationAccountName $DestinationAutomationAccountName
	}
}

Function Export-CertificatesToNewAccount($Certificates)
{
	foreach($Certificate in $Certificates)
	{
		$CertificateName=$Certificate.Name
		$getCertificate=Get-AutomationCertificate -Name $CertificateName
		$ASNFormatCertificate=$getCertificate.GetRawCertData()
		[string]$Base64Certificate =[Convert]::ToBase64String($ASNFormatCertificate)
		$bearerToken = Get-AzCachedAccessToken
		if($null -ne $bearerToken)
		{
			$Headers = @{
				"Authorization" = "Bearer $bearerToken"
			}

			$url="https://management.azure.com/subscriptions/"+$DestinationSubscriptionId+"/resourceGroups/"+$DestinationResourceGroup+"/providers/Microsoft.Automation/automationAccounts/"+$DestinationAutomationAccountName+"/certificates/"+$CertificateName+"?api-version=2019-06-01"	
			$properties= @{
				"base64Value"= $Base64Certificate;
				"description"= $Certificate.description;
				"thumbprint"= $getCertificate.Thumbprint;
				"isExportable"= $Certificate.Exportable;
			}
			$Body = @{
				"name"= $CertificateName;
				"properties"= $properties 
			}
			$bodyjson=($Body| COnvertTo-Json)
			try
			{
				Invoke-RestMethod -Method "PUT" -Uri "$url" -Body $bodyjson -ContentType "application/json" -Headers $Headers
			}
			catch{
				Write-Error -Message "Unable to import cerficate ' $CertificateName ' to account $DestinationAutomationAccountName. Error Message: $($Error[0].Exception.Message)"
			}
			
		}
		else{
			Write-Error "Unable to retrieve the authentication token for the account $DestinationAutomationAccountName"
		}
	}

}

Function Export-PwshModulesToNewAccount($Modules)
{
	Foreach($Module in $Modules)
	{
		$ModuleName = $Module
		$BlobURL="https://"+$StorageAccountName+".blob.core.windows.net/"+$storageContainerName+"/"+$ModuleName+".zip"
		New-AzAutomationModule -AutomationAccountName $DestinationAutomationAccountName -Name $ModuleName -ContentLink $BlobURL -ResourceGroupName $DestinationResourceGroup
	}
}

#---------------------------------------------------------------------------------------------------------------------------------------------------
#Transfer function

Function TransferRunbooks
{
	Set-Context $SourceSubscriptionId
	$Runbooks = Import-RunbooksFromOldAccount
	Write-Output $Runbooks
	if($null -ne $Runbooks)
	{
		$Runbooks | Export-AzAutomationRunbook -OutputFolder $LocalStoragePath -Force  
		Set-Context $DestinationSubscriptionId
		Export-RunbooksToNewAccount $Runbooks
	}
	else
	{
		Write-Error "Unable to find any runbooks associated with the account name $SourceAutomationAccountName"
	}
}


Function TransferVariables
{
	Set-Context $SourceSubscriptionId
	$Variables = Import-VariablesFromOldAccount
	if($null -ne  $Variables)
	{
		Set-Context $DestinationSubscriptionId
		Export-VariablesToNewAccount $Variables
	}
	else
	{
		Write-Error "Unable to find any variables associated with the account name $SourceAutomationAccountName"
	}
}

Function TransferCredentials
{
	Set-Context $SourceSubscriptionId
	$Credentials= Import-CredentialsFromOldAccount
	if($null -ne $Credentials)
	{
		Set-Context $DestinationSubscriptionId
		Export-CredentialsToNewAccount $Credentials
	}
	else
	{
		Write-Error "Unable to find any credentials associated with the account name $SourceAutomationAccountName"
	}
}

Function TransferConnections
{
	Set-Context $SourceSubscriptionId
	$Connections=Import-ConnectionsFromOldAccount
	if($null -ne $Connections)
	{
		Set-Context $DestinationSubscriptionId
		Export-ConnectionsToNewAccount $Connections
	}
	else
	{
		Write-Error "Unable to find any connections associated with the account name $SourceAutomationAccountName"
	}

}

Function TransferCertificates
{
	Set-Context $SourceSubscriptionId
	$Certificates=Import-CertificatesFromOldAccount
	if($null -ne $Certificates)
	{
		Set-Context $DestinationSubscriptionId
		Export-CertificatesToNewAccount $Certificates 
	}
	else
	{
		Write-Error "Unable to find any certificates associated with the account name $SourceAutomationAccountName"
	}
}

Function TransferModules
{
	Set-AzContext -SubscriptionId $SourceSubscriptionId
	New-Item -Path "C:\$tempFolder" -ItemType Directory
	$modules=Import-PwshModulesFromOldAccount
	if($null -ne $modules)
	{
		StoreModules $modules
		SendToBlob $modules
		Set-AzContext -SubscriptionId $DestinationSubscriptionId
		try
		{
			Export-PwshModulesToNewAccount $modules
		}
		catch
		{
			Write-Error -Message "Unable to transfer modules to account $DestinationAutomationAccountName. Error Message: $($Error[0].Exception.Message)"
		}
		RemoveStorageAcc $storageAccountName $storageAccountRG $subscriptionId
	}
	else
	{
		Write-Error "Unable to find any powershell modules associated with the account name $SourceAutomationAccountName"
	}
}

# Start point for the script
if($SourceAutomationAcccountResourceId -ne $null)
{
	$parsedResourceID=ParseReourceID $SourceAutomationAcccountResourceId
	$SourceResourceGroup=$parsedResourceID[0]
	$SourceSubscriptionId=$parsedResourceID[1]
	$SourceAutomationAccountName=$parsedResourceID[2]
}

if($DestinationAutomationAcccountResourceId -ne $null)
{
	$parsedResourceID=ParseReourceID $DestinationAutomationAcccountResourceId
	$DestinationResourceGroup=$parsedResourceID[0]
	$DestinationSubscriptionId=$parsedResourceID[1]
	$DestinationAutomationAccountName=$parsedResourceID[2]
}

$LocalStoragePath= ".\"
$subscriptionId = $SourceSubscriptionId
$storageAccountRG = $SourceResourceGroup
$storageAccountName = "migrationacctemp1"
$storageContainerName = "migrationcontainertemp1"
$tempFolder="LocalTempFolder1"

if(CheckifInputIsValid($SourceAutomationAccountName) -and CheckifInputIsValid($SourceResourceGroup) -and CheckifInputIsValid($SourceSubscriptionId) -and CheckifInputIsValid($DestinationAutomationAccountName) -and CheckifInputIsValid($DestinationResourceGroup) -and CheckifInputIsValid($DestinationSubscriptionId))
{
	if((Test-IsGuid $SourceSubscriptionId) -and (Test-IsGuid $DestinationSubscriptionId))
	{
		foreach($assestType in $Types)
		{
			if($assestType -eq "Runbooks")
			{
				TransferRunbooks
			}
			elseif($assestType -eq "Variables")
			{
				TransferVariables
			}
			elseif($assestType -eq "Connections")
			{
				TransferConnections
			}
			elseif($assestType -eq "Credentials")
			{
				TransferCredentials
			}
			elseif($assestType -eq "Certificates")
			{
				TransferCertificates
			}
			elseif($assestType -eq "Modules")
			{
				TransferModules
			}
			else{
				Write-Error "Please enter a valid type as $assestType is not a valid option, acceptable options are: Certificates, Connections, Credentials, Modules, Runbooks, Variables"
			}

		}

	}
	else
	{
		Write-Error "Please enter valid Source and Destination subscription IDs"
	}
}
else
{
	Write-Error "Please enter valid Inputs(either Source and Destination Resource IDs or Source and Destination Subscription IDs, Resource Group names and Automation account names)"
}

	
