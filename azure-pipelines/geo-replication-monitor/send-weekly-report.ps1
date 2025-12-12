<# 
    Script: send-weekly-report.ps1

    Purpose:
      - Query Log Analytics for last 7 days of geo-replication data
      - Generate comprehensive weekly email report with detailed metrics
      - Send email via SendGrid every Monday at 10 AM

    Notes:
      - Expected to run inside Azure Pipelines using an AzurePowerShell task
      - Requires Az.Accounts and Az.OperationalInsights modules on the agent
      - Queries StorageGeoReplication_CL table in Log Analytics
      - Uses same SendGrid configuration as check-geo-replication.ps1
#>

param(
    [Parameter(Mandatory = $true)]
    [string] $LogAnalyticsWorkspaceId,

    [Parameter(Mandatory = $true)]
    [string] $LogAnalyticsSharedKey,

    [Parameter(Mandatory = $true)]
    [string] $SendGridApiKey,

    [Parameter(Mandatory = $true)]
    [string] $SendGridFrom,

    [Parameter(Mandatory = $true)]
    [string] $SendGridTo,

    [Parameter(Mandatory = $false)]
    [string] $Environment = "Prod",

    [Parameter(Mandatory = $false)]
    [int] $ThresholdMinutes = 30
)

Write-Host "Starting weekly geo-replication report. Environment=$Environment ThresholdMinutes=$ThresholdMinutes"

# Check for required modules
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    throw "Az.Accounts module is required on the agent."
}
if (-not (Get-Module -ListAvailable -Name Az.OperationalInsights)) {
    throw "Az.OperationalInsights module is required on the agent."
}

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.OperationalInsights -ErrorAction Stop

$nowUtc = [DateTime]::UtcNow
$sevenDaysAgo = $nowUtc.AddDays(-7)

Write-Host "Querying Log Analytics for data from last 7 days (since $($sevenDaysAgo.ToString('u')))"

# KQL Query to get 7-day historical data with aggregations
# Note: Using double suffixes (_s_s, _b_b, _d_d) as they appear in the actual Log Analytics table
$kqlQuery = @"
StorageGeoReplication_CL
| where ServiceType_s_s == "StorageGeoReplication"
| where TimeGenerated > ago(7d)
| where IsGeoReplicated_b_b == true
| where HasReadAccess_b_b == true
| summarize 
    CurrentLag = toreal(arg_max(TimeGenerated, LagMinutes_d_d)),
    MaxLag = max(LagMinutes_d_d),
    AvgLag = avg(LagMinutes_d_d),
    MinLag = min(LagMinutes_d_d),
    TimesOverThreshold = countif(IsOverThreshold_b_b == true),
    TotalChecks = count(),
    CurrentStatus = arg_max(TimeGenerated, GeoReplicationStatus_s_s),
    SubscriptionId = any(SubscriptionId_s_s),
    ResourceGroup = any(ResourceGroup_s_s),
    Location = any(PrimaryLocation_s_s),
    SkuName = any(SkuName_s_s),
    ThresholdMinutes = any(ThresholdMinutes_d_d),
    LastSyncTime = arg_max(TimeGenerated, LastSyncTime_t_t)
    by ResourceName_s_s
| extend PercentOverThreshold = round((TimesOverThreshold * 100.0 / TotalChecks), 1)
| extend CurrentLag = round(iff(isnull(CurrentLag), 0.0, CurrentLag), 2)
| extend MaxLag = round(coalesce(MaxLag, 0.0), 2)
| extend AvgLag = round(coalesce(AvgLag, 0.0), 2)
| extend MinLag = round(coalesce(MinLag, 0.0), 2)
| order by MaxLag desc, CurrentLag desc
"@

try {
    # Get access token from current Azure context
    Write-Host "Getting access token from Azure context..."
    $context = Get-AzContext
    if (-not $context) {
        throw "No Azure context found. Please ensure you are logged in via Azure PowerShell task."
    }

    # Get access token for Log Analytics API
    $resource = "https://api.loganalytics.io"
    $token = (Get-AzAccessToken -ResourceUrl $resource).Token

    if (-not $token) {
        throw "Failed to obtain access token for Log Analytics API."
    }

    # Execute query using Log Analytics REST API
    Write-Host "Executing KQL query via REST API..."
    $queryUri = "https://api.loganalytics.io/v1/workspaces/$LogAnalyticsWorkspaceId/query"

    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json"
    }

    $body = @{
        query = $kqlQuery
    } | ConvertTo-Json -Depth 3

    $response = Invoke-RestMethod -Method Post -Uri $queryUri -Headers $headers -Body $body -ErrorAction Stop

    # Parse response - Log Analytics REST API returns tables with rows
    if (-not $response -or -not $response.tables -or $response.tables.Count -eq 0) {
        Write-Warning "No data returned from Log Analytics query."
        $reportData = @()
    }
    else {
        # Convert table rows to objects
        $table = $response.tables[0]
        $columns = $table.columns | ForEach-Object { $_.name }
        $reportData = @()

        foreach ($row in $table.rows) {
            $obj = [PSCustomObject]@{}
            for ($i = 0; $i -lt $columns.Count; $i++) {
                $columnName = $columns[$i]
                $value = $row[$i]
                $obj | Add-Member -MemberType NoteProperty -Name $columnName -Value $value
            }
            $reportData += $obj
        }

        Write-Host "Query returned $($reportData.Count) storage accounts"
    }
}
catch {
    Write-Error "Failed to query Log Analytics: $_"
    throw
}

