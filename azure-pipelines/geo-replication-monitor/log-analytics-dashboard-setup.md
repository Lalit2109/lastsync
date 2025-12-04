# Log Analytics and Dashboard Setup Guide

This guide walks you through setting up Azure Log Analytics to collect geo-replication monitoring data and creating dashboards to visualize it.

## Overview

The PowerShell script sends monitoring data to a Log Analytics workspace using the **Data Collector API**. This data is stored in a custom table called `StorageGeoReplication_CL` (the `_CL` suffix indicates a custom log). This table is specifically designed for storage account geo-replication monitoring.

> **Important**: The script sends field names **without type suffixes** (e.g., `IsGeoReplicated`, `LagMinutes`). Log Analytics automatically adds the correct type suffixes based on the actual data types:
> - `_s` for strings (e.g., `ServiceType` becomes `ServiceType_s`)
> - `_b` for booleans (e.g., `IsGeoReplicated` becomes `IsGeoReplicated_b`)
> - `_d` for numbers (e.g., `LagMinutes` becomes `LagMinutes_d`)
> - `_t` for dates (e.g., `LastSyncTime` becomes `LastSyncTime_t`)
> 
> This ensures the schema is created correctly with single suffixes. All queries in this guide use the field names with single suffixes as they appear in Log Analytics.

## Step 1: Create or Identify Log Analytics Workspace

### Option A: Create a New Workspace (Recommended for Centralized Monitoring)

1. In Azure Portal, go to **Create a resource**
2. Search for **"Log Analytics workspace"**
3. Click **Create**
4. Fill in:
   - **Subscription**: Choose your subscription
   - **Resource Group**: Create new or use existing (e.g., `rg-infra-monitoring`)
   - **Name**: e.g., `law-infra-monitoring-prod`
   - **Region**: Choose a region close to your resources
5. Click **Review + create** → **Create**
6. Wait for deployment, then click **Go to resource**

### Option B: Use an Existing Workspace

If you already have a Log Analytics workspace for infrastructure monitoring, use that one.

## Step 2: Get Workspace ID and Shared Key

1. In your Log Analytics workspace, go to **Agents management** in the left menu
2. Under **Log Analytics agent instructions**, you'll see:
   - **Workspace ID**: Copy this value (looks like: `12345678-1234-1234-1234-123456789abc`)
   - **Primary key**: Click **Show** and copy the key (keep it secure!)

3. **Save these values** - you'll need them for the pipeline variables

## Step 3: Configure Pipeline Variables

In Azure DevOps, configure the Log Analytics variables:

1. Go to your pipeline → **Edit** → **Variables** (or use a Variable Group)
2. Add the following variables:

   ### Required Variables (if not already set):
   - `SendGridApiKey` (secret)
   - `SendGridFrom`
   - `SendGridTo`
   - `ThresholdMinutes`
   - `Mode`
   - `Environment`

   ### New Log Analytics Variables:
   - **`LogAnalyticsWorkspaceId`**:
     - Value: Your workspace ID (e.g., `12345678-1234-1234-1234-123456789abc`)
     - Type: Variable (not secret, but can be if you prefer)
   
   - **`LogAnalyticsSharedKey`**:
     - Value: Your workspace Primary key
     - Type: **Secret** (click the lock icon)
     - **Important**: Mark this as secret for security

3. **Alternative**: Update the YAML file directly:
   ```yaml
   variables:
     LogAnalyticsWorkspaceId: 'your-workspace-id-here'
     # LogAnalyticsSharedKey should be set as a secret in pipeline variables
   ```

## Step 4: Verify Data Collection

1. **Run the pipeline manually** once to test
2. Wait for the run to complete
3. Check the pipeline logs - you should see:
   ```
   Preparing data for Log Analytics...
   Successfully sent X records to Log Analytics workspace
   ```

4. **Verify data in Log Analytics**:
   - Go to your Log Analytics workspace → **Logs**
   - Run this query:
     ```kusto
     StorageGeoReplication_CL
     | where ServiceType_s == "StorageGeoReplication"
     | take 50
     ```
   - You should see records with columns like:
     - `SubscriptionId_s`, `ResourceName_s`, `LagMinutes_d`, `IsOverThreshold_b`, etc.
   - **Important**: Field names should have single suffixes (`_s`, `_b`, `_d`, `_t`). If you see double suffixes like `_s_s` or `_b_b`, the schema was created incorrectly. Use the new `StorageGeoReplication_CL` table instead.

## Step 5: Create KQL Queries for Dashboard Widgets

