<#PSScriptInfo

.VERSION 1.1

.GUID e4d79ced-48c7-44e7-bdd5-1b9c48a725a3

.AUTHOR Azure Automation Team

.COMPANYNAME 
Microsoft

.COPYRIGHT 

.TAGS 
Azure Automation Visual Studio Team Services Source Control

.LICENSEURI 
https://raw.githubusercontent.com/azureautomation/runbooks/master/LICENSE

.PROJECTURI 
https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Sync-VSTS.ps1

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES

#>

<#
.SYNOPSIS 
    This Azure Automation runbook syncs runbook and configurations from VSTS source control. It requires that a 
    service hook be set up in VSTS to trigger this runbook when changes are made.

.DESCRIPTION
    This Azure Automation runbook syncs runbook and configurations from VSTS source control. It requires that a 
    service hook be set up in VSTS to trigger this runbook when changes are made. It can also be run without a
    service hook to force a synce of everything from VSTS folder.
    It requires that you have the RunAs account configured in the automation service.

    This enables continous integration with VSTS source control and an automation account.

.PARAMETER WebhookData
    Optional. This will contain the change that was made in VSTS and sent over to the runbook through a
    service hook call.

.PARAMETER ResourceGroup
    Required. The name of the resource group the automation account is in.

.PARAMETER AutomationAccountName
    Required. The name of the Automation account to sync all the runbooks and configurations to

.PARAMETER VSFolder
    Required. The name of the folder in VSTS where the runbooks and configurations exist.
    This should look like '$/ContosoDev/AutomationScriptsConfigurations'
  
.PARAMETER VSAccount
    Required. The name of the account in VSTS

.PARAMETER VSAccessTokenVariableName
    Required. The name of the Automation variable that holds the access token for access to the VSTS project.
    You can set this up by following http://www.visualstudio.com/en-us/integrate/get-started/auth/overview 

.EXAMPLE
    .\Sync-VSTS.ps1 -ResourceGroup Contoso -AutomationAccountName ContosoAccount -VSFolder '$/ContosoDev/AutomationScriptsConfigurations' -VSAccount "contosogroup" -VSAccessTokenVariableName "VSToken" -Verbose

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: April 18th, 2017  
#>
Param
(
    [Parameter(Mandatory=$false)]
    [Object]
    $WebhookData,

    [Parameter(Mandatory=$true)]
    [String] $ResourceGroup,

    [Parameter(Mandatory=$true)]
    [String] $AutomationAccountName,

    [Parameter(Mandatory=$true)]
    [String] $VSFolder,

    [Parameter(Mandatory=$true)]
    [String] $VSAccount,

    [Parameter(Mandatory=$true)]
    [String] $VSAccessTokenVariableName
)

