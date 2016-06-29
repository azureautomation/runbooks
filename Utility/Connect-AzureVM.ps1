<#PSScriptInfo

.VERSION 1.0

.GUID 803969d1-8f13-482b-8345-6b5b503dff25

.AUTHOR Rohit Minni

.COMPANYNAME Microsoft

.COPYRIGHT 

.TAGS 

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
    Sets up the connection to an Azure ARM VM

.DESCRIPTION
    This runbook sets up a connection to an Azure ARM virtual machine. It requires the Azure virtual machine to
    have the Windows Remote Management service enabled. It enables WinRM and configures it on your VM after which it sets up a connection to the Azure
	subscription, gets the public IP Address of the virtual machine and return it. 

.PARAMETER AzureSubscriptionId
    SubscriptionId of the Azure subscription to connect to
    
.PARAMETER AzureOrgIdCredentialName
    A credential containing an Org Id username / password with access to this Azure subscription.

	If invoking this runbook inline from within another runbook, pass a Azure Automation PSCredential Name for this parameter.

.PARAMETER ResourceGroupName
    Name of the resource group where the VM is located.

.PARAMETER VMName    
    Name of the virtual machine that you want to connect to  

.EXAMPLE
    Connect-AzureARMVMPS -AzureSubscriptionId "1019**********************" -ResourceGroupName "RG1" -VMName "VM01" -AzureOrgIdCredentialName $cred

.NOTES
    AUTHOR: Rohit Minni
    LASTEDIT: May 25, 2016 
