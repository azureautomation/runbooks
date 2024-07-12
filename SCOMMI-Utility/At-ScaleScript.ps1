<#
.SYNOPSIS
This script onboards multiple machines to SCOM managed instance at scale as monitored resource (SCOM MI agent). 
A user can provide a list of subscriptions Ids, and the script will onboard all the Azure machines present in them.
Another way to use the script is to provide the list of ARM resource Ids for each of the machines which a user wishes to onboard.
.DESCRIPTION
Pre-requisites:
1. The user needs Contributor permission on the subscription which they are trying to onboard.
2. The user needs to have Az.Accounts module in their environment where they wish to run this script.

This script onboards multiple machines (agents) to SCOM managed instance at scale. 
It fetches the list of eligible machines based on the query provided in the script. 
Then it onboards the machines to SCOM managed instance by creating monitored resource and installing agent extension on the machines.
The script also updates the tags of the machines with SCOM managed instance name.
How to use: Copy the file in your local environment and run the script in PowerShell as per the examples provided below.
Also, to enable verbose logging, add this line at the start of the script: $DebugPreference = 'Continue'
.Example
    1. To onboard all the machines in a list of subscriptions:
    .\At-ScaleScript.ps1 -scomManagedInstanceId "<SCOM MI Resource ID>" -tenantId "<Tenant ID>" -subscriptionIds "<subId 1>", "<subId 2>", "<subId 3>")
.Example
    2. To onboard specific machines based on the resource id:
    .\At-ScaleScript.ps1 -scomManagedInstanceId "<SCOM MI Resource ID>" -tenantId "<Tenant ID>" -vmResourceIds "<vmResourceId 1>", "<vmResourceId 2>", "<vmResourceId 3>")
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory=$true)]
    [string]
    $scomManagedInstanceId,

    [ValidateSet("AzureCloud", "AzureUSGovernment", "AzureChinaCloud")]
    [Parameter(Mandatory = $false, HelpMessage = "Cloud environment name. 'AzureCloud' by default")]
    [string]
    $env = "AzureCloud",

    [Parameter(Mandatory=$true)]
    [string]
    $tenantId,

    [string[]]
    [Parameter(Mandatory=$false)]
    $vmResourceIds,

    [string[]]
    [Parameter(Mandatory=$false)]
    $subscriptionIds
)

class VirtualMachine {
    [string] $Name
    [string] $ResourceId
    [string] $Location
    [PSObject] $Tags
    [PSObject] $Identity
    [string] $ComputerName
    [string] $DomainName
    [string] $ResourceType
}

class SCOMManagedInstance {
    [string] $Name
    [string] $ResourceId
    [string] $Location
    [string] $ManagementServerEndpoint
    [string] $DataPlaneEndpoint
    [string] $TenantId
}

function Get-VMAPIVersion {
    param (
        [string] $resourceType
    )

    if ($resourceType.ToLower() -eq "microsoft.compute/virtualmachines") {
        return "2023-03-01"
    }
    else {
        return "2022-12-17"
    }
}

function Refresh-AuthorizationHeader {
    $currentDateTime = Get-Date
    if (($currentDateTime.Subtract($lastRefreshDate).TotalSeconds -ge 1500)) {
        $accessToken = (Get-AzAccessToken).Token
        $global:headers = @{
            "Authorization" = "Bearer $accessToken"
        }
        $global:lastRefreshDate = $currentDateTime
    }
    return $global:headers
}

