Configuration HybridWorkerConfiguration {
    

    param(

        [Parameter(Mandatory=$true)]
        [string] $Endpoint,

        [Parameter(Mandatory=$true)]
        [PSCredential] $Token,

        [Parameter(Mandatory=$false)]
        [string] $GroupName = "MyHybridWorker"

    )

    Import-DscResource -ModuleName HybridRunbookWorker
    Import-DscResource -ModuleName @{ModuleName='xPSDesiredStateConfiguration'; ModuleVersion='3.9.0.0'}


    Node $AllNodes.NodeName {
        HybridRunbookWorker Onboard {
            Ensure    = 'Present'
            Endpoint  = $Endpoint
            Token     = $Token
            GroupName = $GroupName
        }
    }
}

#HybridWorkerConfiguration -Endpoint $AutomationEndpoint -Token $DscCredential -Verbose