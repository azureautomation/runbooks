<#
.SYNOPSIS 
    This sample automation runbook is designed to be used in a watcher task that
    looks for new files in a directory. When a new file is found, it calls the action
    runbook associated with the watcher task.

.DESCRIPTION
    This sample automation runbook is designed to be used in a watcher task that
    looks for new files in a directory. When a new file is found, it calls the action
    runbook associated with the watcher task. It requires that a variable called "Watch-NewFileTimestamp"
    be created in the automaiton account that is used to hold the timestamp of the last file processed.

.PARAMETER FolderPath
    Required. The name of a folder that you wish to watch for new files.

.PARAMETER Extension
    Optional. The extension of files that you want to filter on. Default is *.*

.PARAMETER Recurse
    Optional. Determines whether to look for all files under all directories or just the specific
    folder. Default is the folder only.

.EXAMPLE
    .\Watch-NewFile -FolderPath c:\FinanceFiles

.EXAMPLE
    .\Watch-NewFile -FolderPath c:\FinanceFiles -Extension "*.csv" -Recurse $True

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: Nov 12th, 2017 
#>

Param
(
    [Parameter(Mandatory=$true)]
    $FolderPath,

    [Parameter(Mandatory=$false)]
    $Extension = "*.*",

    [Parameter(Mandatory=$false)]
    [boolean] $Recurse = $false 
)

$FolderWatcherWatermark = "Watch-NewFileTimestamp"
$FolderWatermark =  (Get-Date (Get-AutomationVariable -Name $FolderWatcherWatermark)).ToLocalTime()

if ($Recurse)
{    
    $Files = Get-ChildItem -Path $FolderPath -Filter $Extension -Recurse | Where-Object {$_.LastWriteTime -gt $FolderWatermark}
}
else 
{
    $Files = Get-ChildItem -Path $FolderPath -Filter $Extension | Where-Object {$_.LastWriteTime -gt $FolderWatermark}
}

# Iterate through any new files and trigger an action runbook
foreach ($File in $Files)
{
    # Set up values we want to send to the action runbook
    $Properties = @{}
    $Properties.FileName = $File.FullName
    $Properties.Length = $File.Length

    $Data = $Properties | ConvertTo-Json

    Invoke-AutomationWatcherAction -Message "Process new file..." -Data $Data
    
    # Update watermark using last modified so we only get new files
    Set-AutomationVariable -Name $FolderWatcherWatermark -Value (Get-Date $File.LastWriteTime).AddMilliseconds(1).ToLocalTime()
}

