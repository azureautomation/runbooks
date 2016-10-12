Configuration RemoveHybridWorker {

    param(

        [Parameter(Mandatory=$true)]
        [System.String] $AutomationEndpoint,

        [Parameter(Mandatory=$true)]
        [System.String] $HybridGroupName = "MyHybridWorkerGroup"

    )

    Import-DscResource -ModuleName HybridRunbookWorker

    Node $AllNodes.NodeName {
        HybridRunbookWorker Onboard {
            Ensure    = 'Absent'
            Endpoint  = $AutomationEndpoint
            Token     = Get-AutomationPSCredential -Name "TokenCredential"
            GroupName = $HybridGroupName
        }
    }
}