<#
.SYNOPSIS 
    This Azure Automation runbook looks up a user in Azure active direcotry and determines if their 
    password is about to expire. If it is, it can optionally send an email to the user. You need to 
    import the MSOnline module from the Automation module gallery. If no user is specified, all users
    are looked up.

.DESCRIPTION
    This Azure Automation runbook looks up a user in Azure active direcotry and determines if their 
    password is about to expire. If it is, it can optionally send an email to the user. You need to 
    import the MSOnline module from the Automation module gallery. If no user is specified, all users
    are looked up.

    It is required to set up a credential called AzureADCredential in the Automation assets store.
    This credential is used to authenticate against Azure AD to look up the user. You can pass
    in a different credential name if needed.

    If you are going to send an email to the user, a credential called O365Credential is required
    to be set up in the Automation assets store. This is the mail account that will send the email
    to the user. You can pass in a different credential name if needed.

.PARAMETER User
    Optional. This is the name of the Azure AD user to look up. Example. janedoe@contoso.com
    If no user is passed in, all users in AD will be looked up. 

.PARAMETER DaysUntilNotificationIsSent
    Optional. Default is 7 days before the users password is about to expire. If the password
    is about to expire before this date, an email reminder will be sent to the user.

.PARAMETER SendMail
    Optional. Default is false. Boolean value indicates whether to send a mail or not.

.PARAMETER ADCredentialName
    Optional. Default is AzureADCredential. Name of credential asset in the Automation service with access to Azure AD

.PARAMETER O365CredentialName
    Optional. Default is O365Credential. Name of the credential asset in the Automation service to send email from.

.EXAMPLE
    .\Send-Office365PasswordNotification.ps1 -User janedoe@contoso.com -DaysUntilNotificationIsSent 14 -SendMail $true

    AUTHOR: Automation Team
    LASTEDIT: October 15th, 2017  
#>
Param(
    [Parameter(Mandatory=$false)]
    [String] $User,

    [Parameter(Mandatory=$false)]
    [Int] $DaysUntilNotificationIsSent = 7,

    [Parameter(Mandatory=$false)]
    [Boolean] $SendMail = $false,

    [Parameter(Mandatory=$false)]
    [String] $ADCredentialName = "AzureADCredential",

    [Parameter(Mandatory=$false)]
    [String] $O365CredentialName = "O365Credential"
)

# Retrieve credential from Automation asset store and authenticate to Azure AD
$AzureADCredential = Get-AutomationPSCredential -Name $ADCredentialName
Connect-MsolService -Credential $AzureADCredential

# Get default domain to work against
$DefaultDomain = Get-MsolDomain | Where-Object {$_.IsDefault -eq $true} 

# Retrieve password policy
$PasswordPolicy = (Get-MsolPasswordPolicy -DomainName $DefaultDomain.Name).ValidityPeriod 

# If there isn't a policy set, then the default is 90 days
if ($PasswordPolicy -eq $null)
{
    $PasswordPolicy = New-TimeSpan -Days 90
}

if ([string]::IsNullOrEmpty($User))
{
    # Get all users in Azure AD
    $ADUsers = Get-MsolUser -All
}
else 
{
    # Get the user information for the passed in user.
    $ADUsers = Get-MsolUser -UserPrincipalName $User 
}

foreach ($ADUser in $ADUsers)
{
    # Identify when the password was last changed
    $LastChanged = $ADUser.LastPasswordChangeTimestamp

    # Get the days since the last time the password was changed.
    $DaysSinceLastChanged = New-TimeSpan -Start (Get-Date) -End $LastChanged

    # If the password was last changed before the password policy, then the password is expired
    if (-($DaysSinceLastChanged.Days) -ge $PasswordPolicy)
    {
        Write-Output ("Password has expired for " + $ADUser.SignInName)
        Write-Output ("Last changed on " + $LastChanged)
        if ($SendMail)
        {
            if ([string]::IsNullOrEmpty($ADUser.AlternateEmailAddresses))
            {
                Write-Error ("Alternative email address is not set... Cannot send email")
            }
            else
            {
                # Sending mail to alternative email address
                Write-Output ("Sending to alternative email address " + $ADUser.AlternateEmailAddresses)
                $OfficeCred = Get-AutomationPSCredential -Name $O365CredentialName
                Send-MailMessage -Credential $OfficeCred -SmtpServer smtp.office365.com -Port 587 `
                                -To $ADUser.AlternateEmailAddresses `
                                -Subject "Password has expired" `
                                -Body "Please reset your password." `
                                -From $OfficeCred.UserName `
                                -BodyAsHtml `
                                -UseSsl
            }
        }
    }
    else
    {
        # Find how many days left before the password should be changed.
        $DaysLeft = ($PasswordPolicy + $DaysSinceLastChanged.Days)
        # If the days left are less then the passed in nofication days write out user
        if ($DaysLeft -le $DaysUntilNotificationIsSent)
        {
            Write-Output ("Your password will expire in " + $DaysLeft + " days")
            Write-Output ("Email address is " + $ADUser.SignInName)
            # If mail option is enabled, send email
            if ($SendMail)
            {
                $OfficeCred = Get-AutomationPSCredential -Name $O365CredentialName
                $Body = "Please reset your password in the next " + $DaysLeft + " days."
                Send-MailMessage -Credential $OfficeCred -SmtpServer smtp.office365.com -Port 587 `
                                -To $ADUser.SignInName `
                                -Subject "Password will expire soon" `
                                -Body $Body `
                                -From $OfficeCred.UserName `
                                -BodyAsHtml `
                                -UseSsl
            }
        }
    }
}