Here are the KQL queries for different dashboard widgets. Each widget shows a different view of your storage accounts.

### Widget 1: Storage Accounts with GRS Enabled (with Lag Status)

**Purpose**: Shows all accounts that have geo-replication enabled, with their current lag status. Accounts over threshold are highlighted.

```kusto
StorageGeoReplication_CL
| where ServiceType_s == "StorageGeoReplication"
| where TimeGenerated > ago(1h)
| where IsGeoReplicated_b == true
| summarize arg_max(TimeGenerated, *) by SubscriptionId_s, ResourceName_s
| project TimeGenerated, SubscriptionId_s, ResourceGroup_s, ResourceName_s, 
         Location = PrimaryLocation_s, SkuName_s, GeoReplicationStatus_s,
         LagMinutes_d, ThresholdMinutes_d, IsOverThreshold_b, Environment_s
| extend StatusColor = case(
    IsOverThreshold_b == true, "Red",
    LagMinutes_d > 0, "Yellow", 
    "Green")
| order by IsOverThreshold_b desc, LagMinutes_d desc nulls last
```

**Visualization**: Table with conditional formatting (red for over threshold, yellow for lag > 0, green for healthy)

### Widget 2: Storage Accounts with GRS NOT Enabled

**Purpose**: Lists all storage accounts that do NOT have geo-replication enabled.

```kusto
StorageGeoReplication_CL
| where ServiceType_s == "StorageGeoReplication"
| where TimeGenerated > ago(1h)
| where IsGeoReplicated_b == false
| summarize arg_max(TimeGenerated, *) by SubscriptionId_s, ResourceName_s
| project TimeGenerated, SubscriptionId_s, ResourceGroup_s, ResourceName_s,
         Location = PrimaryLocation_s, SkuName_s, Environment_s
| order by SubscriptionId_s, ResourceGroup_s, ResourceName_s
```

**Visualization**: Table

### Widget 3: Accounts Over Threshold (Alert View - Red Highlighted)

**Purpose**: Shows only accounts that are over the threshold, highlighted in red.

```kusto
StorageGeoReplication_CL
| where ServiceType_s == "StorageGeoReplication"
| where TimeGenerated > ago(1h)
| where IsGeoReplicated_b == true
| where HasReadAccess_b == true
| where IsOverThreshold_b == true
| summarize arg_max(TimeGenerated, *) by SubscriptionId_s, ResourceName_s
| project TimeGenerated, SubscriptionId_s, ResourceGroup_s, ResourceName_s,
         Location = PrimaryLocation_s, SkuName_s, GeoReplicationStatus_s,
         LagMinutes_d, ThresholdMinutes_d, Environment_s
| extend LagOverThreshold = LagMinutes_d - ThresholdMinutes_d
| order by LagOverThreshold desc
```

**Visualization**: Table (will appear red in dashboard if conditional formatting is applied)

### Widget 4: Summary Statistics

**Purpose**: Overview counts and percentages.

```kusto
StorageGeoReplication_CL
| where ServiceType_s == "StorageGeoReplication"
| where TimeGenerated > ago(1h)
| summarize arg_max(TimeGenerated, *) by SubscriptionId_s, ResourceName_s
| summarize 
    TotalAccounts = count(),
    GeoReplicated = countif(IsGeoReplicated_b == true),
    NotGeoReplicated = countif(IsGeoReplicated_b == false),
    WithReadAccess = countif(HasReadAccess_b == true),
    OverThreshold = countif(IsOverThreshold_b == true),
    Healthy = countif(HasReadAccess_b == true and IsOverThreshold_b == false)
| extend 
    GeoReplicationPercentage = round((GeoReplicated * 100.0 / TotalAccounts), 1),
    HealthPercentage = round((Healthy * 100.0 / WithReadAccess), 1)
| project TotalAccounts, GeoReplicated, NotGeoReplicated, WithReadAccess, 
         OverThreshold, Healthy, GeoReplicationPercentage, HealthPercentage
```

**Visualization**: Single row table or KPI cards

### Widget 5: Lag Trend Over Time (for Geo-Replicated Accounts)

**Purpose**: Shows average lag trend for accounts with read access.

```kusto
StorageGeoReplication_CL
| where ServiceType_s == "StorageGeoReplication"
| where TimeGenerated > ago(7d)
| where IsGeoReplicated_b == true
| where HasReadAccess_b == true
| where isnotnull(LagMinutes_d)
| summarize 
    AvgLag = avg(LagMinutes_d),
    MaxLag = max(LagMinutes_d),
    MinLag = min(LagMinutes_d)
    by bin(TimeGenerated, 1h), Environment_s
| render timechart
```

