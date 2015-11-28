<#
.SYNOPSIS 
    Sets up the connection to an Azure subscription

.DESCRIPTION
    WARNING: This runbook is deprecated. Please use OrgID credential auth to connect to Azure, instead of
	certificate auth using this runbook. You can learn more about using credential auth with Azure here:
	http://aka.ms/Sspv1l
	
	This runbook sets up a connection to an Azure subscription.
    Requirements: 
        1. Automation Certificate Asset containing the management certificate loaded to Azure 
        2. Automation Connection Asset containing the subscription id and the name of the certificate 
           setting in Automation Assets 


.PARAMETER AzureConnectionName
    Name of the Azure connection setting that was created in the Automation service.
    This connection setting contains the subscription id and the name of the certificate setting that 
    holds the management certificate.

.EXAMPLE
    Connect-Azure -AzureConnectionName "Visual Studio Ultimate with MSDN"

.NOTES
    AUTHOR: System Center Automation Team
    LASTEDIT: Aug 14, 2014 
#>

workflow Connect-Azure
{
    Param
    (   
        [Parameter(Mandatory=$true)]
        [String]
        $AzureConnectionName       
    )

	Write-Warning -Message "WARNING: This runbook is deprecated. Please use OrgID credential auth to connect to Azure, instead of certificate auth using this runbook. You can learn more about using credential auth with Azure here: http://aka.ms/Sspv1l"
    
    # Get the Azure connection asset that is stored in the Auotmation service based on the name that was passed into the runbook 
    $AzureConn = Get-AutomationConnection -Name $AzureConnectionName
    if ($AzureConn -eq $null)
    {
        throw "Could not retrieve '$AzureConnectionName' connection asset. Check that you created this first in the Automation service."
    }

    # Get the Azure management certificate that is used to connect to this subscription
    $Certificate = Get-AutomationCertificate -Name $AzureConn.AutomationCertificateName
    if ($Certificate -eq $null)
    {
        throw "Could not retrieve '$AzureConn.AutomationCertificateName' certificate asset. Check that you created this first in the Automation service."
    }

    # Set the Azure subscription configuration
    Set-AzureSubscription -SubscriptionName $AzureConnectionName -SubscriptionId $AzureConn.SubscriptionID -Certificate $Certificate
}