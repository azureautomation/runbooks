# Migrate Automation account from one region to another
This PowerShell script is for migration of Automation account assets from the account in primary region to the account in secondary region. This script migrates only Runbooks, Modules, Connections, Credentials, Certificates and Variables.
### Prerequisites:
		1. Ensure that the Automation account in the secondary region is created and available so that assets from primary region can be migrated to it.
		2. System Managed Identities should be enabled in the Automation account in the primary region.
		3. Ensure that Primary Automation account's Managed Identity has Contributor access with read and write permissions to the Automation account in secondary region. You can enable it by providing the necessary permissions in Secondary Automation account’s managed identities. Learn more
		4.This script requires access to Automation account assets in primary region. Hence, it should be executed as a runbook in that Automation account for successful migration.
