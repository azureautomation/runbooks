#!/usr/bin/env python3
"""
Imports python 3 packages from pypi.org
This Azure Automation runbook runs in Azure to import a package and its dependencies from pypi.org.
It requires the subscription id, resource group of the Automation account, Automation name, and package name as arguments.
Args:
    subscription_id (-s) - Subscription id of the Automation account
    resource_group (-g) - Resource group name of the Automation account
    automation_account (-a) - Automation account name
    module_name (-m) - Name of module to import from pypi.org
    version (-v) - Version of module to be imported.
    Imports module
    Example:
        import_python3package_from_pypi.py -s xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxx -g contosogroup -a contosoaccount -m pytz -v 1.0.0
Changelog:
    2020-12-29 AutomationTeam:
    -Import Python 3 package with dependencies
"""
import requests
import subprocess
import json
import sys
import pip
import os
import re
import shutil
import json
import time
import getopt
import re
from pkg_resources import packaging

#region Constants
PYPI_ENDPOINT = "https://pypi.org/simple"
FILENAME_PATTERN = "[\\w]+"
#endregion

def extract_and_compare_version(url, min_req_version):
    try:
        re.search('\d+(\.\d+)+', url).group(0)        
    except :
         print ("Failed to extract and compare version URL  %s min_req_versionor %s" % (url, min_req_version))

    extracted_ver = re.search('\d+(\.\d+)+', url).group(0)
    print ("Extracted version   %s min_req_versionor %s" % (extracted_ver, min_req_version))
    return packaging.version.parse(extracted_ver) >= packaging.version.parse(min_req_version)  
    

def resolve_download_url(packagename, version):
    response = requests.get("%s/%s" % (PYPI_ENDPOINT, packagename))
    print("response from Python lib server for ", packagename, " was ", response.content)
    urls = re.findall(r'href=[\'"]?([^\'" >]+)', str(response.content))
    for url in urls:
        if 'cp38-win_amd64.whl' in url and version in url:
            print ("Detected download uri %s for %s" % (url, packagename))
            return(url)
    for url in urls:
        if 'py3-none-any.whl' in url and version in url:
            print ("Detected download uri %s for %s" % (url, packagename))
            return(url)
    for url in urls:
        if 'abi3-win_amd64.whl' in url and 'cp36' in url and version in url:
            print ("Detected download uri %s for %s" % (url, packagename))
            return(url)        
    for url in urls:
        if 'cp38-win_amd64.whl' in url and extract_and_compare_version(url,version):
            print ("Detected download uri %s for %s" % (url, packagename))
            return(url)            
    for url in urls:
        if 'py3-none-any.whl' in url and extract_and_compare_version(url,version):
            print ("Detected download uri %s for %s" % (url, packagename))
            return(url)  
    print("Could not find WHL from PIPI for package %s and version %s" % (packagename, version))        

def get_msi_token():
    endPoint = os.getenv('IDENTITY_ENDPOINT')+"?resource=https://management.azure.com/" 
    identityHeader = os.getenv('IDENTITY_HEADER') 
    payload={} 
    headers = { 
    'X-IDENTITY-HEADER': identityHeader,
    'Metadata': 'True' 
    } 
    response = requests.request("GET", endPoint, headers=headers, data=payload) 
    return response.json()['access_token']

def send_webservice_import_module_request(packagename, download_uri_for_file):

    for attempt in range(6):
        request_url = "https://management.azure.com/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Automation/automationAccounts/%s/python3Packages/%s?api-version=2018-06-30" \
                    % (subscription_id, resource_group, automation_account, packagename)

        token = get_msi_token()
        requestbody = { 'properties': { 'description': 'uploaded via automation', 'contentLink': {'uri': "%s" % download_uri_for_file} } }
        headers = {'Content-Type' : 'application/json', 'Authorization' : 'Bearer %s' % token}
        r = requests.put(request_url, data=json.dumps(requestbody), headers=headers)
        if str(r.status_code) in ["429"]:
            print ("Download request ", request_url, "throttled - waiting 60 seconds")
            time.sleep(60)
        elif str(r.status_code) in ["200", "201"]:
            break
        else:
            raise Exception("Error importing package {0} into Automation account. Error code is {1}".format(packagename, str(r.status_code)))
    

def find_dependencies(dep_graph, dep_map):
    for child in dep_graph['install']:
        dep_module_name = child['metadata']['name']
        dep_module_version = child['metadata']['version']
        print("Adding module ", dep_module_name, " with version ", dep_module_version)
        dep_map.update({dep_module_name: dep_module_version})

subprocess.check_call([sys.executable, '-m', 'pip', 'install','--upgrade', 'pip', '--user'])

if __name__ == '__main__':
    if len(sys.argv) < 9:
        raise Exception("Requires Subscription id -s, Automation resource group name -g, account name -a, and module name -g as arguments. \
                        Example: -s xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxx -g contosogroup -a contosoaccount -m pytz -v version")

    # Process any arguments sent in
    subscription_id = None
    resource_group = None
    automation_account = None
    module_name = None
    version_name = None

    opts, args = getopt.getopt(sys.argv[1:], "s:g:a:m:v:")
    for o, i in opts:
        if o == '-s':
            subscription_id = i
        elif o == '-g':
            resource_group = i
        elif o == '-a':
            automation_account = i
        elif o == '-m':
            module_name = i
        elif o == '-v':
            version_name = i

    module_with_version = module_name + "==" + version_name
    subprocess.check_call([sys.executable, '-m', 'pip',  'install', '--dry-run', module_with_version, '-I', '--quiet', '--report', 'modules.json'])

    f = open('modules.json', 'rb')
    strJson = bytearray(f.read())
    dep_graph = json.loads(strJson)
    dep_map = {}
    find_dependencies(dep_graph,dep_map)
    # Import package with dependencies from pypi.org
    for module_name,version in dep_map.items():
        download_uri_for_file = resolve_download_url(module_name, version)
        send_webservice_import_module_request(module_name, download_uri_for_file)