#>
   
    Param
    (            
        [parameter(Mandatory=$true)]
        [String]$AzureSubscriptionId,

        [parameter(Mandatory=$true)]
        [String]$AzureOrgIdCredentialName,
                        
        [parameter(Mandatory=$true)]
        [String]$ResourceGroupName,
        
        [parameter(Mandatory=$true)]
        [String]$VMName      
    )

    $ErrorActionPreference = "SilentlyContinue"
    $AzureOrgIdCredential = Get-AutomationPSCredential -Name $AzureOrgIdCredentialName
	
    $Login = Login-AzureRmAccount -Credential $AzureOrgIdCredential

	# Select the Azure subscription we will be working against
    $Subscription = Select-AzureRmSubscription -SubscriptionId $AzureSubscriptionId


  function Configure-AzureWinRMHTTPS {
  <#
  .SYNOPSIS
  Configure WinRM over HTTPS inside an Azure VM.
  .DESCRIPTION
  1. Creates a self signed certificate on the Azure VM.
  2. Creates and executes a custom script extension to enable Win RM over HTTPS and opens 5986 in the Windows Firewall
  3. Creates a Network Security Rules for the Network Security Group attached the the first NIC attached the the VM allowing inbound traffic on port 5986  
  #>
 
   
  Param
          (
            [parameter(Mandatory=$true)]
            [String]$VMName,
             
            [parameter(Mandatory=$true)]
            [String]$ResourceGroupName,      
 
            [parameter()]
            [String]$DNSName = $env:COMPUTERNAME,
              
            [parameter()]
            [String]$SourceAddressPrefix = "*"
 
          ) 
 
# define a temporary file in the users TEMP directory
$file = $env:TEMP + "\ConfigureWinRM_HTTPS.ps1"

$string = "param(`$DNSName)" + "`r`n" + "Enable-PSRemoting -Force" + "`r`n" + "New-NetFirewallRule -Name 'WinRM HTTPS' -DisplayName 'WinRM HTTPS' -Enabled True -Profile 'Any' -Action 'Allow' -Direction 'Inbound' -LocalPort 5986 -Protocol 'TCP'" + "`r`n" + "`$thumbprint = (New-SelfSignedCertificate -DnsName `$DNSName -CertStoreLocation Cert:\LocalMachine\My).Thumbprint" + "`r`n" + "`$cmd = `"winrm create winrm/config/Listener?Address=*+Transport=HTTPS @{Hostname=`"`"`$DNSName`"`"; CertificateThumbprint=`"`"`$thumbprint`"`"}`"" + "`r`n" + "cmd.exe /C `$cmd"
	
$string | Out-File -FilePath $file -force
 
  
# Get the VM we need to configure
$vm = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $VMName
 
# Get storage account name
$StorageAccountName = $vm.StorageProfile.OsDisk.Vhd.Uri.Split("//")[2].Split('.')[0]
# get storage account key
$StorageKey = Get-AzureRmStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
try
{
    $key = $StorageKey.value[0]
}
catch
{
}
finally
{
    if($key -eq $null)
    {
        $key = $StorageKey.Key1
    }
}
# create storage context
$StorageContext = New-AzureStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $key
  
# create a container called scripts
$CreateContainer = New-AzureStorageContainer -Name "scripts" -Context $StorageContext -ErrorAction SilentlyContinue
  
#upload the file
$BlobContent = Set-AzureStorageBlobContent -Container "scripts" -File $file -Blob "ConfigureWinRM_HTTPS.ps1" -Context $StorageContext -force
 
# Create custom script extension from uploaded file
$extension = Set-AzureRmVMCustomScriptExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -Name "EnableWinRM_HTTPS" -Location $vm.Location -StorageAccountName $StorageAccountName -StorageAccountKey $key -FileName "ConfigureWinRM_HTTPS.ps1" -ContainerName "scripts" -RunFile "ConfigureWinRM_HTTPS.ps1" -Argument $DNSName

# Get the name of the first NIC in the VM
$nicName = Get-AzureRmResource -ResourceId $vm.NetworkInterfaceIDs[0]
$nic = Get-AzureRmNetworkInterface -ResourceGroupName $ResourceGroupName -Name $nicName.ResourceName
 
# Get the network security group attached to the NIC
$nsgRes = Get-AzureRmResource -ResourceId $nic.NetworkSecurityGroup.Id
$nsg = Get-AzureRmNetworkSecurityGroup  -ResourceGroupName $ResourceGroupName  -Name $nsgRes.Name 
  
# Add the new NSG rule, and update the NSG
$InboundRule = $nsg | Add-AzureRmNetworkSecurityRuleConfig -Name "WinRM_HTTPS" -Priority 1100 -Protocol TCP -Access Allow -SourceAddressPrefix $SourceAddressPrefix -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 5986 -Direction Inbound -ErrorAction SilentlyContinue | Set-AzureRmNetworkSecurityGroup -ErrorAction SilentlyContinue

}

    Configure-AzureWinRMHTTPS -ResourceGroupName $ResourceGroupName -VMName $VMName

    $VM = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $VMName
    if($VM)
    {
  
        $NICs = Get-AzureRmNetworkInterface | Where-Object{$_.VirtualMachine.Id -eq $VM.Id}
        $IPConfigArray = New-Object System.Collections.ArrayList
        foreach($nic in $NICs)
        {
            if($nic.IpConfigurations.LoadBalancerBackendAddressPools)
            {
                $arr = $nic.IpConfigurations.LoadBalancerBackendAddressPools.id.Split('/')
                $LoadBalancerNameIndex = $arr.IndexOf("loadBalancers") + 1                    
                $loadBalancer = Get-AzureRmLoadBalancer | Where-Object{$_.Name -eq $arr[$LoadBalancerNameIndex]}
                $PublicIpId = $loadBalancer.FrontendIPConfigurations.PublicIpAddress.Id
            }

            $publicips = New-Object System.Collections.ArrayList

            if($nic.IpConfigurations.PublicIpAddress.Id)
            {
                $publicips.Add($nic.IpConfigurations.PublicIpAddress.Id) | Out-Null
            }

            if($PublicIpId)
            {
                $publicips.Add($PublicIpId) | Out-Null
            }

            foreach($publicip in $publicips)
            {
                $name = $publicip.split('/')[$publicip.Split('/').Count - 1]
                $ResourceGroup = $publicip.Split('/')[$publicip.Split('/').Indexof("resourceGroups")+1]
                $PublicIPAddress = Get-AzureRmPublicIpAddress -Name $name -ResourceGroupName $ResourceGroup | Select-Object -Property Name,ResourceGroupName,Location,PublicIpAllocationMethod,IpAddress
                $IPConfigArray.Add($PublicIPAddress) | Out-Null
            }
        }
        $Uri = $IPConfigArray | Where-Object{$_.IpAddress -ne $null} | Select-Object -First 1 -Property IpAddress

        if($Uri.IpAddress -ne $null)
        {               
            return $Uri.IpAddress.ToString()           
        }
        else
        {
            Write-Output "Couldnt get the IP Address of the VM"
            return $null
        }  
    
    }
    else
    {
        Write-Output "VM not found"
        return $null
    }        
    
