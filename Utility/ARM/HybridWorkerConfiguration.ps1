Configuration HybridWorkerConfiguration {

    param(

        [Parameter(Mandatory=$true)]
        [System.String] $AutomationEndpoint,

        [Parameter(Mandatory=$false)]
        [System.String] $HybridGroupName = "MyHybridWorker"

    )

    Import-DscResource -ModuleName HybridRunbookWorker
    Import-DscResource -ModuleName xPSDesiredStateConfiguration -ModuleVersion 4.0.0.0

    $OIPackageLocalPath = "C:\MMASetup-AMD64.exe"
    $WorkspaceID = Get-AutomationVariable -Name "WorkspaceId" 
    $WorkspaceKey = Get-AutomationVariable -Name "WorkspaceKey"



    Node $AllNodes.NodeName {
        HybridRunbookWorker Onboard {
            Ensure    = 'Present'
            Endpoint  = $AutomationEndpoint
            Token     = Get-AutomationPSCredential -Name "TokenCredential"
            GroupName = $HybridGroupName
        }

         xRemoteFile OIPackage {
            Uri = "https://opsinsight.blob.core.windows.net/publicfiles/MMASetup-AMD64.exe"
            DestinationPath = $OIPackageLocalPath
        }

        Service OIService
        {
            Name = "HealthService"
            State = "Running"
            DependsOn = "[Package]OI"
        }

        Package OI {
            Ensure = "Present"
            Path  = $OIPackageLocalPath
            Name = "Microsoft Monitoring Agent"
            ProductId = "E854571C-3C01-4128-99B8-52512F44E5E9"
            Arguments = '/C:"setup.exe /qn ADD_OPINSIGHTS_WORKSPACE=1 OPINSIGHTS_WORKSPACE_ID=' + $WorkspaceID + ' OPINSIGHTS_WORKSPACE_KEY=' + $WorkspaceKey + ' AcceptEndUserLicenseAgreement=1"'
            DependsOn = "[xRemoteFile]OIPackage"
        }
    }
}