
<#PSScriptInfo

.VERSION 1.0

.GUID 

.AUTHOR AzureAutomationTeam

.COMPANYNAME Microsoft

.COPYRIGHT 

.TAGS AzureAutomation Utility

.LICENSEURI 

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/Utility/Remove-ResourceGroups.ps1

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES

#>

#Requires -Module Azure
#Requires -Module AzureRM.Profile
#Requires -Module AzureRM.Resources

<# 
.SYNOPSIS 
  Connects to Azure and removes all resource groups which match the name filter

.DESCRIPTION 
  This runbook connects to Azure and removes all resource groups which match the name filter. 
  You can run across multiple subscriptions, delete all resource groups, or run in preview mode.
  Warning: This will delete all resources, including child resources in a group when preview mode is set to $false.

.PARAMETER NameFilter 
  Optional 
  Allows you to specify a name filter to limit the resource groups that you will KEEP or DELETE.
  Pass multiple name filters through a comma separated list.     
  The filter is not case sensitive and will match any resource group that contains the string.   
 
.PARAMETER PreviewMode 
  Optional with default of $true. 
  Execute the runbook to see which resource groups would be deleted but take no action.  

#> 

workflow Remove-ResourceGroups
{
    [OutputType([String])]

    param(
        [parameter(Mandatory = $false)] 
        [string] $NameFilter, 
	 	
        [parameter(Mandatory = $false)] 
        [bool] $PreviewMode = $true,

        [parameter(Mandatory = $false)]
        [string] $FromEmailAddress,

        [parameter(Mandatory = $false)]
        [string] $DestEmailAddress,
    
        [parameter(Mandatory = $false)]
        [sting] $SendGridToken  # To be converted to keyvault
    )

    $VerbosePreference = 'Continue'
	
    inlineScript {
        $NameFilter = $using:NameFilter
        $PreviewMode = $using:PreviewMode
        $PSPrivateMetadata = $using:PSPrivateMetadata

        $FromEmailAddress = $using:FromEmailAddress
        $DestEmailAddress = $using:DestEmailAddress
        $SendGridToken = $using:SendGridToken
		
        # Connect to Azure with RunAs account
        $conn = Get-AutomationConnection -Name "AzureRunAsConnection" 
        $null = Add-AzureRmAccount `
            -ServicePrincipal `
            -Tenant $conn.TenantId `
            -ApplicationId $conn.ApplicationId `
            -CertificateThumbprint $conn.CertificateThumbprint

        # Use the subscription that this Automation account is in
        $null = Select-AzureRmSubscription -SubscriptionId $conn.SubscriptionID 

        # Parse name filter list
        if ($NameFilter) { 
            $nameFilterList = $NameFilter.Split(',') 
            [regex]$nameFilterRegex = '(' + (($nameFilterList | foreach {[regex]::escape($_.ToLower())}) –join "|") + ')' 
        } 

        # Find the resource group that this Automation job is running in so that we can protect it from being removed
        if ([string]::IsNullOrEmpty($PSPrivateMetadata.JobId.Guid)) {
            throw ("This is not running from the Automation service, so could not retrieve the resource group for the Automation account in order to protect it from being removed.")
            exit
        }
        else {
            $resources = Get-AzureRmResource
            $automationResources = $resources | ? {$_.ResourceType -eq "Microsoft.Automation/automationAccounts"}
            foreach ($automation in $automationResources) {
                # Loop through each Automation account to find this job
                $job = Get-AzureRmAutomationJob -ResourceGroupName $automation.ResourceGroupName -AutomationAccountName $automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
                if (!([string]::IsNullOrEmpty($job))) {
                    $thisResourceGroupName = $job.ResourceGroupName
                    return
                }
            }
        }

        # Process the resource groups
        try {
            # Find RGs to remove based on passed in name filter
            $resourceGroups = Get-AzureRmResourceGroup | `
                                    ? { $nameFilterList.Count -eq 0 -or $_.ResourceGroupName.ToLower() -match $nameFilterRegex }
            $groupMap = @{}
            $resourceGroups | % { $groupMap[$_.ResourceGroupName] = $_ }

            # Get the locks on the resources and RGs
            $locks = Get-AzureRmResourceLock
            $rLocks = $locks | ? {$_.ExtensionResourceType -eq "Microsoft.Authorization/locks"} # locks on resources
            $rgLocks = $locks | ? {$_.ResourceType -eq "Microsoft.Authorization/locks"} # locks on RGs

            $resourceGroups | % {
                $currentRg = $_
                # Filter out RGs with locks
                $rgLock = $rgLocks | ? {$_.ResourceGroupName -eq $currentRg.ResourceGroupName}
                if ($rgLock) {
                    Write-Output "$($currentRg.ResourceGroupName) is locked: $($rgLock.Properties.notes)"
                    $groupMap.Remove($currentRg.ResourceGroupName)
                    return
                }
                # Filter out the RG running this runbook
                if ($currentRg.ResourceGroupName -eq $thisResourceGroupName) {
                    Write-Output ("The resource group for this runbook job will not be removed.  Resource group: $thisResourceGroupName")
                    $groupMap.Remove($currentRg.ResourceGroupName)
                    return
                }
            }

            $resources = Get-AzureRmResource
            $resourcesToRemove = ($resources | ? {$groupMap.ContainsKey($_.ResourceGroupName)})
            $resourcesToRemove | % {
                $currentR = $_
                $rLock = $rLocks | ? {$_.ResourceGroupName -eq $currentR.ResourceGroupName} | ? {$_.ResourceName -eq $currentR.Name }
                if ($rLock) {
                    # Filter out RGs that contain locked resources
                    Write-Output "$($currentR.ResourceGroupName)/$($currentR.Name) is locked: $($rLock.Properties.notes)"
                    $groupMap.Remove($currentR.ResourceGroupName)
                }
            }

            # The RGs to be removed
            $groupsToRemove = $groupMap.Values

            # No matching groups were found to remove 
            if ($groupsToRemove.Count -eq 0) { 
                Write-Output "No matching resource groups found."
                return
            }
            # Matching groups were found to remove 
            else 
            { 
                # The resources in RGs to be removed
                $resourcesToRemove = ($resources | ? {$groupMap.ContainsKey($_.ResourceGroupName)})

                # In preview mode, so report what would be removed, but take no action.
                if ($PreviewMode -eq $true) { 
                    Write-Output "Preview Mode: The following resource groups would be removed:" 
                    foreach ($group in $groupsToRemove){						 
                        Write-Output "`t$($group.ResourceGroupName)"
                    } 
                    Write-Output "Preview Mode: The following resources would be removed:"
                    $resources | % { "`t$($_.ResourceGroupName)/$($_.Name)" }
                } 
                # Remove the resource groups
                else { 
                    Write-Output "The following resource groups will be removed:" 
                    foreach ($group in $groupsToRemove){						 
                        Write-Output $($group.ResourceGroupName) 
                    } 
                    Write-Output "The following resources will be removed:"
                    $resources | % { "`t$($_.ResourceGroupName)/$($_.Name)" }
                    # Here is where the remove actions happen
                    foreach ($resourceGroup in $groupsToRemove) { 
                        Write-Output "Starting to remove resource group: $($resourceGroup.ResourceGroupName) ..." 
                        # Remove-AzureRmResourceGroup -Name $($resourceGroup.ResourceGroupName) -Force 
                        if ((Get-AzureRmResourceGroup -Name $($resourceGroup.ResourceGroupName) -ErrorAction SilentlyContinue) -eq $null) { 
                            Write-Output "...successfully removed resource group: $($resourceGroup.ResourceGroupName)" 
                        }				 
                    } 
                } 
                Write-Output "Completed." 
            } 
        } 
        catch { 
            $errorMessage = $_ 
        } 
        if ($errorMessage) { 
            Write-Error $errorMessage 
        }

        # Send email report
        if ($DestEmailAddress -and $FromEmailAddress -and $SendGridKey) {
            
            $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
            $headers.Add("Authorization", "Bearer " + $SendGridKey)
            $headers.Add("Content-Type", "application/json")
            
            if ($PreviewMode) {
                $subject = "Azure Resources scheduled for cleanup"
                $content = "<HTML><BODY><P><H1>Cleanup summary</H1></P>"
                $content += "<P><H2>Resources scheduled for clean up:</H2></P>"
            } else {
                $subject = "Azure Resources cleanup report"
                $content = "<HTML><BODY><P><H1>Cleanup summary</H1></P>"
                $content += "<P><H2>Resources cleaned up:</H2></P>"
            }

            # TODO: if cleanup occurred, should report on any failures

            $resourcesToRemoveTable = $resourcesToRemove | Select-Object Name, ResourceGroupName, ResourceType | ConvertTo-Html -Fragment
            $content += $resourcesToRemoveTable

            $content += "<P><H2>Locked Resource Groups:</H2></P>"
            $content += $rgLocks | Select-Object -ExpandProperty Properties -Property ResourceGroupName, Name | Select-Object ResourceGroupName, Name, notes | ConvertTo-Html -Fragment

            $content += "<P><H2>Locked resources:</H2></P>"
            $content += $rLocks | Select-Object -ExpandProperty Properties -Property ResourceName, ResourceGroupName, Name | Select-Object ResourceName, ResourceGroupName, Name, notes | ConvertTo-Html -Fragment

            $content += "</BODY></HTML>"

            $content = $content -join [Environment]::NewLine

            $body = @{
            personalizations = @(
                @{
                    to = @(
                            @{
                                email = $DestEmailAddress
                            }
                    )
                }
            )
            from = @{
                email = $FromEmailAddress
            }
            subject = $subject
            content = @(
                @{
                    type = "text/html"
                    value = $content
                }
            )
            }

            $bodyJson = $body | ConvertTo-Json -Depth 8

            $response = Invoke-RestMethod -Uri https://api.sendgrid.com/v3/mail/send -Method Post -Headers $headers -Body $bodyJson
        }
    }
}