function Get-VMDetails {
    param (
        [string]$resourceId,
        [string]$resourceType
    )
    $apiVersion = Get-VMAPIVersion -resourceType $resourceType
    $requestUrl = "${armEndpoint}${resourceId}?api-version=${apiVersion}"

    Write-Debug "Fetching VM details for $resourceId"
    try {
        $headers = Refresh-AuthorizationHeader
        $vmResponse = Invoke-RestMethod -Method "GET" -Uri "$($requestUrl)" -ContentType "application/json" -Headers $headers

        if ($vmResponse) {
            if ([string]::IsNullOrEmpty($vmResponse.properties.osProfile.domain)) {
                $domainName = "Not Available"
            } else {
                $domainName = $vmResponse.properties.osProfile.domain
            }
            $virtualMachine = [VirtualMachine]@{
                Name = $vmResponse.name
                ResourceId = $resourceId
                Location = $vmResponse.location
                Tags = $vmResponse.tags
                Identity = $vmResponse.identity
                ComputerName = $vmResponse.properties.osProfile.computerName
                DomainName = $domainName
                ResourceType = $vmResponse.type
            }
            Write-Debug "VM details fetched successfully for $resourceId"
            return $virtualMachine
        } else { 
            throw "Encountered error while fetching VM details $resourceId : $response"
        }
    }
    catch {
        throw "Encountered error while fetching VM details $resourceId : $_"
    }  
}

function Delete-MonitoredResource {
    param (
        [PSObject] $monitoredResource
    )
    $resourceId = $monitoredResource.id
    $requestUrl = "${armEndpoint}${resourceId}?api-version=2023-07-07-preview"
    Write-Debug "Deleting monitored resource $($monitoredResource.id)"
    try {
        $headers = Refresh-AuthorizationHeader
        $response = Invoke-RestMethod -Method "DELETE" -Uri "$($requestUrl)" -ContentType "application/json" -Headers $headers
        if ($response) {
            Write-Debug "Monitored resource deleted successfully for $($monitoredResource.id)"
            return $response
        } else {
            throw "Encountered error while deleting monitored resource $($monitoredResource.id) : $response"
        }
    } catch {
        throw "Encountered error while deleting monitored resource $($monitoredResource.id) : $_"
    }
}

function Delete-AgentExtension {
    param (
        [VirtualMachine] $virtualMachine,
        [SCOMManagedInstance] $scommi
    )

    $apiVersion = Get-VMAPIVersion -resourceType $virtualMachine.ResourceType
    $resourceId = $virtualMachine.ResourceId
    $requestUrl = "${armEndpoint}${resourceId}/extensions/SCOMMI-Agent-Windows?api-version=${apiversion}"

    Write-Debug "Uninstallation agent extension on $($virtualMachine.ResourceId)"

    try {
        $headers = Refresh-AuthorizationHeader
        $response = Invoke-WebRequest -Uri "$($requestUrl)" -Method "DELETE" -ContentType "application/json" -Headers $headers

        if ($response -and $response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            $pollingURL = $response.Headers["azure-asyncoperation"]
            if ($pollingURL -eq $null -or $pollingURL -eq "") {
                throw "Agent extension uninstallation failed with error: Polling URL not found in response headers"
            }
        } else {
            throw "Agent extension uninstallation failed with error: $response"
        }

        Write-Debug "Agent extension uninstallation initiated on $($virtualMachine.ResourceId)"
        Start-Sleep -Seconds $pollingInterval
        $status = PollingAgentInstallationStatus -pollingURL $pollingURL
        Write-Debug "Agent extension uninstallation status on $($virtualMachine.ResourceId) : $status"
        return $status
    } catch {
        throw "Agent extension uninstall initiation failed with error: $_"
    }
}

