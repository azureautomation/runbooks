<#PSScriptInfo
.VERSION 1.0
.GUID 4d9af509-ec3f-44c6-b2af-9a9306642b7a
.AUTHOR Azure Automation Team
.COMPANYNAME Microsoft
.COPYRIGHT 
.TAGS Azure Automation 
.LICENSEURI 
.PROJECTURI 
.ICONURI 
.EXTERNALMODULEDEPENDENCIES 
.REQUIREDSCRIPTS 
.EXTERNALSCRIPTDEPENDENCIES 
.RELEASENOTES
#>

<#  
.SYNOPSIS  
  Runs a PowerShell command, with or without parameters. 
  
.DESCRIPTION  
  This runbook will run a PowerShell command, with or without parameters.
  In Azure Automation, this runbook is useful for running a PowerShell command on a hybrid runbook worker.
  
.PARAMETER Command  
  Required  
  The name of the PowerShell command to run   
  
.PARAMETER Parameters  
  Optional
  Format the value with JSON like this:  '{"ComputerName":"localhost","Name":"lsass","Verbose":true}'

.EXAMPLE
  .\Invoke-PSCommand -Command "Get-Process" -Parameters '{"ComputerName":"localhost","Name":"lsass","Verbose":true}'

.NOTES
   AUTHOR: Azure Automation Team 
   LASTEDIT: 2016-10-9
#>

# Returns whatever object(s) the invoked command returns  
[OutputType([object])] 

param (
    [Parameter(Mandatory=$true)]
    [string] $Command,

    [Parameter(Mandatory=$false)]
    [string] $Parameters
)

if ([string]::IsNullOrEmpty($Parameters))
{
    & $Command
}
else
{
    # Convert parameters from json into hash table so they can be passed to the command
    $Params = @{}
    $ParamValues = ConvertFrom-Json $Parameters
    foreach ($Param in $ParamValues.PSObject.Properties)
    {
        $Params.Add($Param.Name,$Param.Value)
    }
    & $Command @Params
}