**Visualization**: Time chart

### Widget 6: Accounts by Geo-Replication Status (Donut Chart)

**Purpose**: Visual breakdown of accounts by status.

```kusto
StorageGeoReplication_CL
| where ServiceType_s == "StorageGeoReplication"
| where TimeGenerated > ago(1h)
| summarize arg_max(TimeGenerated, *) by SubscriptionId_s, ResourceName_s
| extend Status = case(
    IsOverThreshold_b == true, "Over Threshold",
    HasReadAccess_b == true and IsOverThreshold_b == false, "Healthy (Monitored)",
    IsGeoReplicated_b == true and HasReadAccess_b == false, "GRS (No Read Access)",
    "Not Geo-Replicated")
| summarize Count = count() by Status
| order by Count desc
```

**Visualization**: Donut or pie chart

### Widget 7: Top 10 Accounts by Lag (Last 24 Hours)

**Purpose**: Shows the worst-performing accounts.

```kusto
StorageGeoReplication_CL
| where ServiceType_s == "StorageGeoReplication"
| where TimeGenerated > ago(24h)
| where IsGeoReplicated_b == true
| where HasReadAccess_b == true
| where isnotnull(LagMinutes_d)
| summarize MaxLag = max(LagMinutes_d) by SubscriptionId_s, ResourceName_s, Environment_s
| top 10 by MaxLag desc
| project SubscriptionId_s, ResourceName_s, Environment_s, MaxLag
```

**Visualization**: Bar chart or table

## Step 6: Choose Your Visualization Method

Before creating your dashboard, you need to decide between **Azure Dashboard** and **Azure Workbook**. Here's a comparison to help you choose:

### Azure Dashboard vs Azure Workbook

#### What is Azure Dashboard?
- **What it is**: A simple, tile-based dashboard in the Azure Portal
- **Best for**: Quick visualizations, pinning existing charts/tiles, simple layouts
- **How to create**: Pin queries from Log Analytics directly to a dashboard

#### What is Azure Workbook?
- **What it is**: An interactive, parameterized reporting tool with advanced features
- **Best for**: Complex reports, interactive queries, parameters, multiple data sources, sharing with teams

### Comparison Table

| Feature | Azure Dashboard | Azure Workbook |
|---------|----------------|----------------|
| **Complexity** | Simple | More advanced |
| **Setup Time** | Faster (5 minutes) | More setup (15-20 minutes) |
| **Parameters** | Limited | Full support (dropdowns, time ranges, etc.) |
| **Interactivity** | Basic | High (click-through, drill-down) |
| **Data Sources** | Single (per tile) | Multiple in one workbook |
| **Conditional Formatting** | Limited | Advanced |
| **Sharing** | Portal access | Can be shared as a resource |
| **Mobile Friendly** | Yes | Yes |
| **Best For** | Quick overview | Detailed reports and analysis |

### When to Use Each

#### Use Azure Dashboard if:
- ✅ You want a quick overview
- ✅ You prefer simple tiles
- ✅ You don't need parameters
- ✅ You want to pin existing queries quickly
- ✅ You need a simple status view

#### Use Azure Workbook if:
- ✅ You want interactive reports
- ✅ You need parameters (time range, environment filters)
- ✅ You want advanced formatting and conditional highlighting
- ✅ You plan to share with teams
- ✅ You want drill-down capabilities
- ✅ You need multiple related visualizations in one place

### Recommendation for This Use Case

**We recommend using Azure Workbook** because:
1. ✅ You have multiple related queries (summary, alerts, trends, charts)
2. ✅ Conditional formatting helps highlight accounts over threshold
3. ✅ Parameters let you filter by environment and time range
4. ✅ Better for sharing with your team
5. ✅ More flexible for future enhancements

### Visual Example

**Azure Dashboard:**
```
┌─────────┐ ┌─────────┐ ┌─────────┐
│ Tile 1 │ │ Tile 2 │ │ Tile 3 │
└─────────┘ └─────────┘ └─────────┘
┌─────────┐ ┌─────────┐
│ Tile 4 │ │ Tile 5 │
└─────────┘ └─────────┘
```

