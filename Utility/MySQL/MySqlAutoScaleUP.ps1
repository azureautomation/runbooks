<#
.SYNOPSIS
    Auto scale up Managed MySQL DB to the next higher vCPU

.DESCRIPTION
    This runbook will auto scale up Managed MySQL DB instance to the next 
    higher available vCPU configuration with a given Tier 

.PARAMETER ResourceGroupName
    The name of Resource Group

.PARAMETER ServerName
    The name of Server

.PARAMETER SkuTier
    The name current Tier

.EXAMPLE
    MySQLAutoScaleUP -ResourceGroupName "prod" -Server 'dbazure' -SkuTier "Gen5"
	  
.NOTES
    AUTHOR: Vikrant Pawar
    LASTEDIT: Sep 20th 2021 
#>

workflow MySQLAutoScaleUP
{
    ########################################################

    # Parameters

    ########################################################

    [CmdletBinding()]

    param(

        [Parameter(Mandatory=$True,Position=0)]

        [ValidateLength(1,100)]

        [string]$ResourceGroupName,



        [Parameter(Mandatory=$True,Position=1)]

        [ValidateLength(1,100)]

        [string]$ServerName,

        

        [Parameter(Mandatory=$False,Position=2)]

        [ValidateLength(1,100)]

        [string]$SkuTier

    )



    # Track the execution date & time
    $StartDate=(GET-DATE)



    ########################################################

    # Log-in to Azure with AZ (standard code)

    ########################################################

    Write-Verbose -Message 'Connecting to Azure'

    

    # Name of the Azure Run As a connection

    $ConnectionName = 'AzureRunAsConnection'

    try

    {

        # Get the connection properties to connect Azure resources

        $ServicePrincipalConnection = Get-AutomationConnection -Name $ConnectionName      

    

        'Log in to Azure...'

    # $null = Connect-AzAccount `

        #    -ServicePrincipal `

        #   -TenantId $ServicePrincipalConnection.TenantId `

        #  -ApplicationId $ServicePrincipalConnection.ApplicationId `

        # -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint 

            $null = Add-AzAccount `
            -ServicePrincipal `
            -TenantId $servicePrincipalConnection.TenantId `
            -ApplicationId $servicePrincipalConnection.ApplicationId `
            -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 

    }

    catch 

    {

        if (!$ServicePrincipalConnection)

        {

            #Missed to 'Create Azure Run As account' 

            $ErrorMessage = "Connection $ConnectionName not found."

            throw $ErrorMessage

        }

        else

        {

            # additional execption

            Write-Error -Message $_.Exception.Message

            throw $_.Exception

        }

    }



    ########################################################

    # Setting SKU Tier for MySQLDatabase

    ########################################################
    "get current sku"
    $CurrentSKU = (Get-AzMySqlServer -Name $ServerName -ResourceGroupName $ResourceGroupName).skuname
    $CurrentVCPU = $CurrentSKU.substring($CurrentSKU.length-2,2)
    $NewVCPU = 2*$CurrentVCPU
    $NewSKU = $SkuTier + "_" + $NewVCPU
    "current sku is $CurrentSKU and vCPU $CurrentVCPU, New SKU is $NewSKU"


    If($CurrentSKU -eq $NewSKU)

    {

        # Validating the existing SKU value

        Write-Error "Cannot change pricing tier of $ServerName because the new SKU $SkuTier tier is equal to current SKU tier $CurrentSKU."

        return

    }

    else

    {

        try

        {

            # updating the existing SKU value with the new one
            "Upscaling from SKU tier $CurrentSKU to $NewSKU"
            Write-Verbose -Message "Upscaling from SKU tier $CurrentSKU to $NewSKU"
            Update-AzMySqlServer -Name "$($ServerName)" -ResourceGroupName  "$($ResourceGroupName)" -sku "$($NewSKU)"

        }

        catch

        {

            Write-Error -Message $_.Exception.Message

            throw $_.Exception

        }    

    }
}