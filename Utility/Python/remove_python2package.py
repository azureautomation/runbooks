#!/usr/bin/env python2
"""
This Azure Automation runbook runs in Azure to remove a package from Azure Automation.
It requires the subscription id, resource group of the Automation account, Automation name, and package name as arguments.
Passing in * for the package name will remove all packages from the account.

Args:
    subscription_id (-s) - Subscription id of the Automation account
    resource_group (-g) - Resource group name of the Automation account
    automation_account (-a) - Automation account name
    module_name (-m) - Name of module delete. Use * to remove all packages

    Removes module pytz
    Example:
        remove_python2package.py -s xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxx -g contosogroup -a contosoaccount -m pytz

Changelog:
    2018-10-04 AutomationTeam:
    -initial script

"""
import requests
import sys
import json
import getopt

def get_automation_runas_token():
    """ Returs a token that can be used to authenticate against Azure resources """
    from OpenSSL import crypto
    import adal
    import automationassets

    # Get the Azure Automation RunAs service principal certificate
    cert = automationassets.get_automation_certificate("AzureRunAsCertificate")
    sp_cert = crypto.load_pkcs12(cert)
    pem_pkey = crypto.dump_privatekey(crypto.FILETYPE_PEM, sp_cert.get_privatekey())

    # Get run as connection information for the Azure Automation service principal
    runas_connection = automationassets.get_automation_connection("AzureRunAsConnection")
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

def remove_package(packagename):
    # remove package from Azure Automation account
    request_url = "https://management.azure.com/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Automation/automationAccounts/%s/python2Packages/%s?api-version=2018-06-30" \
                  % (subscription_id, resource_group, automation_account, packagename)

    headers = {'Content-Type' : 'application/json', 'Authorization' : "Bearer %s" % token}
    package_info = requests.get(request_url, headers=headers).json()
    if len(package_info) > 2:
        print "Removing {0} from Automation account.".format(str(package_info['name']))
        response_request = requests.delete(request_url,headers=headers)
        if str(response_request.status_code) not in ["200", "201"]:
            raise Exception("Error removing package {0} from Automation account. Error code is {1}".format(packagename, str(response_request.status_code)))
    else:
        print "Package {0} was not found in Automation account {1}".format(packagename, json.dumps(package_info))


def get_all_packages():
    # get all automation packages in the account. Returns dictionary of packages
    request_url = "https://management.azure.com/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Automation/automationAccounts/%s/python2Packages?api-version=2018-06-30" \
                  % (subscription_id, resource_group, automation_account)

    headers = {'Content-Type' : 'application/json', 'Authorization' : "Bearer %s" % token}
    package_info = requests.get(request_url, headers=headers).json()
    return package_info 

if __name__ == '__main__':
    if len(sys.argv) < 9:
        raise Exception("Requires Subscription id -s, Automation resource group name -g, account name -a, and module name -g as arguments. Passing * for module name removes all modules. \
                        Example: -s xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxx -g contosogroup -a contosoaccount -m pytz ")

    # Process any arguments sent in
    subscription_id = None
    resource_group = None
    automation_account = None
    module_name = None

    opts, args = getopt.getopt(sys.argv[1:], "s:g:a:m:")
    for o, i in opts:
        if o == '-s':  
            subscription_id = i
        elif o == '-g':  
            resource_group = i
        elif o == '-a': 
            automation_account = i
        elif o == '-m': 
            module_name = i

    # Set Run as token for this automation accounts service principal to be used to import the package into Automation account
    token = get_automation_runas_token()

    # Remove packages from Azure Automation
    if module_name == '*':
        print "Removing all packages from the automation account..."
        packages = get_all_packages()
        for package in packages['value']:
            remove_package(package['name'])
    else:
        remove_package(module_name)

    print "\nCompleted removing packages"