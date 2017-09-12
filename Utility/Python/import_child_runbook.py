#!/usr/bin/env python2
"""
Example showing how to download a runbook from an automation account so you can call it from a parent python script

You could publish the below code as a new python runbook (hello_world) and then call it with this sample.

#!/usr/bin/env python2

def hello(name):
    print name
"""

def download_file(resource_group, automation_account, runbook_name, runbook_type):
    """
    Downloads a runbook from the automation account to the cloud container

    """
    import os
    import sys
    import requests
    import automationassets

    # Return token based on Azure automation Runas connection
    def get_automation_runas_token(runas_connection):
        """ Returs a token that can be used to authenticate against Azure resources """
        from OpenSSL import crypto
        import adal

        # Get the Azure Automation RunAs service principal certificate
        cert = automationassets.get_automation_certificate("AzureRunAsCertificate")
        sp_cert = crypto.load_pkcs12(cert)
        pem_pkey = crypto.dump_privatekey(crypto.FILETYPE_PEM, sp_cert.get_privatekey())

        # Get run as connection information for the Azure Automation service principal
        application_id = runas_connection["ApplicationId"]
        thumbprint = runas_connection["CertificateThumbprint"]
        tenant_id = runas_connection["TenantId"]

        # Authenticate with service principal certificate
        resource = "https://management.core.windows.net/"
        authority_url = ("https://login.microsoftonline.com/" + tenant_id)
        context = adal.AuthenticationContext(authority_url)
        azure_credential = context.acquire_token_with_client_certificate(
            resource,
            application_id,
            pem_pkey,
            thumbprint)

        # Return the token
        return azure_credential.get('accessToken')

    # Authenticate to Azure using the Azure Automation RunAs service principal
    automation_runas_connection = automationassets.get_automation_connection("AzureRunAsConnection")
    access_token = get_automation_runas_token(automation_runas_connection)

    # Set what resources to act against
    subscription_id = str(automation_runas_connection["SubscriptionId"])

    # Set up URI to create a new automation job
    uri = ("https://management.azure.com/subscriptions/" + subscription_id
           + "/resourceGroups/" + resource_group
           + "/providers/Microsoft.Automation/automationAccounts/" + automation_account
           + "/runbooks/" + runbook_name + "/content?api-version=2015-10-31")


    # Make request to create new automation job
    headers = {"Authorization": 'Bearer ' + access_token}
    result = requests.get(uri, headers=headers)

    runbookfile = os.path.join(sys.path[0], runbook_name) + runbook_type

    with open(runbookfile, "w") as text_file:
        text_file.write(result.text)

# Specify the runbook to download
_AUTOMATION_RESOURCE_GROUP = "contoso"
_AUTOMATION_ACCOUNT = "contosodev"
_RUNBOOK_NAME = "hello_world"
_RUNBOOK_TYPE = ".py"

download_file(_AUTOMATION_RESOURCE_GROUP, _AUTOMATION_ACCOUNT, _RUNBOOK_NAME, _RUNBOOK_TYPE)

# Import child runbook and call some function
import child_runbook
child_runbook.hello("world")
