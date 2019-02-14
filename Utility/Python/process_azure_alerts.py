#!/usr/bin/env python2
"""
Processes a webhook sent from an Azure alert.

This Azure Automation sample runbook runs on Azure to process an alert sent
through a webhook. It converts the RequestBody into a Python object
by loading the json string sent in.

Changelog:
    2018-09-01 AutomationTeam:
    -initial script

"""
import sys
import json

# Read in all of the input from the webhook parameter
payload = ""
for index in range(len(sys.argv)):
    payload += str(sys.argv[index]).strip()

# Get the RequestBody so we can process it
start = payload.find("RequestBody:")
end = payload.find("RequestHeader:")
requestBody = payload[start+12:end-1]

# Parse body as json string and print out the Python ojbect
jsonBody = json.loads(str(requestBody))
print jsonBody