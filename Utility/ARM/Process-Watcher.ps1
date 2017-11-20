<#
.SYNOPSIS 
    This sample automation runbook is designed to be used in a watcher task that takes action
    on data passed in from a watcher runbook.

.DESCRIPTION
    This sample automation runbook is designed to be used in a watcher task that takes action
    on data passed in from a watcher runbook. It is required to have a parameter called $EVENTDATA in
    watcher action runbooks to receive information from the watcher runbook.

.PARAMETER EVENTDATA
    Optional. Contains the information passed in from the watcher runbook.

.NOTES
    AUTHOR: Automation Team
    LASTEDIT: Nov 12th, 2017
#>

param(
    $EVENTDATA
)

Write-Output("Passed in data is " + ($EVENTDATA.EventProperties.Data | ConvertFrom-Json))