function Offboard-MonitoredResource {
    param (
        [VirtualMachine] $virtualMachine,
        [SCOMManagedInstance] $scommi,
        [PSObject] $agent
    )
    $status = "succeeded"
    if ([string]::IsNullOrEmpty($agent.properties.computerName)) {
        return $status
    }
    else {
        $computerName = ""
        if ($agent.properties.resourceAdditionalProperties -ne $null -and [string]::IsNullOrEmpty($agent.properties.resourceAdditionalProperties.FQDN) -eq $false) {
            $computerName = $agent.properties.resourceAdditionalProperties.FQDN
        }
        elseif ($agent.properties.domainName -eq $null -or [string]::IsNullOrEmpty($agent.properties.domainName) -or $agent.properties.domainName.ToLower() -eq "not available" -or $agent.properties.domainName.ToLower() -eq "na" -or $agent.properties.domainName.ToLower() -eq "notavailable") {
            $computerName = $agent.properties.computerName
        }
        else {
            $computerName = "$($agent.properties.computerName).$($agent.properties.domainName)"
        }
        
        $requestPayload = @{
            computerName = $computerName
            resourceId = $virtualMachine.ResourceId
        } | ConvertTo-Json

        $scommiResourceId = $scommi.ResourceId

        $requestUrl = "${armEndpoint}${scommiResourceId}/offboardMonitoredResource?api-version=2023-07-07-preview"
        Write-Debug "Offboarding the monitored resource $($virtualMachine.ResourceId) from SCOM managed instance $scommiResourceId"
        try {
            $headers = Refresh-AuthorizationHeader
            $response = Invoke-WebRequest -Method "POST" -Uri "$($requestUrl)" -Body $requestPayload -ContentType "application/json" -Headers $headers
            if ($response -and $response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                $pollingURL = $response.Headers["azure-asyncoperation"]
                if ($pollingURL -eq $null -or $pollingURL -eq "") {
                    throw "Agent offboarding failed with error: Polling URL not found in response headers"
                }
            }
            else {
                throw "Agent offboarding failed with error: $response"
            }
            Write-Debug "Agent offboarding initiated on $($virtualMachine.ResourceId)"
            Start-Sleep -Seconds $pollingInterval
            $status = PollingAgentInstallationStatus -pollingURL $pollingURL
            Write-Debug "Agent offboarding status on $($virtualMachine.ResourceId) : $status"
            return $status
        } catch {
            throw "Encountered error while initiating agent offboarding for $($virtualMachine.ResourceId) : $_"
        }
    }
}

function Create-MonitoredResource {
    param (
        [VirtualMachine] $virtualMachine,
        [SCOMManagedInstance] $scommi
    )
    
    $requestPayload = @{
        properties = @{
            resourceId = $virtualMachine.ResourceId
            resourceLocation = $virtualMachine.Location
            computerName = $virtualMachine.ComputerName
            domainName = $virtualMachine.DomainName
        }
    } | ConvertTo-Json
    $monitoredResourceName = (New-Guid).ToString()
    $scomResourceId = $scommi.ResourceId
    $requestUri = "${armEndpoint}${scomResourceId}/monitoredResources/${monitoredResourceName}?api-version=2023-07-07-preview"

    Write-Debug "Creating monitored resource for $($virtualMachine.ResourceId)"

    try {
        $headers = Refresh-AuthorizationHeader
        $response = Invoke-RestMethod -Uri "$($requestUri)" -Method "PUT" -Body $requestPayload -ContentType "application/json" -Headers $headers
        if ($response) {
            Write-Debug "Monitored resource created successfully for $($virtualMachine.ResourceId)"
            return $response
        } else {
            throw "Monitored resource API call failed with error: $response"
        }
    } catch {
        throw "Monitored resource API call failed with error: $_"
    }
}

function ValidateAndEnableSystemIdentity {
    param (
        [VirtualMachine] $virtualMachine
    )
    
    if ($virtualMachine.Identity -eq $null -or $virtualMachine.Identity.type -eq $null -or $virtualMachine.Identity.type -eq "" -or $virtualMachine.Identity.type -eq "UserAssigned") {
        $requestContent = @{
            identity = @{
                type = "SystemAssigned"
            }
        }
        if ($virtualMachine.Identity.type -eq "UserAssigned") {
            $requestContent = @{
                identity = @{
                    type = "SystemAssigned, UserAssigned" 
                }
            }
        }
        try {
            Write-Debug "Enabling system assigned identity for $($virtualMachine.ResourceId)"
            $vmUrl = $virtualMachine.resourceId
            $headers = Refresh-AuthorizationHeader
            $response = Invoke-RestMethod -Uri "${armEndpoint}${vmUrl}?api-version=2018-06-01" -Method Patch -Body ($requestContent | ConvertTo-Json) -ContentType "application/json" -Headers $headers
            if ($response) {
                Write-Debug "System assigned identity enabled successfully for $($virtualMachine.ResourceId)"
                return $response
            } else {
                throw "Encountered error while enabling system assigned identity for $vmUrl : $response"
            }
        } catch {
            throw "Encountered error while enabling system assigned identity for $vmUrl : $_"
        }
    } else {
        Write-Debug "System assigned identity already enabled for $($virtualMachine.ResourceId)"
    }
}