if (-not $reportData -or $reportData.Count -eq 0) {
    Write-Host "No geo-replicated storage accounts found in Log Analytics for the last 7 days."
    Write-Host "Sending empty report notification."
    
    $htmlBody = @"
<h2>Weekly Storage Account Geo-Replication Report - Last 7 Days</h2>
<p><strong>Environment:</strong> $Environment</p>
<p><strong>Report Period:</strong> $($sevenDaysAgo.ToString('u')) to $($nowUtc.ToString('u')) (UTC)</p>
<p><strong>Report Generated:</strong> $($nowUtc.ToString('u')) (UTC)</p>
<p><strong>Status:</strong> No geo-replicated storage accounts found in Log Analytics for the specified period.</p>
<p><em>This may indicate that no monitoring data has been collected, or all accounts are non-geo-replicated.</em></p>
"@
}
else {
    # Calculate summary statistics
    $totalAccounts = $reportData.Count
    $accountsOverThreshold = ($reportData | Where-Object { $_.CurrentLag -gt $ThresholdMinutes }).Count
    $accountsOverThresholdPercent = [math]::Round(($accountsOverThreshold * 100.0 / $totalAccounts), 1)
    $avgLagAcrossAll = [math]::Round(($reportData | Measure-Object -Property CurrentLag -Average).Average, 2)
    $maxLagAcrossAll = [math]::Round(($reportData | Measure-Object -Property MaxLag -Maximum).Maximum, 2)
    $totalOverThresholdEvents = ($reportData | Measure-Object -Property TimesOverThreshold -Sum).Sum

    Write-Host "Summary Statistics:"
    Write-Host "  - Total Accounts: $totalAccounts"
    Write-Host "  - Accounts Over Threshold: $accountsOverThreshold ($accountsOverThresholdPercent%)"
    Write-Host "  - Average Lag (Current): $avgLagAcrossAll minutes"
    Write-Host "  - Max Lag (7 days): $maxLagAcrossAll minutes"
    Write-Host "  - Total Over-Threshold Events: $totalOverThresholdEvents"

    # Build HTML email body
    $summaryHtml = @"
<h2>Weekly Storage Account Geo-Replication Report - Last 7 Days</h2>
<p><strong>Environment:</strong> $Environment</p>
<p><strong>Report Period:</strong> $($sevenDaysAgo.ToString('u')) to $($nowUtc.ToString('u')) (UTC)</p>
<p><strong>Report Generated:</strong> $($nowUtc.ToString('u')) (UTC)</p>
<p><strong>Data Source:</strong> Azure Log Analytics (StorageGeoReplication_CL table)</p>

<h3>Summary Statistics</h3>
<table border="1" cellspacing="0" cellpadding="5" style="margin-bottom: 20px;">
  <tr>
    <th>Metric</th>
    <th>Value</th>
  </tr>
  <tr>
    <td>Total Geo-Replicated Accounts (Monitored)</td>
    <td><strong>$totalAccounts</strong></td>
  </tr>
  <tr>
    <td>Accounts Currently Over Threshold</td>
    <td><strong style="color: #ff0000;">$accountsOverThreshold ($accountsOverThresholdPercent%)</strong></td>
  </tr>
  <tr>
    <td>Average Current Lag (All Accounts)</td>
    <td><strong>$avgLagAcrossAll minutes</strong></td>
  </tr>
  <tr>
    <td>Maximum Lag (Last 7 Days)</td>
    <td><strong style="color: #ff0000;">$maxLagAcrossAll minutes</strong></td>
  </tr>
  <tr>
    <td>Total Over-Threshold Events (Last 7 Days)</td>
    <td><strong>$totalOverThresholdEvents</strong></td>
  </tr>
</table>

<h3>Detailed Account Report</h3>
<p>The following table shows metrics for each storage account over the last 7 days:</p>
"@

    # Build detailed table
    $tableRows = ""
    foreach ($account in $reportData) {
        $currentLag = if ($account.CurrentLag) { [math]::Round([double]$account.CurrentLag, 2) } else { 0.0 }
        $maxLag = if ($account.MaxLag) { [math]::Round([double]$account.MaxLag, 2) } else { 0.0 }
        $avgLag = if ($account.AvgLag) { [math]::Round([double]$account.AvgLag, 2) } else { 0.0 }
        $minLag = if ($account.MinLag) { [math]::Round([double]$account.MinLag, 2) } else { 0.0 }
        $timesOverThreshold = if ($account.TimesOverThreshold) { [int]$account.TimesOverThreshold } else { 0 }
        $totalChecks = if ($account.TotalChecks) { [int]$account.TotalChecks } else { 0 }
        $percentOverThreshold = if ($account.PercentOverThreshold) { [math]::Round([double]$account.PercentOverThreshold, 1) } else { 0.0 }
        $threshold = if ($account.ThresholdMinutes) { [int]$account.ThresholdMinutes } else { $ThresholdMinutes }
        $currentStatus = if ($account.CurrentStatus) { $account.CurrentStatus } else { "N/A" }
        $lastSyncTime = if ($account.LastSyncTime) { $account.LastSyncTime } else { "N/A" }

        # Determine row highlighting
        $rowStyle = ""
        if ($currentLag -gt $threshold) {
            $rowStyle = " style='background-color:#ffcccc;'"
        }
        elseif ($currentLag -gt 0) {
            $rowStyle = " style='background-color:#fff4cc;'"
        }

        # Format lag values with color
        $currentLagDisplay = if ($currentLag -gt $threshold) {
            "<strong style='color:#ff0000;'>$currentLag</strong>"
        }
        elseif ($currentLag -gt 0) {
            "<span style='color:#ff8800;'>$currentLag</span>"
        }
        else {
            "<span style='color:#00aa00;'>$currentLag</span>"
        }

        $maxLagDisplay = if ($maxLag -gt $threshold) {
            "<strong style='color:#ff0000;'>$maxLag</strong>"
        }
        else {
            "$maxLag"
        }

        $subscriptionId = if ($account.SubscriptionId) { $account.SubscriptionId } else { "N/A" }
        $resourceGroup = if ($account.ResourceGroup) { $account.ResourceGroup } else { "N/A" }
        $resourceName = if ($account.ResourceName_s_s) { $account.ResourceName_s_s } else { "N/A" }
        $location = if ($account.Location) { $account.Location } else { "N/A" }
        $skuName = if ($account.SkuName) { $account.SkuName } else { "N/A" }

        $tableRows += "<tr$rowStyle>" +
                     "<td>$subscriptionId</td>" +
                     "<td>$resourceGroup</td>" +
                     "<td><strong>$resourceName</strong></td>" +
                     "<td>$location</td>" +
                     "<td>$skuName</td>" +
                     "<td>$currentStatus</td>" +
                     "<td>$lastSyncTime</td>" +
                     "<td>$currentLagDisplay</td>" +
                     "<td>$maxLagDisplay</td>" +
                     "<td>$avgLag</td>" +
                     "<td>$minLag</td>" +
                     "<td>$timesOverThreshold / $totalChecks</td>" +
                     "<td>$percentOverThreshold%</td>" +
                     "<td>$threshold</td>" +
                     "</tr>"
    }

    $tableHtml = @"
<table border="1" cellspacing="0" cellpadding="5" style="width: 100%;">
  <tr style="background-color:#e0e0e0;">
    <th>Subscription</th>
    <th>Resource Group</th>
    <th>Storage Account</th>
    <th>Location</th>
    <th>SKU</th>
    <th>Geo Status</th>
    <th>Last Sync Time</th>
    <th>Current Lag (min)</th>
    <th>Max Lag (7d) (min)</th>
    <th>Avg Lag (7d) (min)</th>
    <th>Min Lag (7d) (min)</th>
    <th>Over Threshold (count/total)</th>
    <th>% Over Threshold</th>
    <th>Threshold (min)</th>
  </tr>
  $tableRows
</table>
"@

    $htmlBody = $summaryHtml + $tableHtml
}

# Build SendGrid payload
$subjectPrefix = "[$Environment] Storage Geo-Replication"
$subject = "$subjectPrefix - Weekly Report (Last 7 Days)"

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
    Write-Host "SendGrid email request completed successfully."
    Write-Host "Weekly report sent to $($toList.Count) recipient(s)."
}
catch {
    Write-Error "Failed to send email via SendGrid. $_"
    throw
}

Write-Host "Weekly report generation completed."