Function Get-TFSBasicAuthHeader{
    Param(
        [string]
        $AccessToken,
        [string]
        $Account
        )

    # Set up authentication for use against the Visual Studio Online account
    # This needs to be enabled on your account - http://www.visualstudio.com/en-us/integrate/get-started/auth/overview 
    $VSAuthCredential = ':' + $AccessToken
    $VSAuth = [System.Text.Encoding]::UTF8.GetBytes($VSAuthCredential)
    $VSAuth = [System.Convert]::ToBase64String($VSAuth)
    @{Authorization=("Basic {0}" -f $VSAuth)}

}
Function Invoke-TFSGetRestMethod
{
    Param(
        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Username,

        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Password,

        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Account,

        [Parameter(ParameterSetName='UseConnectionObject', Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $Connection,

        [Parameter(Mandatory=$True)]  
        $URI,
        
        [Parameter(Mandatory=$false)]       
        [string]
        $QueryString
        )

    if ($Connection -eq $null) { $Connection = Set-ConnectionValues -UserName $Username -Password $Password -Account $Account }

    # Get the API verison to use for REST calls
    $APIVersion = GetAPIVersion
    $URI = $URI + $APIVersion
    $URI = $URI + $QueryString

    # Set up Basic authentication for use against the Visual Studio Online account
    # This needs to be enabled on your account - http://www.visualstudio.com/en-us/integrate/get-started/auth/overview 
    $headers = SetBasicAuthHeader -Username $Connection.Username -Password $Connection.Password -Account $Connection.Account 

    $Result = Invoke-RestMethod -Uri $URI -headers $headers -Method Get

 
    # Return array values to make them more PowerShell friendly
    if ($Result.value -ne $null) {$Result.value}
    else {$Result}
}

Function Invoke-TFSGetBatchRestMethod
{
    Param(
        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Username,

        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Password,

        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Account,

        [Parameter(ParameterSetName='UseConnectionObject', Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $Connection,

        [Parameter(Mandatory=$True)]  
        $URI,
        
        [Parameter(Mandatory=$false)]       
        [string]
        $QueryString
        )

    if ($Connection -eq $null) { $Connection = Set-ConnectionValues -UserName $Username -Password $Password -Account $Account }

    # Get the API verison to use for REST calls
    $APIVersion = GetAPIVersion
    $URI = $URI + $APIVersion
    $URI = $URI + $QueryString

    # Get only top 100
    $Top = 100
    $URI = $URI + '&$top=' + $Top
    
    # Set up Basic authentication for use against the Visual Studio Online account
    # This needs to be enabled on your account - http://www.visualstudio.com/en-us/integrate/get-started/auth/overview 
    $headers = SetBasicAuthHeader -Username $Connection.Username -Password $Connection.Password -Account $Connection.Account 

    $Result = Invoke-RestMethod -Uri $URI -headers $headers -Method Get

    # Check if there are more results than the $Top asked for
    if ($Result.count -eq $Top)
    {
        # Loop until there are no more results
        $Skip = 0
        Do
        {
            $Skip = $Skip + $Top
            $URISkip = $URI + '&$skip=' + $Skip
            $NextResult = Invoke-RestMethod -Uri $URISkip -headers $headers -Method Get
            if ($NextResult.value -ne $null) {$Result.value = $Result.value + $NextResult.value}
        } While ($NextResult.Count -ne 0)
    }
 
    # Return array values to make them more PowerShell friendly
    if ($Result.value -ne $null) {$Result.value}
    else {$Result}
}

Function Invoke-TFSPostRestMethod
{
    Param(
        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Username,

        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Password,

        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Account,

        [Parameter(ParameterSetName='UseConnectionObject', Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $Connection,

        [string]
        $URI,

        [string]
        $Body
        )

    # Use connection if specific values were set
    if ($Connection -eq $null) { $Connection = Set-ConnectionValues -UserName $Username -Password $Password -Account $Account }

    # Get the API verison to use for REST calls
    $APIVersion = GetAPIVersion
    $URI = $URI + $APIVersion

    
    # Set up authentication for use against the Visual Studio Online account
    # This needs to be enabled on your account - http://www.visualstudio.com/en-us/integrate/get-started/auth/overview 
    $headers = SetBasicAuthHeader -Username $Connection.Username -Password $Connection.Password -Account $Connection.Account 

    $Result = Invoke-RestMethod -Uri $URI -headers $headers -Method Post -Body $Body -ContentType "application/json"
   
    # Return array values to make them more PowerShell friendly
    if ($Result.value -ne $null) {$Result.value}
    else {$Result}
}

Function Get-TFSVersionFolder{
    [CmdletBinding(DefaultParameterSetName='UseConnectionObject')]
    param(
        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Username,

        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Password,

        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Account,

        [Parameter(ParameterSetName='UseConnectionObject', Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $Connection,

        [Parameter(Mandatory=$True)]
        [String]
        $VersionControlPath,

        [Parameter(Mandatory=$False)]
        [Switch]
        $Recurse
    )

    # Use connection if specific values were set
    if ($Connection -eq $null) { $Connection = Set-ConnectionValues -UserName $Username -Password $Password -Account $Account }

    $URI = "https://" + $Connection.Account + ".visualstudio.com/defaultcollection/_apis/tfvc/itemBatch"

    # Determine whether to recurse through the directory or just return the root folder
    $RecurseLevel = "onelevel"
    if ($Recurse.IsPresent)
    {
        $RecurseLevel = "full"
    }

    $PostBody = @"
{
  "itemDescriptors": [
    {
      "path": "$VersionControlPath",
      "recursionLevel": "$RecurseLevel"
    }
  ]
}
"@
    Invoke-TFSPostRestMethod -Connection $Connection -URI $URI -Body $PostBody

} 

 
Function Get-TFSVersionFile{
    [CmdletBinding(DefaultParameterSetName='UseConnectionObject')]
    param(
        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Username,

        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Password,

        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Account,

        [Parameter(ParameterSetName='UseConnectionObject', Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $Connection,

        [Parameter(Mandatory=$True)]
        [String]
        $VersionControlPath,

        [Parameter(Mandatory=$False)]
        [String]
        $LocalPath
    )

    # Set up a hashtable with the account and access token to make it easier to pass around.
    if ($Connection -eq $null) { $Connection = Set-ConnectionValues -UserName $Username -Password $Password -Account $Account }

    $URI = "https://" + $Connection.Account + ".visualstudio.com/defaultcollection/_apis/tfvc/items/$VersionControlPath"

    $Result = Invoke-TFSGetRestMethod -URI $URI -Connection $Connection

    # If local path is specified, create the file in that directory and return the full path
    if ($LocalPath)
    {
        $FileName = Split-Path $VersionControlPath -Leaf
        $Result | Set-Content -Encoding Default -Path (Join-Path $LocalPath $FileName) -Force
        Join-Path $LocalPath $FileName
    }
    else {$Result}
} 

Function Get-TFSChangeSet{
    [CmdletBinding(DefaultParameterSetName='UseConnectionObject')]
    param(
        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$False)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Username,

        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Password,

        [Parameter(ParameterSetName='SpecifyConnectionParameters', Position=0, Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Account,

        [Parameter(ParameterSetName='UseConnectionObject', Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $Connection,

        [Parameter(Mandatory=$True)]
        [String]
        $VersionControlPath,

        [Parameter(Mandatory=$True)]
        [String]
        $ChangeSetID
    )

    # Use connection if specific values were set
    if ($Connection -eq $null) { $Connection = Set-ConnectionValues -UserName $Username -Password $Password -Account $Account }

    $URI = "https://" + $Connection.Account + ".visualstudio.com/_apis/tfvc/changesets/" + $ChangeSetID + "/changes"

    Invoke-TFSGetBatchRestMethod -Connection $Connection -URI $URI

} 

Function SetBasicAuthHeader{
    Param(
        [string]
        $Username,
        [string]
        $Password,
        [string]
        $Account
        )

    if ([string]::IsNullOrEmpty($Username))
    {
        $VSAuthCredential =  ':' + $Password
    }
    else
    {
        $VSAuthCredential = $Username + ':' + $Password
    }
    # Set up authentication for use against the Visual Studio Online account
    # This needs to be enabled on your account - http://www.visualstudio.com/en-us/integrate/get-started/auth/overview 
    $VSAuth = [System.Text.Encoding]::UTF8.GetBytes($VSAuthCredential)
    $VSAuth = [System.Convert]::ToBase64String($VSAuth)
    @{Authorization=("Basic {0}" -f $VSAuth)}

}

Function Set-ConnectionValues
{
    Param(
        [string]
        $UserName,
        [string]
        $Password,
        [string]
        $Account
        )

        @{"UserName"=$UserName;"Password"=$Password;"Account"=$Account;}
}

# Get the API version to use against Visual Studio Online
Function GetAPIVersion{
    "?api-version=1.0"
}

try
    {
    # Authenticate to Azure so we can upload the runbooks
    $RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection"         

    Write-Verbose ("Logging in to Azure...")
    Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $RunAsConnection.TenantId `
        -ApplicationId $RunAsConnection.ApplicationId `
        -CertificateThumbprint $RunAsConnection.CertificateThumbprint | Write-Verbose 

    Select-AzureRmSubscription -SubscriptionId $RunAsConnection.SubscriptionID  | Write-Verbose 

 
    # Get the personal access token to access VSTS
    $AccessToken = Get-AutomationVariable -Name $VSAccessTokenVariableName
    if (!$AccessToken)
    {
        throw "Variable $VSAccessTokenVariableName not found. Create this secure variable that holds your access token"
    }

    $Connection = Set-ConnectionValues -Password $AccessToken -Account $VSAccount

    # Create temp folder to store VS PowerShell scripts we are going to import into automation account
    $PSFolderPath = Join-Path $env:temp  (new-guid).Guid
    New-Item -ItemType Directory -Path $PSFolderPath | Write-Verbose

    # If this was not triggered by VSTS then the webhookdata will be null so just sync everything from
    # the folder
    if ($WebhookData -eq $null)
    {
        $ChangedFiles = Get-TFSVersionFolder -Connection $Connection -VersionControlPath $VSFolder
        foreach ($File in $ChangedFiles)
        {
            if ($File.path -match ".ps1")
            {
                $PSPath = Get-TFSVersionFile -Connection $Connection -VersionControlPath $File.path -LocalPath $PSFolderPath
                Write-Output("Syncing " +  $File.path )
                $AST = [System.Management.Automation.Language.Parser]::ParseFile($PSPath, [ref]$null, [ref]$null);
                If ($AST.EndBlock -ne $null -and $AST.EndBlock.Extent.Text.ToLower().StartsWith("workflow"))
                {
                Write-Verbose "File is a PowerShell workflow"
                $AutomationScript = Import-AzureRmAutomationRunbook -Path $PSPath -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Type PowerShellWorkflow -Force -Published 
                }
                If ($AST.EndBlock -ne $null -and $AST.EndBlock.Extent.Text.ToLower().StartsWith("configuration"))
                {
                Write-Verbose "File is a configuration script"
                $AutomationScript = Import-AzureRmAutomationDscConfiguration -Path $PSPath -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Force -Published
                }
                If (!($AST.EndBlock -ne $null -and $AST.EndBlock.Extent.Text.ToLower().StartsWith("configuration") -or ($AST.EndBlock -ne $null -and $AST.EndBlock.Extent.Text.ToLower().StartsWith("workflow"))))
                {
                Write-Verbose "File is a powershell script"
                $AutomationScript = Import-AzureRmAutomationRunbook -Path $PSPath -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Type PowerShell -Force -Published 
                }
            }
        }
    }
    else
    {
        $WebhookBody = ConvertFrom-Json $WebhookData.RequestBody
        $ChangeSetID = $WebhookBody.resource.changesetId
        # Get the list of files
        $ChangedFiles = Get-TFSChangeSet -Connection $Connection -VersionControlPath $VSFolder -ChangeSetID $ChangeSetID
 
        # Upload / remove these runbooks or configurations to the automation account
        foreach ($File in $ChangedFiles)
        {
            if ($File.item.path -match ".ps1")
            {
                # Remove files that are deleted from VSTS
                if ($File.changeType -match "delete")
                {
                    $FileName = Split-Path $File.item.path -Leaf
                    $Name = $FileName.Substring(0,$FileName.LastIndexOf('.'))              
                    $Runbook = Get-AzureRmAutomationRunbook -Name $Name -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
                    if ($Runbook -ne $null)
                    {
                        Write-Output ("Removing runbook " + $Name)    
                        Remove-AzureRmAutomationRunbook -Name $Name -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Force
                    }
                    else
                    {
                        $Configuration = Get-AzureRmAutomationDscConfiguration -Name $Name -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
                        if ($Configuration -ne $null)
                        {
                            Write-Output ("Removing configuration " + $Name)  
                            Remove-AzureRmAutomationDscConfiguration -Name $Name -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Force
                        }
                    }
                }
                else
                {
                    # Download the file locally and then upload to the automation service
                    $PSPath = Get-TFSVersionFile -Connection $Connection -VersionControlPath $File.item.path -LocalPath $PSFolderPath
                    Write-Output("Syncing " +  $File.item.path)
                    $AST = [System.Management.Automation.Language.Parser]::ParseFile($PSPath, [ref]$null, [ref]$null);
                    If ($AST.EndBlock -ne $null -and $AST.EndBlock.Extent.Text.ToLower().StartsWith("workflow"))
                    {
                        Write-Verbose "File is a PowerShell workflow"
                        $AutomationScript = Import-AzureRmAutomationRunbook -Path $PSPath -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Type PowerShellWorkflow -Force -Published 
                    }
                    If ($AST.EndBlock -ne $null -and $AST.EndBlock.Extent.Text.ToLower().StartsWith("configuration"))
                    {
                        Write-Verbose "File is a configuration script"
                       $AutomationScript = Import-AzureRmAutomationDscConfiguration -Path $PSPath -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Force -Published
                    }
                    If (!($AST.EndBlock -ne $null -and $AST.EndBlock.Extent.Text.ToLower().StartsWith("configuration") -or ($AST.EndBlock -ne $null -and $AST.EndBlock.Extent.Text.ToLower().StartsWith("workflow"))))
                    {
                        Write-Verbose "File is a powershell script"
                        $AutomationScript = Import-AzureRmAutomationRunbook -Path $PSPath -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Type PowerShell -Force -Published 
                    }
                }
            }
        }
    }
}
catch
{
    throw $_
}
finally
{
    # Remove temp files
    if (Test-Path $PSFolderPath)
    {
        Remove-Item $PSFolderPath -Recurse -Force
    }
} 


