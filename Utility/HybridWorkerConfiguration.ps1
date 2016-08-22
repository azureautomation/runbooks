Configuration HybridWorkerConfiguration {
    Import-DscResource -ModuleName HybridRunbookWorker

    param(

        [Parameter(Mandatory=$true)]
        [String] $Endpoint,

        [Parameter(Mandatory=$true)]
        [String] $Token,

        [Parameter(Mandatory=$false)]
        [String] $GroupName = "MyHybridWorker"

    )

    HybridRunbookWorker Onboard {
        Ensure = 'Present'
        Endpoint = $Endpoint
        Token = $Token
        GroupName = $GroupName
    }
}