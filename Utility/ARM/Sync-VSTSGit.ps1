<#PSScriptInfo

.VERSION 1.0

.GUID ff9ac18b-e2d9-4ce6-80c2-81ce8cfcc9da

.AUTHOR Azure Automation Team

.COMPANYNAME 
Microsoft

.COPYRIGHT 

.TAGS 
Azure Automation Visual Studio Team Services Git Source Control

.LICENSEURI 
https://raw.githubusercontent.com/azureautomation/runbooks/master/LICENSE

.PROJECTURI 
https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Sync-VSTSGit.ps1

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES

#>

<#
.SYNOPSIS 
    This Azure Automation runbook syncs runbook and configurations from VSTS Git source control. It requires that a 
    service hook be set up in VSTS to trigger this runbook when changes are made.

.DESCRIPTION
    This Azure Automation runbook syncs runbook and configurations from VSTS Git source control. It requires that a 
    service hook be set up in VSTS to trigger this runbook when changes are made. It can also be run without a
    service hook to force a synce of everything from VSTS folder.
    It requires that you have the RunAs account configured in the automation service.

    This enables continous integration with VSTS Git source control and an automation account.

.PARAMETER WebhookData
    Optional. This will contain the change that was made in VSTS and sent over to the runbook through a
    service hook call.

.PARAMETER ResourceGroup
    Required. The name of the resource group the automation account is in.

.PARAMETER AutomationAccountName
    Required. The name of the Automation account to sync all the runbooks and configurations to

.PARAMETER VSAccount
    Required. The name of the account in VSTS

.PARAMETER VSProject
    Required. The name of the project in VSTS where the runbooks and configurations exist.
  
.PARAMETER GitRepo
    Required. The name of the Git repository in VSTS where the runbooks and configurations exist.
  
.PARAMETER GitBranch
    Required. The name of the branch in the Git repository in VSTS where the runbooks and configurations exist.

.PARAMETER Folder
    Required. The name of the folder in VSTS where the runbooks and configurations exist.
    This should look like '/AutomationScriptsConfigurations' 

.PARAMETER VSAccessTokenVariableName
    Required. The name of the Automation variable that holds the access token for access to the VSTS project.
    You can set this up by following http://www.visualstudio.com/en-us/integrate/get-started/auth/overview 

.EXAMPLE
    .\Sync-VSTSGit.ps1 -ResourceGroup contoso -AutomationAccountName contosodev -VSAccount "contosogroup" -VSProject Finance -GitRepo "Marketing" -GitBranch "master" -Folder "/AutomationScriptsConfigurations" -VSAccessTokenVariableName VSToken -Verbose

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: Jan 26th, 2017  
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
    [String] $VSAccount,

    [Parameter(Mandatory=$true)]
    [String] $VSProject,

    [Parameter(Mandatory=$true)]
    [String] $GitRepo,

    [Parameter(Mandatory=$true)]
    [String] $GitBranch,

    [Parameter(Mandatory=$true)]
    [String] $Folder,

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

Function Get-TFSGitFolderItem{
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
        $Project,

        [Parameter(Mandatory=$True)]
        [String]
        $Repo,

        [Parameter(Mandatory=$True)]
        [String]
        $Folder,

        [Parameter(Mandatory=$True)]
        [String]
        $Branch,

        [Parameter(Mandatory=$False)]
        [Switch]
        $Recurse
    )

    # Use connection if specific values were set
    if ($Connection -eq $null) { $Connection = Set-ConnectionValues -UserName $Username -Password $Password -Account $Account }

    $RecurseLevel = "onelevel"
    if ($Recurse.IsPresent)
    {
        $RecurseLevel = "full"
    }

    $URI = "https://" + $Connection.Account + ".visualstudio.com/defaultcollection/_apis/git/$Project/repositories/$Repo/items"

    Invoke-TFSGetRestMethod -Connection $Connection -URI $URI -QueryString "&versionType=Branch&version=$Branch&scopePath=$Folder&recursionLevel=$RecurseLevel"
} 

 
Function Get-TFSGitFile{
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
        $Project,

        [Parameter(Mandatory=$True)]
        [String]
        $RepoID,

        [Parameter(Mandatory=$True)]
        [String]
        $BlobObjectID,

        [Parameter(Mandatory=$True)]
        [String]
        $Path,

        [Parameter(Mandatory=$False)]
        [String]
        $LocalPath
    )

    # Set up a hashtable with the account and access token to make it easier to pass around.
    if ($Connection -eq $null) { $Connection = Set-ConnectionValues -UserName $Username -Password $Password -Account $Account }

    $URI = "https://" + $Connection.Account + ".visualstudio.com/DefaultCollection/_apis/git/repositories/$RepoID/blobs/$BlobObjectID"
    $Result = Invoke-TFSGetRestMethod -Connection $Connection -URI $URI -QueryString "&scopePath=$Path"

    # If local path is specified, create the file in that directory and return the full path
    if ($LocalPath)
    {
        $FileName = Split-Path $Path -Leaf
        $Result | Set-Content -Encoding Default -Path (Join-Path $LocalPath $FileName) -Force
        Join-Path $LocalPath $FileName
    }
    else {$Result}
} 

