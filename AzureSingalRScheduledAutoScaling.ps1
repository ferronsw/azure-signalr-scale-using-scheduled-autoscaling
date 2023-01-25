<#
.SYNOPSIS
    Vertically scale Azure SignalR Service up or down according to a
    schedule using Azure Automation.

.DESCRIPTION
    This Azure Automation runbook enables vertically scaling of
    Azure SignalR Service (standard tier, because premium already has scale options) according to a schedule. 
    on a schedule allows you to scale your solution according to
    predictable resource demand. This runbook
    can be scheduled to run hourly. The code checks the
    scalingSchedule parameter to decide if scaling needs to be
    executed, or if the database is in the desired state already and
    no work needs to be done. The script is Timezone aware.

.PARAMETER environmentName
    Name of Azure Cloud environment. Default is AzureCloud, only change
    when on Azure Government Cloud, for example AzureUSGovernment.

.PARAMETER resourceGroupName
    Name of the resource group to which the SignalR Service is
    assigned.

.PARAMETER subscriptionId
    Set subscriptionId if the system assinged Indentity has access to more then one subscription.

.PARAMETER signalRServiceName
    Azure SignalR Service name.

.PARAMETER scalingSchedule
    Database Scaling Schedule. It is possible to enter multiple
    comma separated schedules: [{},{}]
    Weekdays start at 0 (sunday) and end at 6 (saturday).
    If the script is executed outside the scaling schedule time slots
    that you defined, the defaut edition/tier (see below) will be
    configured.

.PARAMETER scalingScheduleTimeZone
    Time Zone of time slots in $scalingSchedule.
    Available time zones: [System.TimeZoneInfo]::GetSystemTimeZones().

.PARAMETER defaultUnits
    Azure SignalR Standard number of unitis to be provisioned outside ot the schedule.
    specified in the scalingSchedule paramater value.
    Example values: 1,2,3,4,5,6,7,8,9,10,20,30,40,50,60,70,80,90,100

.EXAMPLE
    -environmentName AzureCloud
    -resourceGroupName myResourceGroup
    signalRServiceName myserver
    -scalingSchedule [{WeekDays:[1], StartTime:"06:59:59", StopTime:"17:59:59", Units: "3"}, {WeekDays:[2,3,4,5], StartTime:"06:59:59", StopTime:"17:59:59", Units: "2"}]
    -scalingScheduleTimeZone W. Europe Standard Time
    -defaultUnits 1

.NOTES
    Author: Ferron Nijland
    Last Update: Jan 2023
#>

param(
[parameter(Mandatory=$false)]
[string] $environmentName = "AzureCloud",   

[parameter(Mandatory=$true)]
[string] $resourceGroupName,

[parameter(Mandatory=$false)]
[string] $subscriptionId,

[parameter(Mandatory=$true)]
[string] $signalRServiceName,

[parameter(Mandatory=$true)]
[string] $scalingSchedule,

[parameter(Mandatory=$false)]
[string] $scalingScheduleTimeZone = "W. Europe Standard Time",

[parameter(Mandatory=$false)]
[string] $defaultUnits = "1"
)

filter timestamp {"[$(Get-Date -Format G)]: $_"}

Write-Output "Script started." | timestamp

$VerbosePreference = "Continue"
$ErrorActionPreference = "Stop"

#Check if a subscriptionId is specified    
if($subscriptionId.Length -gt 0)
{
    try 
    {
            $AzureContext = (Connect-AzAccount -Identity -Subscription $subscriptionId).context
    }
    catch
    {
            Write-Output "There is no system-assigned user identity. Aborting."; 
            exit
    }
}
else 
{
    try 
    {
            $AzureContext = (Connect-AzAccount -Identity).context
    }
    catch
    {
            Write-Output "There is no system-assigned user identity. Aborting."; 
            exit
    }
}

Write-Output "Authenticated with Automation System assinged Identity"  | timestamp

#Get current date/time and convert to $scalingScheduleTimeZone
$stateConfig = $scalingSchedule | ConvertFrom-Json
$startTime = Get-Date
Write-Output "Azure Automation local time: $startTime." | timestamp
$toTimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById($scalingScheduleTimeZone)
Write-Output "Time zone to convert to: $toTimeZone." | timestamp
$newTime = [System.TimeZoneInfo]::ConvertTime($startTime, $toTimeZone)
Write-Output "Converted time: $newTime." | timestamp
$startTime = $newTime

