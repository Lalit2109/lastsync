<# 
    Script: check-geo-replication.ps1

    Purpose:
      - Enumerate Storage Accounts across one or more subscriptions
      - For geo-replicated accounts, read blob service geo-replication stats
      - Compute lag in minutes from LastSyncTime
      - Send a consolidated email via SendGrid

    Notes:
      - Expected to run inside Azure Pipelines using an AzurePowerShell task
        that already logged in via an Azure Resource Manager service connection.
      - Requires Az.Accounts and Az.Storage modules on the agent.
      - Requires Az.Storage module version 1.11.0 or later for -IncludeGeoReplicationStats parameter.
      - Reference: https://learn.microsoft.com/en-us/azure/storage/common/last-sync-time-get?tabs=azure-powershell
#>

param(
    [Parameter(Mandatory = $true)]
    [int] $ThresholdMinutes,

    [Parameter(Mandatory = $true)]
    [string] $SendGridApiKey,

    [Parameter(Mandatory = $true)]
    [string] $SendGridFrom,

    [Parameter(Mandatory = $true)]
    [string] $SendGridTo,

    [Parameter(Mandatory = $false)]
    [ValidateSet("alert", "report")]
    [string] $Mode = "alert",

    [Parameter(Mandatory = $false)]
    [string] $Environment = "Prod",

    [Parameter(Mandatory = $false)]
    [string] $LogAnalyticsWorkspaceId,

    [Parameter(Mandatory = $false)]
    [string] $LogAnalyticsSharedKey
)

Write-Host "Starting geo-replication check. Mode=$Mode ThresholdMinutes=$ThresholdMinutes Environment=$Environment"

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    throw "Az.Accounts module is required on the agent."
}
if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
    throw "Az.Storage module is required on the agent."
}

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Storage -ErrorAction Stop

# Auto-discover all accessible subscriptions
Write-Host "Discovering all accessible subscriptions..."
$subscriptions = Get-AzSubscription -ErrorAction Stop
if (-not $subscriptions -or $subscriptions.Count -eq 0) {
    throw "No subscriptions found. Ensure the service connection has Reader access to subscriptions."
}
$subscriptionIds = $subscriptions | ForEach-Object { $_.Id }
Write-Host "Found $($subscriptionIds.Count) subscription(s): $($subscriptionIds -join ', ')"

$nowUtc = [DateTime]::UtcNow

$results = @()

