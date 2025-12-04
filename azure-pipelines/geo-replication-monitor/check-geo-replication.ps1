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
    [string] $SubscriptionsCsv,

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
    [string] $Environment = "Prod"
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

$subscriptionIds = $SubscriptionsCsv.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries).ForEach({ $_.Trim() })
if (-not $subscriptionIds -or $subscriptionIds.Count -eq 0) {
    throw "No subscription IDs provided. Set SubscriptionsCsv to a comma-separated list of subscriptions."
}

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

        # Only consider geo-replicated SKUs with read access to secondary
        # RAGRS = Read-Access Geo-Redundant Storage
        # RAGZRS = Read-Access Geo-Zone-Redundant Storage  
        # GZRS = Geo-Zone-Redundant Storage (also has read access)
        # Note: GRS (without RA) is NOT included as it doesn't provide LastSyncTime via blob stats API
        if ($sku -notmatch "(?i)(RAGRS|RAGZRS|GZRS)") {
            Write-Host "Skipping account $($sa.StorageAccountName) - SKU '$sku' is not geo-replicated with read access"
            continue
        }

        Write-Host "Processing account $($sa.StorageAccountName) - SKU: $sku"

        try {
            # Get geo-replication stats using the official PowerShell method
            # Reference: https://learn.microsoft.com/en-us/azure/storage/common/last-sync-time-get?tabs=azure-powershell
            # Requires Az.Storage module version 1.11.0 or later
            $storageAccountWithStats = Get-AzStorageAccount -ResourceGroupName $sa.ResourceGroupName `
                -Name $sa.StorageAccountName `
                -IncludeGeoReplicationStats `
                -ErrorAction Stop
            
            if (-not $storageAccountWithStats) {
                Write-Warning "Failed to get storage account with stats for $($sa.StorageAccountName) in subscription $subId"
                continue
            }
            
            $geoReplicationStats = $storageAccountWithStats.GeoReplicationStats
            if (-not $geoReplicationStats) {
                Write-Warning "No GeoReplicationStats for account $($sa.StorageAccountName) in subscription $subId"
                continue
            }
            
            $lastSync = $geoReplicationStats.LastSyncTime
            if (-not $lastSync) {
                Write-Warning "No LastSyncTime for account $($sa.StorageAccountName) in subscription $subId"
                continue
            }

            $lagMinutes = [math]::Round(($nowUtc - $lastSync.ToUniversalTime()).TotalMinutes, 2)
            $isOverThreshold = $lagMinutes -gt $ThresholdMinutes
            
            # Get geo-replication status from GeoReplicationStats
            $geoStatus = $geoReplicationStats.Status
            if (-not $geoStatus) {
                $geoStatus = "Unknown"
            }

            $result = [PSCustomObject]@{
                SubscriptionId    = $subId
                ResourceGroup     = $sa.ResourceGroupName
                StorageAccount    = $sa.StorageAccountName
                Location          = $sa.Location
                SkuName           = $sku
                GeoStatus         = $geoStatus
                LastSyncTimeUtc   = $lastSync.ToUniversalTime().ToString("u")
                LagMinutes        = $lagMinutes
                IsOverThreshold   = $isOverThreshold
                ThresholdMinutes  = $ThresholdMinutes
                Environment       = $Environment
            }

            $results += $result
        }
        catch {
            Write-Warning "Failed to get geo stats for account $($sa.StorageAccountName) in subscription $subId. $_"
        }
    }
}

if (-not $results) {
    Write-Host "No geo-replicated storage accounts found across the specified subscriptions."
    if ($Mode -eq "report") {
        # Still send an empty report if desired
        Write-Host "Mode=report and no accounts found. Sending empty report."
    }
    else {
        Write-Host "Mode=alert and no accounts found. Exiting without email."
        return
    }
}

Write-Host "Total geo-replicated accounts evaluated: $($results.Count)"

$overThreshold = $results | Where-Object { $_.IsOverThreshold -eq $true }

if ($Mode -eq "alert" -and -not $overThreshold) {
    Write-Host "Mode=alert and no accounts over threshold. No email will be sent."
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
        $rows += "<tr$highlight>" +
                 "<td>$($r.SubscriptionId)</td>" +
                 "<td>$($r.ResourceGroup)</td>" +
                 "<td>$($r.StorageAccount)</td>" +
                 "<td>$($r.Location)</td>" +
                 "<td>$($r.SkuName)</td>" +
                 "<td>$($r.GeoStatus)</td>" +
                 "<td>$($r.LastSyncTimeUtc)</td>" +
                 "<td>$($r.LagMinutes)</td>" +
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

if ($Mode -eq "alert") {
    $emailData = $overThreshold
}
else {
    $emailData = $results
}

if (-not $emailData -or $emailData.Count -eq 0) {
    Write-Host "No rows to include in email (this should only happen in report mode with no accounts). Exiting."
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


