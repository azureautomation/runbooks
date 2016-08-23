Configuration HybridWorkerConfiguration {
    

    param(

       # [Parameter(Mandatory=$true)]
        [string] $Endpoint,

        #[Parameter(Mandatory=$true)]
        [string] $Token,

        #[Parameter(Mandatory=$false)]
        [string] $GroupName = "MyHybridWorker"

    )

    Import-DscResource -ModuleName HybridRunbookWorker

    Node "HybridVM" {
        HybridRunbookWorker Onboard {
            Ensure = 'Present'
            Endpoint = $Endpoint
            Token = $Token
            GroupName = $GroupName
        }
    }
}

HybridWorkerConfiguration