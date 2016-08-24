Configuration HybridWorkerConfiguration {
    

    param(

        [Parameter(Mandatory=$true)]
        [System.String] $AutomationEndpoint,

        [Parameter(Mandatory=$false)]
        [System.String] $HybridGroupName = "MyHybridWorker"

    )

    Import-DscResource -ModuleName HybridRunbookWorker


    Node $AllNodes.NodeName {
        HybridRunbookWorker Onboard {
            Ensure    = 'Present'
            Endpoint  = $AutomationEndpoint
            Token     = Get-AutomationPSCredential -Name "TokenCredential"
            GroupName = $HybridGroupName
        }
    }
}