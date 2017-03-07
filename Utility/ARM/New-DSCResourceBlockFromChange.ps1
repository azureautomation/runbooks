<#
.SYNOPSIS
    Generates a DSC resource block to undo a specific change


.DESCRIPTION
    Generates a DSC resource block to undo a specific change reported in OMS Change Tracking

    
.PARAMETER Query

    Mandatory. The query used to generate the single result that you wish to undo.
        (Expects only Type=ConfigurationChange results, only accepts the first result)


.PARAMETER SubscriptionID

    Mandatory. The Subscription ID containing the OMS workspace where the Change Tracking change record belongs.


.PARAMETER ResourceGroupName

    Mandatory. The resource group name of the OMS workspace where the Change Tracking change record belongs.


.PARAMETER WorkspaceName

    Mandatory. The name of the OMS workspace where the Change Tracking change record belongs.


.PARAMETER AutomationAccountName

    Optional. The name of the Automation Account to store the DSC configuration. If blank, the configuration will not be stored.


.PARAMETER StartDateTime

    Optional. The start date and time for the time window to look for the change record. Defaults to past 24 hours ago.


.PARAMETER EndDateTime

    Optional. The end date and time for the time window to look for the change record. Default to now.


.PARAMETER IsLinux

    Optional. Flag to set if the DSC block is being generated for a Linux machine.


.EXAMPLE
    New-DSCResourceBlock -Query "Type=ConfigurationChange (ConfigChangeType=Files)" -ResourceGroupName "Contoso" -WorkspaceName "ContosoWorkspace" -SubscriptionID "xxx-xxxx-xxxx-xxxxx"


.NOTES

    AUTHOR: Jenny Hunter, Azure Automation Team

    LASTEDIT: January 31, 2017  
#>



Param (
# OMS Query for change record
[Parameter(Mandatory=$true)]
[String] $Query,

# Azure Subscription ID
[Parameter(Mandatory=$true)]
[String] $SubscriptionID,

# Resource Group Name
[Parameter(Mandatory=$true)]
[String] $ResourceGroupName,

# OMS Workspace Name
[Parameter(Mandatory=$true)]
[String] $WorkspaceName,

# Azure Automation Account Name
[Parameter(Mandatory=$false)]
[String] $AutomationAccountName,

# Start
[Parameter(Mandatory=$false)]
[String] $StartDateTime = (Get-Date).AddDays(-1).toUniversalTime().GetDateTimeFormats()[105],

# End
[Parameter(Mandatory=$false)]
[String] $EndDateTime = (Get-Date).toUniversalTime().GetDateTimeFormats()[105],

# Linux Flag
[Parameter(Mandatory=$false)]
[Boolean] $IsLinux = $false
)

# Generate the seach query for the OMS log analytics REST api
$SearchQuery = "{'top':1, 'query':'$Query', 'start':'$StartDateTime', 'end':'$EndDateTime'}";

try{ 

    # Login to the armclient
    $Login = armclient login

} catch {

    Write-Error ("Please ensure you have Chocolatey and the ARMClient installed. Find out more at https://docs.microsoft.com/en-us/azure/log-analytics/log-analytics-log-search-api.")
}

# Get the resulting change record
$Output = armclient post /subscriptions/$SubscriptionID/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/search?api-version=2015-03-20 $SearchQuery

# Create a dictionary to hold the change record values
$Properties = @{}

# Create an index/flag for the value header
$i = -1

# Parse the results for the relevant change data
for ($j = 0; $j -lt $output.Length; $j++) {

    # If within the value category and not an ACL add it to the properties list
    if (($i -ge 0) -AND ($output[$j].Trim().StartsWith('"')) -and !($output[$j].Trim().startsWith('"Acls"')) -and !($output[$j].Trim().startsWith('"PreviousAcls"'))) {
        
        # Find the property's name
        $Output[$j] = $Output[$j].Substring($Output[$j].IndexOf('"') + 1)
        $QuoteIndex1 = $Output[$j].IndexOf('"')
        $PropertyName = $Output[$j].Substring(0, $QuoteIndex1)

        # Find the property's value
        $Output[$j] = $Output[$j].Substring(0,$Output[$j].LastIndexOf('"'))
        $QuoteIndex2 = $Output[$j].LastIndexOf('"') + 1
        $PropertyValue = $output[$j].Substring($QuoteIndex2, ($Output[$j].Length - $QuoteIndex2))

        # Add the value pair to the dictionary, check for duplicate entries (may result from metadata)
        try {

            $Properties.Add($PropertyName, $PropertyValue)
            Write-Output "$PropertyName : $PropertyValue"

        } catch{}
       
    }

    # Check for the header of the value category
    if (($i -lt 0) -and ($Output[$j] -match '"value":') -and !($Output[$j] -match ']')) {
        
        $i = $j + 1

    } 

    #Write-Output $j " " $Output[$j]

}

