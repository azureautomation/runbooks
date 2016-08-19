
<#
.SYNOPSIS 
     Creates a report on job and runbook activity over the past X days and optionally emails it.

.DESCRIPTION
    This runbook creates a report on jobs and runbook modifications over the past X days.
    The report can be in HTML or text format and can be sent via email.  You may want to
    set this runbook to run on a recurring schedule (for example, daily).

    Requirements:
       1. Credential asset that contains an Azure AD credential with administrative access 
          to the Azure subscription. For more info see http://aka.ms/runbookauthor/authentication
       2. Variable asset with the Azure Subscription name
       3. Variable asset with the Automation Account name
       4. Credential asset that contains the PowerShell credential for the email SMTP service
       5. Configure SMTP email properties below

.PARAMETER NumberOfDaysForReport
    An integer to indicate the time period of the report in the number of days before now.
    The default is 1 day.

.PARAMETER OutputHTML
    A boolean to indicate if the report should be formatted as HTML.
    The default is to format the report as HTML.

.PARAMETER SendReportByEmail
    A boolean to indicate if the report should be sent by email.
    The default is to send the report by email.

.EXAMPLE
    Create-AutomationReport `
        -NumberOfDaysForReport 7 `
        -OutputHTML $true `
        -SendReportByEmail $true

.NOTES
    AUTHOR: System Center Automation Team
    LASTEDIT: January 16, 2015
#>

workflow Create-AutomationReport
{   
    param
    (
        [Parameter (Mandatory=$false)]
        [int] $NumberOfDaysForReport = 1,
        
        [Parameter (Mandatory=$false)]
        [bool] $OutputHTML = $true,
        
        [Parameter (Mandatory=$false)]
        [bool] $SendReportByEmail = $true
    )
    
    # Get Automation assets
    # IMPORTANT: The assets must be created before running this runbook.
    $AzureSubscriptionName = Get-AutomationVariable -Name 'AzureSubscriptionName'
    $AutomationAccountName = Get-AutomationVariable -Name 'AutomationAccountName'
	$AzureOrgIdCredential = Get-AutomationPSCredential -Name 'AzureOrgIdCredential'
    if ($SendReportByEmail) {$EmailCredential = Get-AutomationPSCredential -Name 'LiveEmailCredential'}
    
    # Initialize variables
    $Out = ""
    $DateTimeNow = Get-Date
    $DateTimeStart = InlineScript{($using:DateTimeNow).AddDays(-$using:NumberOfDaysForReport)}
    
    # Set email parameters if sending report by email
    if ($SendReportByEmail)
    {
        $EmailInfo = @{"ToAddress"="you@yours.com";`
                        "FromAddress"="me@mine.com";`
                        "SmtpServer"="smtp.abcd.com";`
                        "SmtpPort"=587;`
                        "UseSsl"=$true}
    }

    # Connect to Azure so cmdlets will work and select the subscription to use
    Add-AzureAccount -Credential $AzureOrgIdCredential | Write-Verbose
    Select-AzureSubscription -SubscriptionName $AzureSubscriptionName | Write-Verbose

    # Get the subscription and automation account info
    $SubscriptionInfo = Get-AzureSubscription
    $AccountInfo = Get-AzureAutomationAccount -Name $AutomationAccountName
    
    # Get the jobs and runbooks in the time period
    $Jobs = Get-AzureAutomationJob -AutomationAccountName $AutomationAccountName -StartTime $DateTimeStart
    $Runbooks = Get-AzureAutomationRunbook -AutomationAccountName $AutomationAccountName

    # Adjust the status of jobs that were completed but with errors
    foreach ($Job in $Jobs)
    {
        if ($Job.Status -eq "Completed")
        {
            # See if the job has anything written to the error stream
            $errors = Get-AzureAutomationJobOutput `
                            -Id $Job.Id `
                            -AutomationAccountName $AutomationAccountName `
                            -Stream Error
            if ($errors) {$e='yes'} else {$e='no'}
            Add-Member -InputObject $Job -NotePropertyName 'HasErrors' -NotePropertyValue $e
        }
    }

    # Checkpoint (so jobs and runbooks do not get retrieved again if the runbook is suspended and resumed)
    Checkpoint-Workflow

    # =======================================================================================
    # Create the Report Output (call a function for each section of the report)
    # =======================================================================================

    if ($OutputHTML) { $Out += Write-HTMLReportBegin }

    $Out += Report-ReportParameters `
        -DateTimeStart $DateTimeStart `
        -DateTimeNow $DateTimeNow `
        -AzureSubscriptionInfo $SubscriptionInfo `
        -AutomationAccountInfo $AccountInfo `
        -OutputHTML $OutputHTML
    
    $Out += Report-RunbooksWithJobs `
                -Jobs $Jobs `
                -OutputHTML $OutputHTML
            
    $Out += Report-Jobs `
                -Jobs $Jobs `
                -OutputHTML $OutputHTML
    
    $Out += Report-JobsWithActionableStatus `
                -Jobs $Jobs `
                -OutputHTML $OutputHTML

    $Out += Report-ModifiedRunbooks `
                -Runbooks $Runbooks `
                -OutputHTML $OutputHTML `
                -DateTimeStart $DateTimeStart

    $Out += Report-ScheduledRunbooks `
                -Runbooks $Runbooks `
                -OutputHTML $OutputHTML `

    if ($OutputHTML) { $Out += Write-HTMLReportEnd }


    if ($SendReportByEmail)
    {        
        # Send report email, but checkpoint first so that in case of email failure can resume and try again
        Checkpoint-Workflow
        Send-ReportEmail `
                    -Body $Out `
                    -OutputHTML $OutputHTML `
                    -EmailCredential $EmailCredential `
                    -DateTimeStart $DateTimeStart `
                    -DateTimeNow $DateTimeNow `
                    -AutomationAccountName $AutomationAccountName `
                    -EmailInfo $EmailInfo
    }
        
    # Write the output
    Write-Output $Out

    # -----------------
    # FUNCTIONS
    # -----------------

    # =======================================================================================
    # Write-HTMLReportBegin
    #   Write out the CSS styles and initial elements for the HTML-formatted report
    # =======================================================================================
    function Write-HTMLReportBegin
    {
@"
<style type='text/css'>
.AAReport {
background-color: #snow;
font-family:Calibri;
color:black;
padding-bottom: 50px;
}
.AAReportHeader {
background-color: #ADCDEA;
}
.AAReportBody {
}
.AAReportH1 {
font-weight:lighter;
}
.AAReportH2 {
color: rgb(46,116,181);
font-weight:lighter;
padding-top: 2em;
}
.AAReportH3 {
color: red;
font-weight:lighter;
padding-top: 0.7em;
}
.AAReportTable {
border-collapse: collapse;
}
.AAReportTable th, .AAReportTable td {
padding: 10px;
border: 0;
font-family:Calibri;
}
.AAReportTable th {
background-color: whitesmoke;
font-weight:bolder;
}
.AAReportTable td {
border-bottom: 1px solid lightgray;
}
#AAReportTableReportInfo td {
color: rgb(31,77,120);
border: 0;
padding: 5px;
}
.AAReportTextAlert {
color: red;
}
</style>