Function Get-TFSGitChangeSet{
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
        $RepoID,

        [Parameter(Mandatory=$True)]
        [String]
        $Folder,

        [Parameter(Mandatory=$True)]
        [String]
        $ChangeSetID
    )

    # Use connection if specific values were set
    if ($Connection -eq $null) { $Connection = Set-ConnectionValues -UserName $Username -Password $Password -Account $Account }

    $URI = "https://" + $Connection.Account + ".visualstudio.com/_apis/git/repositories/$RepoID/commits/$ChangeSetID"

    Invoke-TFSGetRestMethod -Connection $Connection -URI $URI -QueryString "&changeCount=1000&scopePath=$Folder"

} 

Function Get-TFSGitRepo{
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
        $Project,

        [Parameter(Mandatory=$True)]
        [String]
        $Repo
    )

    # Use connection if specific values were set
    if ($Connection -eq $null) { $Connection = Set-ConnectionValues -UserName $Username -Password $Password -Account $Account }

    $URI = "https://" + $Connection.Account + ".visualstudio.com/_apis/tfvc/changesets/" + $ChangeSetID + "/changes"

    
    $URI = "https://" + $Connection.Account + ".visualstudio.com/DefaultCollection/$Project/_apis/git/repositories/$Repo"

    Invoke-TFSGetRestMethod -Connection $Connection -URI $URI

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

    $RepoInformation = Get-TFSGitRepo -Connection $Connection -Project $VSProject -Repo $GitRepo

    # Create temp folder to store VS PowerShell scripts we are going to import into automation account
    $PSFolderPath = Join-Path $env:temp  (new-guid).Guid
    New-Item -ItemType Directory -Path $PSFolderPath | Write-Verbose

    # If this was not triggered by VSTS then the webhookdata will be null so just sync everything from the folder
    if ($WebhookData -eq $null)
    {
        $ChangedFiles = Get-TFSGitFolderItem -Connection $Connection -Project $VSProject -Folder $Folder -Branch $GitBranch -Repo $GitRepo
        foreach ($File in $ChangedFiles)
        {
            if ($File.path -match ".ps1")
            {
                $PSPath = Get-TFSGitFile -Connection $Connection -Project $VSProject -RepoID $RepoInformation.id -BlobObjectID $File.objectID -Path $File.Path -LocalPath $PSFolderPath
                Write-Output("Syncing " +  $File.path )
                $AST = [System.Management.Automation.Language.Parser]::ParseFile($PSPath, [ref]$null, [ref]$null);
                If ($AST.EndBlock.Extent.Text.ToLower().StartsWith("workflow"))
                {
                Write-Verbose "File is a PowerShell workflow"
                $AutomationScript = Import-AzureRmAutomationRunbook -Path $PSPath -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Type PowerShellWorkflow -Force -Published 
                }
                If ($AST.EndBlock.Extent.Text.ToLower().StartsWith("configuration"))
                {
                Write-Verbose "File is a configuration script"
                $AutomationScript = Import-AzureRmAutomationDscConfiguration -Path $PSPath -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Force -Published
                }
                If (!($AST.EndBlock.Extent.Text.ToLower().StartsWith("configuration") -or ($AST.EndBlock.Extent.Text.ToLower().StartsWith("workflow"))))
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
        $ChangeSetID = $WebhookBody.resource.commits.commitid

        if ($WebhookBody.resource.repository.id -ne $RepoInformation.id)
        {
            throw ("Push commit from a repository " + $WebhookBody.resource.repository.name + " that is not specified in the runbook parameter. Check your service hooks in VSTS and your runbook parameters")
        }

        if ($WebhookBody.resource.refUpdates.name -ne "refs/heads/$GitBranch")
        {
            throw ("Push commit from branch " + $WebhookBody.resource.refUpdates.name + " that is not specified in the runbook parameter. Check your service hooks in VSTS and your runbook parameters")
        }

        # Get the list of files
        $ChangedFiles = Get-TFSGitChangeSet -Connection $Connection -RepoID $RepoInformation.id -ChangeSetID $ChangeSetID -Folder $Folder 
 
        # Upload / remove these runbooks or configurations to the automation account in they are in the specified folder
        foreach ($File in $ChangedFiles.changes)
        {
            if ($File.item.path -match ".ps1" -and $File.item.path.StartsWith($Folder))
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
                    $PSPath = Get-TFSGitFile -Connection $Connection -Project $VSProject -RepoID $RepoInformation.id -BlobObjectID $File.item.objectID -Path $File.item.Path -LocalPath $PSFolderPath
 
                    Write-Output("Syncing " +  $File.item.path)
                    $AST = [System.Management.Automation.Language.Parser]::ParseFile($PSPath, [ref]$null, [ref]$null);
                    If ($AST.EndBlock.Extent.Text.ToLower().StartsWith("workflow"))
                    {
                        Write-Verbose "File is a PowerShell workflow"
                        $AutomationScript = Import-AzureRmAutomationRunbook -Path $PSPath -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Type PowerShellWorkflow -Force -Published 
                    }
                    If ($AST.EndBlock.Extent.Text.ToLower().StartsWith("configuration"))
                    {
                        Write-Verbose "File is a configuration script"
                        $AutomationScript = Import-AzureRmAutomationDscConfiguration -Path $PSPath -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroup -Force -Published
                    }
                    If (!($AST.EndBlock.Extent.Text.ToLower().StartsWith("configuration") -or ($AST.EndBlock.Extent.Text.ToLower().StartsWith("workflow"))))
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

