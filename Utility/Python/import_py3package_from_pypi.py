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

import subprocess
import sys

# Install requests module
subprocess.check_call([sys.executable, '-m', 'pip', 'install', 'requests'])


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

# collecting acces_token using MSI
endPoint = os.getenv('IDENTITY_ENDPOINT')+"?resource=https://management.core.windows.net" 
identityHeader = os.getenv('IDENTITY_HEADER') 
payload={} 
headers = { 
  'X-IDENTITY-HEADER': identityHeader,
  'Metadata': 'True' 
}
response = requests.request("GET", endPoint, headers=headers, data=payload) 
response = json.loads(response.text)
token = response['access_token']


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

def send_webservice_import_module_request(packagename, download_uri_for_file):
    request_url = "https://management.azure.com/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Automation/automationAccounts/%s/python3Packages/%s?api-version=2018-06-30" \
                  % (subscription_id, resource_group, automation_account, packagename)

    requestbody = { 'properties': { 'description': 'uploaded via automation', 'contentLink': {'uri': "%s" % download_uri_for_file} } }
    headers = {'Content-Type' : 'application/json', 'Authorization' : 'Bearer %s' % token}
    r = requests.put(request_url, data=json.dumps(requestbody), headers=headers)
    if str(r.status_code) not in ["200", "201"]:
        raise Exception("Error importing package {0} into Automation account. Error code is {1}".format(packagename, str(r.status_code)))

def find_and_dependencies(packagename, version, dep_graph, dep_map):
    dep_map.update({packagename: version})
    for child in dep_graph:
        if child['package']['key'].casefold() == packagename.casefold():
            for dep in child['dependencies']:
                version = dep['installed_version'] 
                if version == '?' :
                    version = dep['required_version'][2:]
                    if "!" in version :
                        version = version .split('!')[0]
                find_and_dependencies(dep['package_name'],version,dep_graph, dep_map)  
                

subprocess.check_call([sys.executable, '-m', 'pip', 'install','pipdeptree'])

subprocess.check_call([sys.executable, '-m', 'pip', 'install','packaging'])


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
            subscription_id = i.replace('"', '').replace("'","")
        elif o == '-g':  
            resource_group = i.replace('"', '').replace("'","")
        elif o == '-a': 
            automation_account = i.replace('"', '').replace("'","")
        elif o == '-m': 
            module_name = i.replace('"', '').replace("'","")
        elif o == '-v':
            version_name = i.replace('"', '').replace("'","")    

    module_with_version = module_name + "==" + version_name
    # Install the given module first
    for i in (1,10):
        try:
            subprocess.check_call([sys.executable, '-m', 'pip', 'install', module_with_version])
            break
        except subprocess.CalledProcessError as e:
            continue 

    result = subprocess.run(
        [sys.executable, "-m", "pipdeptree","-j"], capture_output=True, text=True
    )
    dep_graph = json.loads(result.stdout)
    dep_map = {}
    find_and_dependencies(module_name,version_name,dep_graph,dep_map)
    # Import package with dependencies from pypi.org
    for module_name,version in dep_map.items():
        download_uri_for_file = resolve_download_url(module_name, version)
        send_webservice_import_module_request(module_name, download_uri_for_file)
        time.sleep(10)
