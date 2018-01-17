""" Tutorial to show how to authenticate against Azure service management resources """
#!/usr/bin/env python2
import tempfile
import os
import OpenSSL
import azure.servicemanagement
import automationassets

def get_certificate_file(classic_run_as_connection):
    """ Returns a certificate file to authenticate against Azure service management resources """
    cert = automationassets.get_automation_certificate(
        classic_run_as_connection["CertificateAssetName"])
    sp_cert = OpenSSL.crypto.load_pkcs12(cert)
    temp_pem_file = tempfile.NamedTemporaryFile(suffix='.pem', delete=False)
    temp_pem_file.write(OpenSSL.crypto.dump_privatekey(
        OpenSSL.crypto.FILETYPE_PEM, sp_cert.get_privatekey()))
    temp_pem_file.write(OpenSSL.crypto.dump_certificate(
        OpenSSL.crypto.FILETYPE_PEM, sp_cert.get_certificate()))
    temp_pem_file.close()
    return temp_pem_file

try:
    # get Azure classic run as connection
    automation_classic_run_as_connection = automationassets.get_automation_connection(
        "AzureClassicRunAsConnection")

    # get certificate from the service that is used for authentication
    pem_file = None
    pem_file = get_certificate_file(automation_classic_run_as_connection)

    # authenticate against the serivce management api
    service_management_client = azure.servicemanagement.ServiceManagementService(
        automation_classic_run_as_connection["SubscriptionId"], pem_file.name)

    # get list of hosted services and print out each service name
    hosted_services = service_management_client.list_hosted_services()
    for hosted_service in hosted_services:
        print hosted_service.service_name

finally:
    # remove temp pem file created
    if pem_file is not None:
        os.remove(pem_file.name)
