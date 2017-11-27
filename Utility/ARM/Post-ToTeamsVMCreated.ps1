Param(
  [string]$ChannelURL,
  [string]$resourceId
)

$ChannelURL
$resourceId

$r = $resourceId.Split('/') 
$Subscription = $r[2]
$VMResourceGroup = $r[4]
$VMName = $r[8]
$target = "https://portal.azure.com/#resource/$resourceId/overview"   

$body = ConvertTo-Json -Depth 4 @{
  title = 'Azure VM Creation Notification' 
  text = 'A new Azure VM is available'
  sections = @(
    @{
      activityTitle = 'Azure VM'
      activitySubtitle = 'VM ' + $VMName + ' has been created'
      activityText = 'VM was created in the subscription ' + $Subscription + ' and resource group ' + $VMResourceGroup
      activityImage = 'https://azure.microsoft.com/svghandler/automation/'
    }
  )
  potentialAction = @(@{
      '@context' = 'http://schema.org'
      '@type' = 'ViewAction'
      name = 'Click here to manage the VM'
      target = @($target)
    })
}


Invoke-RestMethod -Method "Post" -Uri $ChannelURL -Body $body