#Get current day of week, based on converted start time
$currentDayOfWeek = [Int]($startTime).DayOfWeek
Write-Output "Current day of week: $currentDayOfWeek." | timestamp

# Get the scaling schedule for the current day of week
$dayObjects = $stateConfig | Where-Object {$_.WeekDays -contains $currentDayOfWeek } `
|Select-Object Units, `
@{Name="StartTime"; Expression = {[datetime]::ParseExact(($startTime.ToString("yyyy:MM:dd")+":"+$_.StartTime),"yyyy:MM:dd:HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)}}, `
@{Name="StopTime"; Expression = {[datetime]::ParseExact(($startTime.ToString("yyyy:MM:dd")+":"+$_.StopTime),"yyyy:MM:dd:HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)}}

# Get the signalr object
$signalR = Get-AzSignalR `
-ResourceGroupName $resourceGroupName `
-Name $signalRServiceName 
Write-Output "SignalR name: $($signalR.Name), sku: $($signalR.Sku.Name), units: $($signalR.Sku.Capacity)" | timestamp
Write-Output "Current SignalR ProvisioningState : $($signalR.ProvisioningState )" | timestamp

if($dayObjects -ne $null) { # Scaling schedule found for this day
    # Get the scaling schedule for the current time. If there is more than one available, pick the first
    $matchingObject = $dayObjects | Where-Object { ($startTime -ge $_.StartTime) -and ($startTime -lt $_.StopTime) } | Select-Object -First 1
    if($matchingObject -ne $null)
    {
        Write-Output "Scaling schedule found. Check if current unit count is matching..." | timestamp
        if($signalR.Sku.Capacity -ne $matchingObject.Units)
        {
            Write-Output "SignalR doesn't match the units of the scaling schedule. Changing!" | timestamp
            $signalR = Update-AzSignalR -ResourceGroupName $resourceGroupName -Name $signalRServiceName -UnitCount $matchingObject.Units | out-null
            $signalR = Get-AzSignalR -ResourceGroupName $resourceGroupName -Name $signalRServiceName 
            Write-Output "Current SignalR ProvisioningState: $($signalR.ProvisioningState), sku: $($signalR.Sku.Name), units: $($signalR.Sku.Capacity)" | timestamp
        }
        else
        {
            Write-Output "Current SignalR unit count matches the scaling schedule already. Exiting..." | timestamp
        }
    }
    else { # Scaling schedule not found for current time
        Write-Output "No matching scaling schedule time slot for this time found. Check if current unit count matches the default..." | timestamp
        if($signalR.Sku.Capacity -ne $defaultUnits)
        {
            Write-Output "SignalR unit cout doesn't match the default. Changing!" | timestamp
            $signalR = Update-AzSignalR -ResourceGroupName $resourceGroupName -Name $signalRServiceName -UnitCount $defaultUnits | out-null
            $signalR = Get-AzSignalR -ResourceGroupName $resourceGroupName -Name $signalRServiceName 
            Write-Output "Current SignalR ProvisioningState: $($signalR.ProvisioningState), sku: $($signalR.Sku.Name), units: $($signalR.Sku.Capacity)" | timestamp
        }
        else
        {
            Write-Output "Current SignalR unit count matches the default already. Exiting..." | timestamp
        }
    }
}
else # Scaling schedule not found for this day
{
    Write-Output "No matching scaling schedule for this day found. Check if unit count matches the default..." | timestamp
    if($signalR.Sku.Capacity -ne $defaultUnits)
    {
        Write-Output "SignalR unit cout doesn't match the default. Changing!" | timestamp
        $signalR = Update-AzSignalR -ResourceGroupName $resourceGroupName -Name $signalRServiceName -UnitCount $defaultUnits | out-null
        $signalR = Get-AzSignalR -ResourceGroupName $resourceGroupName -Name $signalRServiceName 
        Write-Output "Current SignalR ProvisioningState: $($signalR.ProvisioningState), sku: $($signalR.Sku.Name), units: $($signalR.Sku.Capacity)" | timestamp
    }
    else
    {
        Write-Output "Current SignalR unit count matches the default already. Exiting..." | timestamp
    }
}

Write-Output "Script finished." | timestamp