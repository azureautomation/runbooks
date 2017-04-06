Configuration HybridWorkerConfiguration {

    param(

        [Parameter(Mandatory=$true)]
        [System.String] $AutomationEndpoint,

        [Parameter(Mandatory=$false)]
        [System.String] $HybridGroupName = "MyHybridWorker"

    )

    Import-DscResource -ModuleName @{ModuleName='xPSDesiredStateConfiguration'; ModuleVersion='4.0.0.0'}
    Import-DscResource -ModuleName HybridRunbookWorkerDsc

    $OIPackageLocalPath = "C:\MMASetup-AMD64.exe"

    Node $AllNodes.NodeName

    {

        # Download a package

        xRemoteFile OIPackage

        {

            Uri = "https://opsinsight.blob.core.windows.net/publicfiles/MMASetup-AMD64.exe"

            DestinationPath = $OIPackageLocalPath

        }



        # Application, requires reboot. Allow reboot in meta config

        Package OI

        {

            Ensure = "Present"

            Path = $OIPackageLocalPath

            Name = "Microsoft Monitoring Agent"

            ProductId = "E854571C-3C01-4128-99B8-52512F44E5E9"

            Arguments = '/Q /C:"setup.exe /qn ADD_OPINSIGHTS_WORKSPACE=1 OPINSIGHTS_WORKSPACE_ID=' + 

                $Node.WorkspaceID + ' OPINSIGHTS_WORKSPACE_KEY=' + 

                    $Node.WorkspaceKey + ' AcceptEndUserLicenseAgreement=1"'

            DependsOn = "[xRemoteFile]OIPackage"

        }

        

        # Service state

        Service OIService

        {

            Name = "HealthService"

            State = "Running"

            DependsOn = "[Package]OI"

        }



        WaitForHybridRegistrationModule ModuleWait

        {

            IsSingleInstance = 'Yes'

            RetryIntervalSec = 3

            RetryCount = 2

            DependsOn = '[Package]OI'

        }



        HybridRunbookWorker Onboard

        {

            Ensure    = 'Present'

            Endpoint  = $Node.AutomationEndpoint

            Token     = $Node.Token

            GroupName = $Node.GroupName

            DependsOn = '[WaitForHybridRegistrationModule]ModuleWait'

        }

    }

}
}