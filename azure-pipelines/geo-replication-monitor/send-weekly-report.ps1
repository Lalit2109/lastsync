<# 
    Script: send-weekly-report.ps1

    Purpose:
      - Query Log Analytics for last 7 days of geo-replication data
      - Generate comprehensive weekly email report with detailed metrics
      - Send email via SendGrid every Monday at 10 AM

    Notes:
      - Expected to run inside Azure Pipelines using an AzurePowerShell task
      - Requires Az.Accounts and Az.OperationalInsights modules on the agent
      - Queries StorageGeoReplication_CL table in Log Analytics using Az.OperationalInsights cmdlets
      - Uses same Azure context authentication as the rest of the pipeline (no manual token management)
      - Uses same SendGrid configuration as check-geo-replication.ps1
      - Note: LogAnalyticsSharedKey parameter is not used for querying (only needed for sending data)
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
| extend MaxLag = round(coalesce(MaxLag, 0.0), 2)
| extend AvgLag = round(coalesce(AvgLag, 0.0), 2)
| extend MinLag = round(coalesce(MinLag, 0.0), 2)
| order by MaxLag desc, AvgLag desc
"@

try {
    # Verify Azure context is available
    Write-Host "Verifying Azure context..."
    $context = Get-AzContext
    if (-not $context) {
        throw "No Azure context found. Please ensure you are logged in via Azure PowerShell task."
    }
    Write-Host "Azure context verified: Account=$($context.Account.Id), Subscription=$($context.Subscription.Id)"

    # Execute query using Az.OperationalInsights PowerShell cmdlet
    # This uses the same Azure context authentication as the rest of the script
    Write-Host "Executing KQL query using Az.OperationalInsights module..."
    Write-Host "Workspace ID: $LogAnalyticsWorkspaceId"
    $timespan = New-TimeSpan -Days 7
    Write-Host "Timespan: $timespan"
    
    $queryResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $LogAnalyticsWorkspaceId -Timespan $timespan -Query $kqlQuery -ErrorAction Stop
    
    # Initialize reportData
    $reportData = @()
    
    # Debug: Check the structure of the result
    if ($null -eq $queryResult) {
        Write-Warning "Query returned null result."
    }
    else {
        Write-Host "QueryResult type: $($queryResult.GetType().FullName)"
        
        # Check if queryResult is an array (shouldn't be, but handle it)
        if ($queryResult -is [Array]) {
            Write-Host "QueryResult is an array with $($queryResult.Count) items"
            $reportData = @($queryResult)
        }
        else {
            # Check for properties
            $memberInfo = $queryResult | Get-Member -MemberType Property -ErrorAction SilentlyContinue
            if ($memberInfo) {
                $properties = $memberInfo | Select-Object -ExpandProperty Name
                Write-Host "QueryResult properties: $($properties -Join ', ')"
            }
            
            # Check for errors first
            if ($queryResult.PSObject.Properties['Error'] -and $queryResult.Error) {
                Write-Warning "Query returned an error: $($queryResult.Error)"
            }
            # Extract results - the cmdlet returns results in the Results property
            elseif ($queryResult.PSObject.Properties['Results']) {
                $results = $queryResult.Results
                if ($null -ne $results) {
                    $reportData = @($results)
                    try {
                        $count = $reportData.Count
                        Write-Host "Query returned $count storage accounts"
                    }
                    catch {
                        Write-Host "Query returned results (count check failed: $_)"
                    }
                }
                else {
                    Write-Warning "Results property is null."
                }
            }
            else {
                Write-Warning "QueryResult does not have a Results property. Using queryResult directly."
                $reportData = @($queryResult)
            }
        }
    }
}
catch {
    Write-Error "Failed to query Log Analytics: $_"
    Write-Error "Exception type: $($_.Exception.GetType().FullName)"
    Write-Error "Stack trace: $($_.ScriptStackTrace)"
    throw
}