**Azure Workbook:**
```
┌─────────────────────────────────────┐
│ Parameters: [Time Range ▼] [Env ▼] │
├─────────────────────────────────────┤
│ Summary Stats (KPI Cards)           │
├─────────────────────────────────────┤
│ Table: Over Threshold (Red)         │
├─────────────────────────────────────┤
│ Table: All Geo-Replicated Accounts  │
├─────────────────────────────────────┤
│ Chart: Lag Trend Over Time          │
└─────────────────────────────────────┘
```

---

## Step 6: Create Azure Dashboard

### Option A: Pin Queries to Dashboard (Simple)

1. In Log Analytics workspace → **Logs**
2. Run one of the queries above
3. Click **Pin to dashboard** (top of results)
4. Choose:
   - **New dashboard** (e.g., "Infra Monitoring Dashboard")
   - Or **Existing dashboard**
5. Repeat for other queries
6. Go to **Dashboard** (search in portal) → Open your dashboard
7. Arrange and resize tiles as needed

### Option B: Create Azure Workbook (More Flexible - Recommended)

1. In Azure Portal, search for **"Workbooks"**
2. Click **+ New** → **Blank workbook**
3. Click **Add** → **Add query**
4. Configure:
   - **Data source**: Log Analytics
   - **Resource type**: Log Analytics workspace
   - **Workspace**: Select your workspace
   - **Query**: Paste one of the KQL queries above
   - **Visualization**: Choose (Table, Time chart, Bar chart, etc.)
5. Click **Run query** to preview
6. Click **Done editing**

7. **Add more tiles**:
   - Click **+ Add** → **Add query** for each additional visualization
   - Use different queries and visualizations
   - **Recommended widget layout**:
     - **Row 1**: Widget 4 (Summary Statistics) - KPI cards
     - **Row 2**: Widget 1 (GRS Enabled with Lag) - Table
     - **Row 3**: Widget 3 (Over Threshold - Red) - Table
     - **Row 4**: Widget 2 (GRS NOT Enabled) - Table
     - **Row 5**: Widget 5 (Lag Trend) - Time chart
     - **Row 6**: Widget 6 (Status Breakdown) - Donut chart, Widget 7 (Top 10) - Bar chart

8. **Add Conditional Formatting (Red Highlighting)**:
   - For **Widget 1** and **Widget 3** (tables showing lag):
     - In the query tile, click **Column Settings** (gear icon)
     - For the `LagMinutes_d` column:
       - Set **Conditional formatting** → **Color palette**
       - Add rules:
         - If `IsOverThreshold_b == true` → **Red** background
         - If `LagMinutes_d > 0` and `IsOverThreshold_b == false` → **Yellow** background
         - Otherwise → **Green** background
     - For the entire row:
       - Set **Row conditional formatting**
       - If `IsOverThreshold_b == true` → **Red** row background
   - This will make accounts over threshold appear in red automatically

9. **Add Parameters** (optional but recommended):
   - Click **+ Add** → **Add parameters**
   - Add parameters like:
     - `Environment` (dropdown: Prod, NonProd, All)
     - `TimeRange` (dropdown: Last 1 hour, Last 24 hours, Last 7 days)
   - Update queries to use parameters:
     ```kusto
     StorageGeoReplication_CL
     | where ServiceType_s == "StorageGeoReplication"
     | where TimeGenerated > ago({TimeRange:value})
     | where Environment_s == "{Environment}" or "{Environment}" == "All"
     ```

9. **Save the workbook**:
   - Click **Save** → **Save as**
   - Name: "Infra Monitoring - Storage Geo-Replication"
   - Save to: Subscription or Resource Group

## Step 7: Understanding Field Name Suffixes

### What are the Suffixes?

Log Analytics uses type suffixes to determine data types in custom tables:
- `_s` = String (text)
- `_b` = Boolean (true/false)
- `_d` = Double (number)
- `_t` = DateTime (timestamp)
- `_g` = GUID

### How the Script Works

The PowerShell script sends field names **without suffixes** (e.g., `IsGeoReplicated`, `LagMinutes`, `ServiceType`). Log Analytics automatically adds the correct type suffixes based on the actual data types when the data is ingested. This ensures:
- Correct single suffixes are applied (e.g., `IsGeoReplicated` → `IsGeoReplicated_b`)
- No double suffix issues occur
- The schema is created correctly on first ingestion

### If You Have an Old Table with Double Suffixes

If you previously created a table with double suffixes (like `IsGeoReplicated_b_b`), you have two options:

**Option 1: Use a New Table Name (Recommended)**
- Change the LogType in the script to a new name (e.g., `"StorageGeoReplicationV2"`)
- This creates a fresh table with correct single suffixes
- Update all queries to use the new table name