function Get-AzureSCOMManagedInstance {
    param (
        [string] $scommiResourceId
    )

    $requestUrl = "${armEndpoint}${scommiResourceId}?api-version=2023-07-07-preview"
    Write-Debug "Fetching SCOM managed instance details for $scommiResourceId"
    try {
        $headers = Refresh-AuthorizationHeader
        $scommiResponse = Invoke-RestMethod -Method "GET" -Uri "$($requestUrl)" -ContentType "application/json" -Headers $headers
        if ($scommiResponse) {
            $location = $scommiResponse.location
            $scommi = [SCOMManagedInstance]@{
                Name = $scommiResponse.name
                ResourceId = $scommiResourceId
                Location = $scommiResponse.location
                ManagementServerEndpoint = $scommiResponse.properties.gmsaDetails.dnsName
                DataPlaneEndpoint = "https://$location.workloadnexus.azure.com"
                TenantId = $scommiResponse.identity.tenantId
            }
            Write-Debug "SCOM managed instance details fetched successfully for $scommiResourceId"
            return $scommi
        } else {
            throw "Encountered error while fetching SCOM managed instance details $scommiResourceId : $scommiResponse"
        }
    } catch {
        throw "Encountered error while fetching SCOM managed instance details $scommiResourceId : $_"
    }    
}

function Install-AgentExtension {
    param (
        [VirtualMachine] $virtualMachine,
        [SCOMManagedInstance] $scommi
    )
    $payload = @{
        location = $virtualMachine.Location
        properties = @{
            publisher = "Microsoft.Azure.SCOMMI"
            type = "WindowsAgent"
            typeHandlerVersion = "1.0"
            autoUpgradeMinorVersion = "true"
            enableAutomaticUpgrade = "true"
            settings = @{
                ManagementGroupName = $scommi.Name
                ManagementServerEndpoint = $scommi.ManagementServerEndpoint
                DataPlaneEndpoint = $scommi.DataPlaneEndpoint
                ApplicationURL = "https://workloadnexus.azure.com"
                SCOMMIResourceId = $scommi.ResourceId
                SCOMMITenantId = $scommi.TenantId
            }
        }
    } | ConvertTo-Json

    $apiVersion = Get-VMAPIVersion -resourceType $virtualMachine.ResourceType
    $resourceId = $virtualMachine.ResourceId
    $requestUrl = "${armEndpoint}${resourceId}/extensions/SCOMMI-Agent-Windows?api-version=${apiversion}"

    Write-Debug "Installing agent extension on $($virtualMachine.ResourceId)"

    try {
        $headers = Refresh-AuthorizationHeader
        $response = Invoke-WebRequest -Uri "$($requestUrl)" -Method "PUT" -Body $payload -ContentType "application/json" -Headers $headers

        if ($response -and $response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            $pollingURL = $response.Headers["azure-asyncoperation"]
            if ($pollingURL -eq $null -or $pollingURL -eq "") {
                throw "Agent extension installation failed with error: Polling URL not found in response headers"
            }
        } else {
            throw "Agent extension installation failed with error: $response"
        }

        Write-Debug "Agent extension initiated on $($virtualMachine.ResourceId)"
        Start-Sleep -Seconds $pollingInterval
        $status = PollingAgentInstallationStatus -pollingURL $pollingURL
        Write-Debug "Agent extension installation status on $($virtualMachine.ResourceId) : $status"
        return $status
    } catch {
        throw "Agent extension install initiation failed with error: $_"
    }
}