# Ensure reportData is always an array
if ($null -eq $reportData) {
    $reportData = @()
}

# Safely check count
$reportDataCount = 0
try {
    if ($reportData -is [Array]) {
        $reportDataCount = $reportData.Count
    }
    elseif ($reportData) {
        $reportDataCount = 1
    }
}
catch {
    Write-Warning "Error getting reportData count: $_"
    $reportDataCount = 0
}

if ($reportDataCount -eq 0) {
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
    $totalAccounts = $reportDataCount
    $accountsOverThreshold = ($reportData | Where-Object { $_.MaxLag -gt $ThresholdMinutes }).Count
    $accountsOverThresholdPercent = [math]::Round(($accountsOverThreshold * 100.0 / $totalAccounts), 1)
    $avgLagAcrossAll = [math]::Round(($reportData | Measure-Object -Property AvgLag -Average).Average, 2)
    $maxLagAcrossAll = [math]::Round(($reportData | Measure-Object -Property MaxLag -Maximum).Maximum, 2)
    $totalOverThresholdEvents = ($reportData | Measure-Object -Property TimesOverThreshold -Sum).Sum

    Write-Host "Summary Statistics:"
    Write-Host "  - Total Accounts: $totalAccounts"
    Write-Host "  - Accounts with Max Lag Over Threshold: $accountsOverThreshold ($accountsOverThresholdPercent%)"
    Write-Host "  - Average Lag (7 days): $avgLagAcrossAll minutes"
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
    <td>Accounts with Max Lag Over Threshold (Last 7 Days)</td>
    <td><strong style="color: #ff0000;">$accountsOverThreshold ($accountsOverThresholdPercent%)</strong></td>
  </tr>
  <tr>
    <td>Average Lag (Last 7 Days - All Accounts)</td>
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
        $maxLag = if ($account.MaxLag) { [math]::Round([double]$account.MaxLag, 2) } else { 0.0 }
        $avgLag = if ($account.AvgLag) { [math]::Round([double]$account.AvgLag, 2) } else { 0.0 }
        $minLag = if ($account.MinLag) { [math]::Round([double]$account.MinLag, 2) } else { 0.0 }
        $timesOverThreshold = if ($account.TimesOverThreshold) { [int]$account.TimesOverThreshold } else { 0 }
        $totalChecks = if ($account.TotalChecks) { [int]$account.TotalChecks } else { 0 }
        $percentOverThreshold = if ($account.PercentOverThreshold) { [math]::Round([double]$account.PercentOverThreshold, 1) } else { 0.0 }
        $threshold = if ($account.ThresholdMinutes) { [int]$account.ThresholdMinutes } else { $ThresholdMinutes }
        $currentStatus = if ($account.CurrentStatus) { $account.CurrentStatus } else { "N/A" }
        $lastSyncTime = if ($account.LastSyncTime) { $account.LastSyncTime } else { "N/A" }

        # Determine row highlighting based on MaxLag
        $rowStyle = ""
        if ($maxLag -gt $threshold) {
            $rowStyle = " style='background-color:#ffcccc;'"
        }
        elseif ($maxLag -gt 0) {
            $rowStyle = " style='background-color:#fff4cc;'"
        }

        # Format lag values with color
        $maxLagDisplay = if ($maxLag -gt $threshold) {
            "<strong style='color:#ff0000;'>$maxLag</strong>"
        }
        elseif ($maxLag -gt 0) {
            "<span style='color:#ff8800;'>$maxLag</span>"
        }
        else {
            "<span style='color:#00aa00;'>$maxLag</span>"
        }

        $avgLagDisplay = if ($avgLag -gt $threshold) {
            "<span style='color:#ff8800;'>$avgLag</span>"
        }
        else {
            "$avgLag"
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
                     "<td>$maxLagDisplay</td>" +
                     "<td>$avgLagDisplay</td>" +
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
