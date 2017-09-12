#!/usr/bin/env python2
"""
Example showing REST calls using Azure Automation RunAs account against Azure resources (automation runbook job)

You could publish the below code as a new python runbook (hello_world_python) and then start it with this sample.

#!/usr/bin/env python2
import getopt
import sys

opts, args = getopt.getopt(sys.argv[1:], "n:")
for o, a in opts:
    if o == '-n':
        name = a


print "Hello " + name

"""
import time
import uuid
import requests
import automationassets

# Automation resource group and account to start runbook job in
_AUTOMATION_RESOURCE_GROUP = "contoso"
_AUTOMATION_ACCOUNT = "contosodev"

# Set up required body values for a runbook.
# Make sure you have a hello_world_python runbook published in the automation account
# with an argument of -n
body = {
    "properties":
        {
            "runbook":
            {
                "name":"hello_world_python"
            },
            "parameters":
            {
                "[PARAMETER 1]":"-n",
                "[PARAMETER 2]":"world"
            }
        }
    }

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
job_id = str(uuid.uuid4())

# Set up URI to create a new automation job
uri = ("https://management.azure.com/subscriptions/" + subscription_id
       + "/resourceGroups/" + _AUTOMATION_RESOURCE_GROUP
       + "/providers/Microsoft.Automation/automationAccounts/" + _AUTOMATION_ACCOUNT
       + "/jobs/(" + job_id + ")?api-version=2015-10-31")


# Make request to create new automation job
headers = {"Authorization": 'Bearer ' + access_token}
json_output = requests.put(uri, json=body, headers=headers).json()

# Get results of the automation job
_RETRY = 360 # stop after 60 minutes (360 * 10 sleep seconds / 60 seconds in a minute)
_SLEEP_SECONDS = 10
status_counter = 0
while status_counter < _RETRY:
    status_counter = status_counter + 1
    job = requests.get(uri, headers=headers).json()
    status = job['properties']['status']
    if status == 'Completed' or status == 'Failed' or status == 'Suspended' or status == 'Stopped':
        break
    time.sleep(_SLEEP_SECONDS)

# if job did not complete in an hour, throw an exception
if status_counter == 360:
    raise StandardError("Job did not complete in 60 minutes.")

if job['properties']['status'] != 'Completed':
    raise StandardError("Job did not complete successfully.")

# Get output streams from the job
uri = ("https://management.azure.com/subscriptions/" + subscription_id
       + "/resourceGroups/" + _AUTOMATION_RESOURCE_GROUP
       + "/providers/Microsoft.Automation/automationAccounts/" + _AUTOMATION_ACCOUNT
       + "/jobs/" + job_id
       + "/streams?$filter=properties/streamType%20eq%20'Output'&api-version=2015-10-31")

job_streams = requests.get(uri, headers=headers).json()

# For each stream id, print out the text
for stream in job_streams['value']:
    uri = ("https://management.azure.com/subscriptions/" + subscription_id
           + "/resourceGroups/" + _AUTOMATION_RESOURCE_GROUP
           + "/providers/Microsoft.Automation/automationAccounts/" + _AUTOMATION_ACCOUNT
           + "/jobs/" + job_id
           + "/streams/" + stream['properties']['jobStreamId']
           + "?$filter=properties/streamType%20eq%20'Output'&api-version=2015-10-31")
    output_stream = requests.get(uri, headers=headers).json()
    print output_stream['properties']['streamText']