function PollingAgentInstallationStatus {
    param (
        [string] $pollingURL
    )

    $status = ""
    $counter = 0
    while($counter -lt $maxCounter -and $status -eq "") {
        try {
            $headers = Refresh-AuthorizationHeader
            $response = Invoke-WebRequest -Uri "$($pollingURL)" -Method "GET" -ContentType "application/json" -Headers $headers
            if ($response -and $response.StatusCode -eq 200) {
                $responseObj = $response.Content | ConvertFrom-Json
                if ($responseObj.status.ToLower() -eq "succeeded") {
                    $status = "succeeded"
                    break
                }
                elseif ($responseObj.status.ToLower() -eq "failed") {
                    $status = "failed"
                    throw "Agent installation failed with error: $($response.Content)"
                }
                else {
                    Start-Sleep -Seconds $pollingInterval
                    $counter++
                }

            } else {
                return $null
            }
        } catch {
            throw "Encountered error while polling agent installation status: $_"
        }
    } 

    if ($status -ne "succeeded") {
        throw "Agent installation status not updated after polling for $maxCounter times. Please check the status manually."
    }
    return $status
}

function Update-VMTags {
    param (
        [VirtualMachine] $virtualMachine
    )

    try {
        Write-Debug "Updating VM tags for $($virtualMachine.ResourceId)"
        $tags = $virtualMachine.Tags
        $newTag = [PSCustomObject]@{
            "SCOM managed instance" = $scommi.Name
        }

        $newTag.PSObject.Properties | ForEach-Object {
            Add-Member -InputObject $tags -MemberType NoteProperty -Name $_.Name -Value $_.Value -Force
        }

        $payload = @{
            tags = $tags
            location = $virtualMachine.Location
        } | ConvertTo-Json

        $apiVersion = Get-VMAPIVersion -resourceType $virtualMachine.ResourceType
        $vmUrl = $virtualMachine.resourceId
        $headers = Refresh-AuthorizationHeader
        $response = Invoke-RestMethod -Uri "${armEndpoint}${vmUrl}?api-version=${apiVersion}" -Method Patch -Body $payload -ContentType "application/json" -Headers $headers
        if ($response) {
            Write-Debug "Tags updated successfully for $($virtualMachine.ResourceId)"
            return $response
        } else {
            throw "Encountered error while updating VM tags: $response"
        }
    } catch {
        throw "Encountered error while updating VM tags: $_"
    }
}

Function Get-ARMEndpoint
{
    param(
        [string]
        $env
    )

    switch ($env)
    {
        "AzureCloud" { return "https://management.azure.com" }
        "AzureChinaCloud" { return "https://management.chinacloudapi.cn" }
        "AzureUSGovernment" { return "https://management.usgovcloudapi.net" }
        default { throw "$($env) is not a valid cloud environment." }
    }
}

function Get-EligibleMachines { 

    if ($vmResourceIds -ne $null -and $vmResourceIds.Length -gt 0 -and $subscriptionIds -eq $null) {
        return $vmResourceIds
    }

    try {
        $payload = @{
            subscriptions = $subscriptionIds
            query = "resources | where type in~ ('microsoft.compute/virtualmachines', 'microsoft.hybridcompute/machines')| where name contains 'sfvm' | project id, IDL=tolower(id), location, name, properties, extendedProperties=properties.extended, identity, type | join kind=leftouter ( resources | where type in~ ('microsoft.compute/virtualmachines/extensions', 'microsoft.hybridcompute/machines/extensions') | where properties.type == 'GatewayServer' or properties.type == 'GatewayServer.Test' or properties.type == 'WindowsAgent' | parse tolower(id) with vmId'/extensions'* | project extensionType = properties.type, vmIDL=tolower(vmId) ) on `$left.IDL == `$right.vmIDL | where extensionType  == '' | where tolower(properties.status) == 'connected' or extendedProperties.instanceView.powerState.displayStatus == 'VM running' "
            options = @{
                "`$top" = 5000
                "`$skip" = 0
            }
        } | ConvertTo-Json


        $requestUrl = "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01"
        $headers = Refresh-AuthorizationHeader
        $response = Invoke-RestMethod -Uri "$($requestUrl)" -Method "POST" -Body $payload -ContentType "application/json" -Headers $headers
        if ($response) {
            Write-Host "Total eligible machines: $($response.count)"
            if ($response.count -eq 0 -or $response.data -eq $null) {
                throw "No eligible machines found"
            }

            $vmData = $response.data
            $virtualMachinesResourceIds = [System.Collections.ArrayList]::new()
            foreach ($resource in $vmData) {
                $resourceId = $resource.id
                $virtualMachinesResourceIds.Add($resourceId) | Out-Null
            }
            return $virtualMachinesResourceIds
        }
        else {
            throw "Encountered error while fetching eligible machines: $response"
        }
    }
    catch {
        throw "Encountered error while fetching eligible machines: $_"
    }
}