foreach ($subId in $subscriptionIds) {
    Write-Host "Processing subscription $subId"
    Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

    $storageAccounts = Get-AzStorageAccount -ErrorAction Stop
    foreach ($sa in $storageAccounts) {
        # Get SKU name from the nested Sku object
        $sku = $sa.Sku.Name
        if (-not $sku) {
            Write-Warning "No SKU found for account $($sa.StorageAccountName) in subscription $subId"
            continue
        }

        # Determine if geo-replication is enabled (all types)
        # RAGRS = Read-Access Geo-Redundant Storage
        # RAGZRS = Read-Access Geo-Zone-Redundant Storage  
        # GZRS = Geo-Zone-Redundant Storage
        # GRS = Geo-Redundant Storage (without read access, but still geo-replicated)
        $isGeoReplicated = $sku -match "(?i)(RAGRS|RAGZRS|GZRS|GRS)"
        $hasReadAccess = $sku -match "(?i)(RAGRS|RAGZRS|GZRS)"  # Keep for reporting, but not used for filtering

        Write-Host "Processing account $($sa.StorageAccountName) - SKU: $sku (GeoReplicated: $isGeoReplicated, ReadAccess: $hasReadAccess)"

        $result = [PSCustomObject]@{
            SubscriptionId    = $subId
            ResourceGroup     = $sa.ResourceGroupName
            StorageAccount    = $sa.StorageAccountName
            Location          = $sa.Location
            SkuName           = $sku
            IsGeoReplicated   = $isGeoReplicated
            HasReadAccess     = $hasReadAccess
            GeoStatus         = $null
            LastSyncTimeUtc   = $null
            LagMinutes        = $null
            IsOverThreshold   = $false
            ThresholdMinutes  = $ThresholdMinutes
            Environment       = $Environment
        }

        # Get geo-replication stats for ALL geo-replicated accounts (GRS, RA-GRS, GZRS, RA-GZRS)
        if ($isGeoReplicated) {
            try {
                # Get geo-replication stats using the official PowerShell method
                # Reference: https://learn.microsoft.com/en-us/azure/storage/common/last-sync-time-get?tabs=azure-powershell
                # Requires Az.Storage module version 1.11.0 or later
                # This works for both GRS and RA-GRS accounts
                $storageAccountWithStats = Get-AzStorageAccount -ResourceGroupName $sa.ResourceGroupName `
                    -Name $sa.StorageAccountName `
                    -IncludeGeoReplicationStats `
                    -ErrorAction Stop
                
                if ($storageAccountWithStats) {
                    $geoReplicationStats = $storageAccountWithStats.GeoReplicationStats
                    if ($geoReplicationStats) {
                        $lastSync = $geoReplicationStats.LastSyncTime
                        if ($lastSync) {
                            $lagMinutes = [math]::Round(($nowUtc - $lastSync.ToUniversalTime()).TotalMinutes, 2)
                            # Check threshold for all geo-replicated accounts
                            $isOverThreshold = $lagMinutes -gt $ThresholdMinutes
                            
                            $result.GeoStatus = $geoReplicationStats.Status
                            if (-not $result.GeoStatus) {
                                $result.GeoStatus = "Unknown"
                            }
                            $result.LastSyncTimeUtc = $lastSync.ToUniversalTime().ToString("u")
                            $result.LagMinutes = $lagMinutes
                            $result.IsOverThreshold = $isOverThreshold
                        }
                    }
                }
            }
            catch {
                Write-Warning "Failed to get geo stats for account $($sa.StorageAccountName) in subscription $subId. $_"
                $result.GeoStatus = "Error"
            }
        }
        else {
            # For non-geo-replicated accounts only (LRS, ZRS, Premium_LRS, etc.)
            $result.GeoStatus = "NotEnabled"
        }

        $results += $result
    }
}

if (-not $results) {
    Write-Host "No storage accounts found across the specified subscriptions."
    if ($Mode -eq "report") {
        # Still send an empty report if desired
        Write-Host "Mode=report and no accounts found. Sending empty report."
    }
    else {
        Write-Host "Mode=alert and no accounts found. Exiting without email."
        return
    }
}

Write-Host "Total storage accounts evaluated: $($results.Count)"
$geoReplicatedCount = ($results | Where-Object { $_.IsGeoReplicated -eq $true }).Count
$withReadAccessCount = ($results | Where-Object { $_.HasReadAccess -eq $true }).Count
Write-Host "  - Geo-replicated: $geoReplicatedCount"
Write-Host "  - With read access (monitored): $withReadAccessCount"

# Send data to Log Analytics if configured (optional - sends ALL accounts)
if ($LogAnalyticsWorkspaceId -and $LogAnalyticsSharedKey -and $results.Count -gt 0) {
    Write-Host "Preparing data for Log Analytics..."
    
    # Import the Log Analytics module
    $scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
    $logAnalyticsModule = Join-Path $scriptPath "Send-LogAnalytics.ps1"
    if (Test-Path $logAnalyticsModule) {
        . $logAnalyticsModule
        
        # Transform results to Log Analytics format (generic InfraMonitoring_CL table)
        # Include ALL storage accounts (not just geo-replicated ones)
        $logAnalyticsData = $results | ForEach-Object {
            @{
                TimeGenerated = [DateTime]::UtcNow.ToString("o")
                ServiceType_s = "StorageGeoReplication"
                SubscriptionId_s = $_.SubscriptionId
                ResourceGroup_s = $_.ResourceGroup
                ResourceName_s = $_.StorageAccount
                ResourceType_s = "Microsoft.Storage/storageAccounts"
                PrimaryLocation_s = $_.Location
                SkuName_s = $_.SkuName
                IsGeoReplicated_b = $_.IsGeoReplicated
                HasReadAccess_b = $_.HasReadAccess
                GeoReplicationStatus_s = if ($_.GeoStatus) { $_.GeoStatus } else { "N/A" }
                LastSyncTime_t = if ($_.LastSyncTimeUtc) { $_.LastSyncTimeUtc } else { $null }
                LagMinutes_d = if ($_.LagMinutes) { $_.LagMinutes } else { $null }
                IsOverThreshold_b = $_.IsOverThreshold
                ThresholdMinutes_d = $_.ThresholdMinutes
                Environment_s = $_.Environment
                RunId_s = if ($env:BUILD_BUILDID) { "$($env:BUILD_BUILDID)-$($env:BUILD_BUILDNUMBER)" } else { "manual-$(Get-Date -Format 'yyyyMMddHHmmss')" }
            }
        }
        
        $logSent = Send-ToLogAnalytics -WorkspaceId $LogAnalyticsWorkspaceId -SharedKey $LogAnalyticsSharedKey -Data $logAnalyticsData -LogType "InfraMonitoring"
        if ($logSent) {
            Write-Host "Data successfully sent to Log Analytics workspace ($($logAnalyticsData.Count) records)"
        }
    }
    else {
        Write-Warning "Log Analytics module not found at $logAnalyticsModule. Skipping Log Analytics upload."
    }
}
else {
    if (-not $LogAnalyticsWorkspaceId -or -not $LogAnalyticsSharedKey) {
        Write-Host "Log Analytics not configured (WorkspaceId or SharedKey not provided). Skipping Log Analytics upload."
    }
}

# Filter to only geo-replicated accounts for email reporting
# Note: Log Analytics receives ALL accounts (both geo-replicated and non-geo-replicated)
$geoReplicatedAccounts = $results | Where-Object { $_.IsGeoReplicated -eq $true }

# For email alerts, consider only geo-replicated accounts that are over threshold
$overThreshold = $geoReplicatedAccounts | Where-Object { $_.IsOverThreshold -eq $true }

if ($Mode -eq "alert" -and -not $overThreshold) {
    Write-Host "Mode=alert and no geo-replicated accounts over threshold. No email will be sent."
    return
}

# In report mode, if no geo-replicated accounts exist, exit without email
if ($Mode -eq "report" -and -not $geoReplicatedAccounts) {
    Write-Host "Mode=report but no geo-replicated accounts found. Exiting without email."
    return
}

function New-HtmlTable {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IEnumerable] $Data,

        [Parameter(Mandatory = $true)]
        [string] $ThresholdLabel,

        [Parameter(Mandatory = $true)]
        [string] $Mode
    )

    $rows = ""
    foreach ($r in $Data) {
        $highlight = if ($r.IsOverThreshold) { " style='background-color:#ffcccc;'" } else { "" }
        $geoStatus = if ($r.GeoStatus) { $r.GeoStatus } else { "N/A" }
        $lastSync = if ($r.LastSyncTimeUtc) { $r.LastSyncTimeUtc } else { "N/A" }
        $lagMinutes = if ($r.LagMinutes) { $r.LagMinutes.ToString("F2") } else { "N/A" }
        $rows += "<tr$highlight>" +
                 "<td>$($r.SubscriptionId)</td>" +
                 "<td>$($r.ResourceGroup)</td>" +
                 "<td>$($r.StorageAccount)</td>" +
                 "<td>$($r.Location)</td>" +
                 "<td>$($r.SkuName)</td>" +
                 "<td>$geoStatus</td>" +
                 "<td>$lastSync</td>" +
                 "<td>$lagMinutes</td>" +
                 "<td>$($r.ThresholdMinutes)</td>" +
                 "</tr>"
    }

    $title = if ($Mode -eq "alert") {
        "Storage accounts with geo-replication lag over $ThresholdLabel minutes"
    }
    else {
        "Storage account geo-replication status report (threshold: $ThresholdLabel minutes)"
    }

    $html = @"
<h2>$title</h2>
<p>Environment: $Environment</p>
<p>Run time (UTC): $($nowUtc.ToString("u"))</p>
<table border="1" cellspacing="0" cellpadding="3">
  <tr>
    <th>Subscription</th>
    <th>Resource Group</th>
    <th>Storage Account</th>
    <th>Location</th>
    <th>SKU</th>
    <th>Geo Status</th>
    <th>Last Sync (UTC)</th>
    <th>Lag (min)</th>
    <th>Threshold (min)</th>
  </tr>
  $rows
</table>
"@

    return $html
}

# Email reports only include geo-replicated accounts (for both alert and report modes)
# Log Analytics already receives all accounts above
if ($Mode -eq "alert") {
    $emailData = $overThreshold
}
else {
    # Report mode: include all geo-replicated accounts (not just those over threshold)
    $emailData = $geoReplicatedAccounts
}

if (-not $emailData -or $emailData.Count -eq 0) {
    Write-Host "No geo-replicated accounts to include in email. Exiting."
    return
}

$htmlBody = New-HtmlTable -Data $emailData -ThresholdLabel $ThresholdMinutes -Mode $Mode

# Build SendGrid payload
$subjectPrefix = "[Storage Geo-Replication]"
if ($Environment) {
    $subjectPrefix = "[$Environment] Storage Geo-Replication"
}

if ($Mode -eq "alert") {
    $subject = "$subjectPrefix ALERT - $($emailData.Count) accounts over $ThresholdMinutes minutes"
}
else {
    $subject = "$subjectPrefix Status Report"
}

$toList = $SendGridTo.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries).ForEach({ $_.Trim() }) | Where-Object { $_ }
if (-not $toList -or $toList.Count -eq 0) {
    throw "SendGridTo is empty after parsing. Provide at least one recipient email address."
}

$personalizations = @(
    @{
        to = @($toList | ForEach-Object { @{ email = $_ } })
        subject = $subject
    }
)

$sgBody = @{
    personalizations = $personalizations
    from             = @{ email = $SendGridFrom }
    content          = @(
        @{
            type  = "text/html"
            value = $htmlBody
        }
    )
}

$sgJson = $sgBody | ConvertTo-Json -Depth 10

Write-Host "Sending email via SendGrid to $SendGridTo"

$headers = @{
    "Authorization" = "Bearer $SendGridApiKey"
    "Content-Type"  = "application/json"
}

try {
    $response = Invoke-RestMethod -Method Post -Uri "https://api.sendgrid.com/v3/mail/send" -Headers $headers -Body $sgJson -ErrorAction Stop
    Write-Host "SendGrid email request completed."
}
catch {
    Write-Error "Failed to send email via SendGrid. $_"
    throw
}