<div class="AAReport">
<div class="AAReportHeader">&nbsp;</div>
<div class="AAReportBody">
"@
    } # end function

    # =======================================================================================
    # Write-HTMLReportEnd
    #   Write out the closing elements for the HTML-formatted report
    # =======================================================================================
    function Write-HTMLReportEnd
    {
        "</div>"
        "</div>"
    } # end function

    # =======================================================================================
    # Report-ReportParameters
    #   Display time period, subscription, and account used for the report
    # =======================================================================================
    function Report-ReportParameters
    {
        param
        (
            [Parameter (Mandatory=$true)]            
            [datetime] $DateTimeStart,

            [Parameter (Mandatory=$true)]            
            [datetime] $DateTimeNow,

            [Parameter (Mandatory=$true)]            
            [object] $AzureSubscriptionInfo,

            [Parameter (Mandatory=$true)]            
            [object] $AutomationAccountInfo,

            [Parameter (Mandatory=$true)]            
            [bool] $OutputHTML
        )
        
        $DateTimeStartFormatFull = (Get-Date $DateTimeStart -Format 'yyyy-M-d h:m:s')
        $DateTimeNowFormatFull = (Get-Date $DateTimeNow -Format 'yyyy-M-d h:m:s')

        if ($OutputHTML)
        {
            "<h1 class='AAReportH1'>AZURE AUTOMATION REPORT</h1>"
            "<table  class='AAReportTable' id='AAReportTableReportInfo'>"
            "<tr><td><b>Time Period (UTC)</b></td><td>" + $DateTimeStartFormatFull + "&nbsp;&nbsp;to&nbsp;&nbsp;" + $DateTimeNowFormatFull + "</td></tr>"
            "<tr><td><b>Subscription Name</b></td><td>" + $AzureSubscriptionInfo.SubscriptionName + "</td></tr>"
            "<tr><td><b>Subscription ID</b></td><td>" + $AzureSubscriptionInfo.SubscriptionId + "</td></tr>"
            "<tr><td><b>Automation Plan</b></td><td>" + $AutomationAccountInfo.Plan + "</td></tr>"
            "<tr><td><b>Automation Account</b></td><td>" + $AutomationAccountInfo.AutomationAccountName + "</td></tr>"
            "<tr><td><b>Location</b></td><td>" + $AutomationAccountInfo.Location + "</td></tr>"
            "</table>"
        }
        else
        {
            "`n------------------------------"
            "`nAZURE AUTOMATION REPORT"
            "`nTime Period (UTC): " + $DateTimeStartFormatFull + " to " + $DateTimeNowFormatFull
            "`nSubscription Name: " + $AzureSubscriptionInfo.SubscriptionName
            "`nSubscription ID: " + $AzureSubscriptionInfo.SubscriptionId
            "`nAutomation Plan: " + $AutomationAccountInfo.Plan
            "`nAutomation Account: " + $AutomationAccountInfo.AutomationAccountName
            "`nLocation: " + $AutomationAccountInfo.Location
        }
    } # end function

    # =======================================================================================
    # Report-RunbooksWithJobs
    #   Runbooks with jobs in time period
    #   Total job count plus for each runbook the count of jobs in each state
    # =======================================================================================
    function Report-RunbooksWithJobs
    {
        param
        (
            [Parameter (Mandatory=$true)]            
            [object] $Jobs,

            [Parameter (Mandatory=$true)]            
            [bool] $OutputHTML
        )
        
        if ($OutputHTML)
        {
            "<h2 class='AAReportH2'>RUNBOOKS WITH JOBS</h2>"
        }
        else
        {
            "`n`n------------------------------"
            "`nRUNBOOKS WITH JOBS"
        }
    
        $HtRunbookJobs = @{}
        foreach ($Job in $Jobs)
        {
            $RbName = $Job.RunbookName
            $Status = $Job.Status
            
            # For Completed jobs, determine if there were errors
            if (($Status -eq "Completed") -and ($Job.HasErrors -eq 'yes'))
            {
                $Status = "Completed With Errors"
            }
            
            # Create a key in the hashtable for each runbook with a value of an empty hashtable
            if (-not $HtRunbookJobs.ContainsKey($RbName))
            {
                $HtRunbookJobs.Add($RbName,@{})
            }
            
            # Record the sum of each status for each runbook
            $HtTemp = $HtRunbookJobs[$RbName]
            if (-not $HtTemp.ContainsKey($Status))
            {   
                $HtTemp.Add($Status,1)
            }
            else
            {
                $HtTemp[$Status] += 1
            }
            $HtRunbookJobs[$RbName] = $HtTemp
        }
        
        # Write out the data sorted by runbook name
        if ($Jobs -and $OutputHTML)
        {
            "<table class='AAReportTable'><tr>"
            "<th>Runbook Name</th>"
            "<th>Failed</th>"
            "<th>Suspended</th>"
            "<th>Stopped</th>"
            "<th>Completed</th>"
            "<th>Completed With Errors</th>"
            "<th>Queued</th>"
            "<th>Running</th>"
            "</tr>"
        }
        $H = $HtRunbookJobs.GetEnumerator() | Sort-Object Name
        foreach($Item in $H)
        {
            # Runbook Name
            if ($OutputHTML)
            {
                "<tr><td>" + $Item.Key + "</td>"
            }
            else
            {            
                "`n`n" + $Item.Key
            }
            
            # Count of jobs in each state
            $HtData = $Item.Value.GetEnumerator() | Sort-Object Name
            if ($OutputHTML)
            {
                # Failed
                "<td align='center' class='AAReportTextAlert'>"
                foreach($I in $HtData) {if ($I.Key -eq "Failed") {$I.Value}}
                "</td>"
                    
                # Suspended
                "<td align='center' class='AAReportTextAlert'>"
                foreach($I in $HtData) {if ($I.Key -eq "Suspended") {$I.Value}}
                "</td>"
                    
                # Stopped
                "<td align='center' class='AAReportTextAlert'>"
                foreach($I in $HtData) {if ($I.Key -eq "Stopped") {$I.Value}}
                "</td>"
                    
                # Completed
                "<td align='center'>"
                foreach($I in $HtData) {if ($I.Key -eq "Completed") {$I.Value}}
                "</td>"
                    
                # Completed with Errors
                "<td align='center' class='AAReportTextAlert'>"
                foreach($I in $HtData) {if ($I.Key -eq "Completed With Errors") {$I.Value}}
                "</td>"
                    
                # Queued
                "<td align='center' class='AAReportTextAlert'>"
                foreach($I in $HtData) {if ($I.Key -eq "Queued") {$I.Value}}
                "</td>"
                    
                # Running
                "<td align='center'>"
                foreach($I in $HtData) {if ($I.Key -eq "Running") {$I.Value}}
                "</td>"
          
                "</tr>"
            }            
            else
            {
                # Plain text output
                foreach($I in $HtData)
                {                    
                    "`n" + $I.Key + ": " + $I.Value                    
                }
            }
        }
        if ($Jobs -and $OutputHTML)
        {
            "</table>"
        }
    } # end function

    # =======================================================================================
    # Report-Jobs
    #   Total job count
    #   Count of jobs with each status
    # =======================================================================================
    function Report-Jobs
    {
        param
        (
            [Parameter (Mandatory=$true)]            
            [object] $Jobs,

            [Parameter (Mandatory=$true)]            
            [bool] $OutputHTML
        )
        
        # total job count
        $JobCount = 0
        if ($Jobs)
        {
            if ($Jobs.Count)
            {
                # array of job objects
                $JobCount = $Jobs.Count
            }
            else
            {
                # single job object
                $JobCount = 1
            }
        }
        
        # count of jobs in each state
        $HtStateCount = @{}
        foreach ($Job in $Jobs)
        {
            $Status = $Job.Status
            if (($Status -eq "Completed") -and ($Job.HasErrors -eq 'yes'))
            {
                $Status = "Completed With Errors"
            }
     
            if (-not $HtStateCount.ContainsKey($Status))
            {   
                $HtStateCount.Add($Status,0)
            }
            $HtStateCount[$Status] += 1
        }
        
        # output        
        if ($OutputHTML)
        {
            "<h2 class='AAReportH2'>JOBS</h2>"
            if ($JobCount -ge 1)
            {
                "<table class='AAReportTable'>"
                "<tr><th align='center'>Total</th>"
            }
            else
            {
                "<div>No jobs during time period</div>"
            }
        }
        else
        {
            "`n`n------------------------------"
            "`nJOBS"
            if ($JobCount -ge 1)
            {            
                "`nTotal Jobs: " + $JobCount
            }
            else
            {
                "`nNo jobs during time period"
            }
        }
        
        $H = $HtStateCount.GetEnumerator() | Sort-Object Name
        $Values = @()
        foreach($I in $H)
        {
            if ($OutputHTML)
            {                
                "<th style='text-align:center'>" + $I.Key + "</th>"
                $Values += $I.Value
            }
            else
            {                
                "`n" + $I.Key + ": " + $I.Value
            }
        }
        
        if (($JobCount -ge 1) -and $OutputHTML) 
        {
            "</tr><tr><td style='text-align:center'>" + $JobCount + "</td>"
            $ArrAlertStates = @("Failed","Suspended","Stopped","Queued","Completed With Errors")
            foreach ($Val in $Values)
            {
                "<td style='text-align:center' "
                if ($ArrAlertStates -contains $Val) {" class='AAReportTextAlert'"}
                ">" + $Val + "</td>"
            }
            "</tr></table>"
        }
    }

    # =======================================================================================
    # Report-JobsWithActionableStatus
    #   Jobs with status of interest - Failed, Suspended, Stopped, Queued, Completed with Errors
    # =======================================================================================
    function Report-JobsWithActionableStatus
    {
        param
        (
            [Parameter (Mandatory=$true)]            
            [object] $Jobs,

            [Parameter (Mandatory=$true)]            
            [bool] $OutputHTML
        )
    
        $ArrStates = @("Failed","Suspended","Stopped","Queued","Completed With Errors")
        $HtStatus = @{}
        foreach ($Job in $Jobs)
        {
            $Status = $Job.Status
            if (($Status -eq "Completed") -and ($Job.HasErrors -eq 'yes'))
            {
                $Status = "Completed With Errors"
            }

            if ($ArrStates -contains $Status)
            {
                if (-not $HtStatus.ContainsKey($Status))
                {   
                    $HtStatus.Add($Status,@())
                }
                $HtStatus[$Status] += $Job
            }
        }
        
        # output
        $H = $HtStatus.GetEnumerator() | Sort-Object Name
        foreach($I in $H)
        {
            # write the status
            if ($OutputHTML)
            {
                "<h3 class='AAReportH3'>" + ($I.Key).ToUpper() + " JOBS</h3>"                
            }
            else
            {
                "`n`n------------------------------"
                "`n" + ($I.Key).ToUpper() + " JOBS"
            }

            # write details for each job in that status
            $arr = $I.Value | sort $_.RunbookName
            if ($OutputHTML) 
            {
                "<table class='AAReportTable'>"
                "<tr><th>Runbook Name</th><th>Job Id</th><th>Last Modified</th></tr>"
            }
            foreach($Job in $arr)
            {
                if ($OutputHTML)
                {
                    "<tr>"
                    "<td>" + $Job.RunbookName + "</td>"
                    "<td>" + $Job.Id + "</td>"
                    "<td>" + $Job.LastModifiedTime + "</td>"
                    "</tr>"
                }
                else
                {
                    "`n`nRunbook Name: " + $Job.RunbookName
                    "`nJob Id: " + $Job.Id
                    "`nLast Modified: " + $Job.LastModifiedTime
                }
            }
            if ($OutputHTML) 
            {
                "</table>"
            }
        }
    } # end function

    # =======================================================================================
    # Report-ModifiedRunbooks
    #   Runbooks modified in time period
    # =======================================================================================
    function Report-ModifiedRunbooks
    {
        param
        (
            [Parameter (Mandatory=$true)]            
            [object] $Runbooks,

            [Parameter (Mandatory=$true)]            
            [bool] $OutputHTML,

            [Parameter (Mandatory=$true)]            
            [datetime] $DateTimeStart
        )
        
        if ($OutputHTML)
        {
            "<h2 class='AAReportH2'>MODIFIED RUNBOOKS</h2>"
        }
        else
        {
            "`n`n------------------------------"
            "`nMODIFIED RUNBOOKS"
        }
        
        $Rbs = ($Runbooks) | Sort-Object LastModifiedTime -Descending
        $AtLeastOne = $false
        foreach ($Rb in $Rbs)
        {
            if ($Rb.LastModifiedTime -ge $DateTimeStart)
            {
                if (-not $AtLeastOne -and $OutputHTML)
                {
                    "<table class='AAReportTable'>"
                    "<tr>"
                    "<th>Runbook Name</th>"
                    "<th>State</th>"
                    "<th>Tags</th>"
                    "<th>Last Modified</th>"
                    "<th>Last Modified By</th>"
                    "</tr>"
                }

                $AtLeastOne = $true

                $RbState = "New"
                if ($Rb.PublishedRunbookVersionId)
                {
                    $RbState = "Published"
                    if ($Rb.DraftRunbookVersionId)
                    {
                        $RbState = "In Edit"
                    }
                }
                
                if ($OutputHTML)
                {
                    "<tr>"
                    "<td>" + $Rb.Name + "</td>"
                    "<td>" + $RbState + "</td>"
                    "<td>" + $Rb.Tags + "</td>"
                    "<td>" + $Rb.LastModifiedTime + "</td>"
                    "<td>" + $Rb.LastModifiedBy + "</td>"
                    "</tr>"
                }
                else
                {
                    "`n`nName: " + $Rb.Name
                    "`nState: " + $RbState
                    "`nTags: " + $Rb.Tags
                    "`nLast Modified: " + $Rb.LastModifiedTime
                    "`nLast Modified By: " + $Rb.LastModifiedBy
                }
            }
        }
        
        if ($OutputHTML)
        {
            if ($AtLeastOne)
            {
                "</table>"                
            }
            else
            {
                "<div>No runbooks modified during time period</div>"
            }
        }
        else
        {
            if (-not $AtLeastOne)
            {                
                "`nNo runbooks modified during time period"
            }
        }
    
    } # end function


    # =======================================================================================
    # Report-ScheduledRunbooks
    #   Runbooks scheduled in next time period
    # =======================================================================================
    function Report-ScheduledRunbooks
    {
        param
        (
            [Parameter (Mandatory=$true)]            
            [object] $Runbooks,

            [Parameter (Mandatory=$true)]            
            [bool] $OutputHTML
        )
        
        # TODO - implement the function details
               
    } # end function

    # =======================================================================================
    # Send-ReportEmail
    #   Send the report in an email
    # =======================================================================================
    function Send-ReportEmail
    {
        param
        (
            [Parameter (Mandatory=$true)]            
            [string] $Body,

            [Parameter (Mandatory=$true)]            
            [bool] $OutputHTML,

            [Parameter (Mandatory=$true)]            
            [PSCredential] $EmailCredential,

            [Parameter (Mandatory=$true)]            
            [datetime] $DateTimeStart,

            [Parameter (Mandatory=$true)]            
            [datetime] $DateTimeNow,
            
            [Parameter (Mandatory=$true)]            
            [string] $AutomationAccountName,
            
            [Parameter (Mandatory=$true)]            
            [object] $EmailInfo
        )

        $DateTimeNowFormatShort = (Get-Date $DateTimeNow -Format yyyy-M-d)
        $DateTimeStartFormatShort = (Get-Date $DateTimeStart -Format yyyy-M-d)

        Send-MailMessage `
            -to $EmailInfo.ToAddress `
            -from $EmailInfo.FromAddress `
            -subject "Automation Report for Account $AutomationAccountName - $DateTimeStartFormatShort to $DateTimeNowFormatShort" `
            -body $Body `
            -smtpserver $EmailInfo.SmtpServer `
            -port $EmailInfo.SmtpPort `
            -credential $EmailCredential `
            -usessl:$EmailInfo.UseSsl `
            -bodyashtml:$OutputHTML `
            -erroraction Stop

    } # end function

} # end workflow