function Controller {
    param (
        [string] $scomManagedInstanceId,
        [string[]] $vmResourceIds
    )

    $success = 0
    $failure = 0

    $totalMachines = $vmResourceIds.Length

    Write-Host "Total machines to be onboarded: $totalMachines"

    $scommi = Get-AzureSCOMManagedInstance -scommiResourceId $scomManagedInstanceId

    foreach ($vmResourceId in $vmResourceIds) {
        try {
            Write-Host "Onboarding machine $vmResourceId"
            $status = OnboardMachine -vmResourceId $vmResourceId -scommi $scommi
            if ($status -eq "succeeded") {
                $success++
                Write-Host "$vmResourceId onboarded successfully"
            }
            else {
                $failure++
                Write-Error "$vmResourceId onboarding failed. Details: $status"
            }
        }
        catch {
            $failure++
            Write-Error "$vmResourceId onboarding failed. Details: $_"
        }
        
    }

    Write-Host "Total machines onboarded successfully: $success"
    if ($failure -gt 0)
    {
        Write-Host "Total machines failed to onboard: $failure"
    }
}

function Get-ResourceType {
    param (
        [string] $resourceId
    )
    if ($resourceId -like "*Microsoft.Compute/virtualMachines*" ) {
        return "microsoft.compute/virtualmachines"
    }
    else {
        return "microsoft.hybridcompute/machines"
    }
}

function OnboardMachine {
    param (
        [string] $vmResourceId,
        [SCOMManagedInstance] $scommi
    )
    $monitoredResourceCreated = $false
    try {
        $resourceType = Get-ResourceType -resourceId $vmResourceId
        $virtualMachine = Get-VMDetails -resourceId $vmResourceId -resourceType $resourceType

        ValidateAndEnableSystemIdentity -virtualMachine $virtualMachine
        $monitoredResource = Create-MonitoredResource -virtualMachine $virtualMachine -scommi $scommi
        $monitoredResourceCreated = $true
        $status = Install-AgentExtension -virtualMachine $virtualMachine -scommi $scommi
        try {
            Update-VMTags -virtualMachine $virtualMachine
        }
        catch {
            Write-Debug "Agent onboarding succeeded but encountered error while updating VM tags for ${vmResourceId} : $_"
        }
        return $status
    }
    catch {
        $errorMessage = "Encountered error while onboarding machine $vmResourceId : $_"
        throw $errorMessage
    }
}
$maxCounter = 30
$pollingInterval = 60
$armEndpoint = Get-ARMEndpoint -env $env

Connect-AzAccount -Environment $env -Tenant $tenantId -ErrorAction Stop > $null

$global:lastRefreshDate = Get-Date
$accessToken = (Get-AzAccessToken).Token
$global:headers = @{
    "Authorization" = "Bearer $accessToken"
}

$virtualMachinesResourceIds = Get-EligibleMachines
Controller -scomManagedInstanceId $scomManagedInstanceId -vmResourceIds $virtualMachinesResourceIds