**Option 2: Keep Using Old Table**
- Update all queries to use the double-suffixed field names:
  - `IsGeoReplicated_b_b` instead of `IsGeoReplicated_b`
  - `HasReadAccess_b_b` instead of `HasReadAccess_b`
  - `GeoReplicationStatus_s_s` instead of `GeoReplicationStatus_s`
  - `IsOverThreshold_b_b` instead of `IsOverThreshold_b`
  - `LastSyncTime_t_s` instead of `LastSyncTime_t`

### How to Check Your Table Schema

Run this query to see all column names and types:
```kusto
StorageGeoReplication_CL
| getschema
| project ColumnName, ColumnType
| order by ColumnName
```

You should see single suffixes like:
- `IsGeoReplicated_b` (not `IsGeoReplicated_b_b`)
- `LagMinutes_d` (not `LagMinutes_d_d`)
- `ServiceType_s` (not `ServiceType_s_s`)

## Step 8: Create Alerts from Log Analytics (Optional)

You can create alerts based on Log Analytics queries:

1. In Log Analytics workspace → **Logs**
2. Run a query that identifies issues:
   ```kusto
   StorageGeoReplication_CL
   | where ServiceType_s == "StorageGeoReplication"
   | where TimeGenerated > ago(5m)
   | where IsOverThreshold_b == true
   | summarize count() by bin(TimeGenerated, 5m)
   | where count_ > 0
   ```
3. Click **New alert rule**
4. Configure:
   - **Condition**: When number of results > 0
   - **Actions**: Email, SMS, or Action Group
   - **Alert rule name**: "Storage Geo-Replication Over Threshold"
5. Click **Create alert rule**

## Step 9: Make It Generic for Future Monitoring

The `StorageGeoReplication_CL` table is specifically designed for storage account geo-replication monitoring. If you want to add other infrastructure monitoring in the future:

1. **Create separate tables** for different service types (e.g., `SqlBackup_CL`, `KeyVaultHealth_CL`)
2. **Set `ServiceType_s`** to identify the service:
   - `"StorageGeoReplication"` (current)
   - `"SqlBackup"` (future)
   - `"KeyVaultHealth"` (future)
   - `"VMPatching"` (future)
   - etc.

3. **Reuse common fields**:
   - `SubscriptionId_s`, `ResourceGroup_s`, `ResourceName_s`, `ResourceType_s`
   - `Environment_s`, `TimeGenerated`, `IsOverThreshold_b`

4. **Add service-specific fields** as needed:
   - For SQL Backup: `BackupStatus_s`, `LastBackupTime_t`
   - For Key Vault: `CertificateExpiryDays_d`, `SecretCount_d`
   - etc.

5. **Extend your workbook**:
   - Add new tabs/sections for each service type
   - Use shared parameters (Environment, TimeRange) across all tabs
   - Filter by `ServiceType_s` in queries

## Troubleshooting

### Issue: No data in Log Analytics

**Check:**
1. Pipeline variables are set correctly (WorkspaceId and SharedKey)
2. Pipeline run completed successfully
3. Check pipeline logs for "Successfully sent X records"
4. Wait 5-10 minutes for data to appear (Log Analytics has a slight delay)

**Query to check:**
```kusto
StorageGeoReplication_CL
| where TimeGenerated > ago(1h)
| count
```

### Issue: "Failed to send data to Log Analytics"

**Possible causes:**
1. Invalid Workspace ID format
2. Invalid or expired Shared Key
3. Network connectivity from agent to Log Analytics
4. Check pipeline logs for specific error message

**Solution:**
- Verify Workspace ID and Shared Key in pipeline variables
- Ensure agent can reach `*.ods.opinsights.azure.com`
- Regenerate the Shared Key if needed (Agents management → Regenerate key)

### Issue: Dashboard not updating

**Check:**
1. Data is arriving in Log Analytics (run a simple query)
2. Dashboard/Workbook is using the correct workspace
3. Time range in queries is appropriate (e.g., `ago(1h)` vs `ago(7d)`)

## Next Steps

- **Set up scheduled reports**: Create a workbook that runs daily and emails a summary
- **Add more services**: Start sending other infrastructure metrics to the same table
- **Create action groups**: Set up automated responses to alerts
- **Export to Power BI**: Connect Log Analytics to Power BI for advanced analytics

## Reference

- [Log Analytics Data Collector API](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-collector-api)
- [KQL Query Language](https://learn.microsoft.com/en-us/azure/data-explorer/kusto/query/)
- [Azure Workbooks](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-overview)