# Thrown an error if the output didn't contain a valid change record
if ($i -lt 0) {

    Write-Error ("Error: Please check your values and query.")

}

# Create a hash table to store the OMS to DSC type conversions
$CTypes = @{}

# Use the OS to determine which change types are available
if ($isLinux) {

    $CTypes.add("Daemons", "nxService")
    $CTypes.add("Software", "nxPackage")
    $CTypes.add("Files", "nxFile")

} else {

    $CTypes.add("WindowsServices", "Service")
    $CTypes.add("Registry", "Registry")
    $CTypes.add("Files", "File")

}

# Begin compiling the DSC block with the parsed metadata
$ChangeType = $CTypes.Get_Item($Properties.Get_Item("ConfigChangeType"))
$DscBlock =  "`t`t$ChangeType ChangeItem`r`n`t`t{"

# Determine which action to take to undo the change
if ($Properties.Get_Item("ChangeCategory") -imatch "Added") {

    $DscBlock = "$DscBlock`r`n`t`t`tEnsure = `"Absent`""

} elseif ($Properties.Get_Item("ChangeCategory") -imatch "Removed") {

   $DscBlock = "$DscBlock`r`n`t`t`tEnsure = `"Present`""

} else {
    # To-do: Undo modification based on type and what field was changed
}

# Use the Change Type to provide a naming reference to the specific change item
$ItemName = ""

switch ($ChangeType) {
    "Service" {
        
        $Name = $Properties.Get_Item("SvcName")
        $ItemName = "`t`t`tName = `"$Name`""

    } "Registry" {
            
        $Key = $Properties.Get_Item("RegistryKey").Replace("\\","\")
        $ValueName = $Properties.Get_Item("ValueName")
        $ItemName = "`t`t`tKey = `"$Key`"`r`n`t`t`tValueName = `"$ValueName`""

    } "nxService" {

        $Name = $Properties.Get_Item("SvcName")
        $ItemName = "`t`t`tName = `"$Name`""

    } "nxPackage" {
        
        $Name = $Properties.Get_Item("SoftwareName")
        $ItemName = "`t`t`tName = `"$Name`""

    } Default {
        # File is the default
        $Path = $Properties.Get_Item("FileSystemPath").Replace("\\","\")
        $ItemName = "`t`t`tDestinationPath = `"$Path`""
    }
}

# Add the item name string to the DSC Block
$DscBlock = "$DscBlock`r`n$ItemName"

# Add ending curly brace
$DscBlock = "$DscBlock`r`n`t`t}"



# To-do: Turn into configuration and apply through Azure Automation
# Only generate, store, compile, and apply configuration if an automation account is supplied
if (![String]::IsNullOrEmpty($AutomationAccountName)) {
    
    $DscConfiguration = "Configuration ChangeRemediationDemo`r`n{`r`n`tImport-DscResource –ModuleName 'PSDesiredStateConfiguration’`r`n`tNode `"localhost`"`r`n`t{`r`n$DscBlock`r`n`t}`r`n}"

    # Write the Configuration to a *.ps1 file
    $tmp = New-Item $Env:Temp\ChangeRemediationDemo.ps1 -type file -force -value $DscConfiguration

    # Login to Azure account
    $Account = Add-AzureRmAccount

    # Get a reference to the DSC node
    $DscNode = Get-AzureRmAutomationDscNode -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $Properties.Get_Item("Computer")
    
    # Import the DSC configuration to the automation account
    $null = Import-AzureRmAutomationDscConfiguration -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName -SourcePath $tmp.FullName -Published -Force


    # Compile the DSC configuration
    $CompilationJob = Start-AzureRmAutomationDscCompilationJob -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -ConfigurationName "ChangeRemediationDemo"
    while($CompilationJob.EndTime –eq $null -and $CompilationJob.Exception –eq $null)           
    {
        $CompilationJob = $CompilationJob | Get-AzureRmAutomationDscCompilationJob
        Start-Sleep -Seconds 3
    }
  
    # Configure the DSC node
    $null = Set-AzureRmAutomationDscNode -ResourceGroupName $ResourceGroupName  -NodeConfigurationName "ChangeRemediationDemo.localhost" -Id $DscNode.Id -AutomationAccountName $AutomationAccountName -Force

    # Clean up the generated configuration file 
    #Remove-Item $tmp.FullName -Force

    #Print out the DSC Configuration
    Write-Output "`n`n`n"
    Write $DscConfiguration
} else {

    #Print out the DSC Block
    Write-Output "`n`n`n"
    Write $DscBlock
}
