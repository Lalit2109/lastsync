# Azure Workbook Import Instructions

This guide explains how to import the pre-configured Workbook JSON template with conditional formatting.

## File: `storage-geo-replication-workbook.json`

This JSON file contains a complete Azure Workbook with:
- ✅ All 7 widgets with KQL queries
- ✅ Conditional formatting (red/yellow/green) for Widget 1 and Widget 3
- ✅ Time range parameter
- ✅ All column names using double suffixes (`_s_s`, `_b_b`, `_d_d`) to match your schema
- ✅ No Environment column references

## How to Import

### Method 1: Direct Import (Recommended)

1. **Open Azure Portal** → Search for **"Workbooks"**
2. Click **"+ New"** → **"Blank workbook"**
3. Click the **"..."** menu (three dots) in the top right
4. Select **"Upload JSON"**
5. Browse and select `storage-geo-replication-workbook.json`
6. The workbook will load with all queries and formatting

### Method 2: Copy-Paste JSON

1. **Open Azure Portal** → Search for **"Workbooks"**
2. Click **"+ New"** → **"Blank workbook"**
3. Click the **"..."** menu → **"Download as JSON"** (to see the format)
4. Replace the entire JSON content with the content from `storage-geo-replication-workbook.json`
5. Click **"..."** → **"Upload JSON"** and paste the JSON

### Method 3: Edit Existing Workbook

1. Open your existing workbook
2. Click **"..."** → **"Download as JSON"**
3. Replace the JSON content with the content from `storage-geo-replication-workbook.json`
4. Click **"..."** → **"Upload JSON"** and paste the updated JSON

## After Import

1. **Select your Log Analytics Workspace**:
   - Each query tile needs to be configured with your workspace
   - Click on each query tile → Edit → Select your workspace

2. **Verify Conditional Formatting**:
   - Widget 1 (GRS Enabled with Lag) should show:
     - Red rows/background for accounts over threshold
     - Yellow for accounts with lag > 0
     - Green for healthy accounts
   - Widget 3 (Over Threshold) should show red highlighting

3. **Test the Time Range Parameter**:
   - Use the time range selector at the top
   - All queries should update automatically

4. **Save the Workbook**:
   - Click **"Save"** → **"Save as"**
   - Name: "Storage Geo-Replication Dashboard"
   - Save to: Subscription or Resource Group

## Widgets Included

1. **Summary Statistics** - KPI cards showing totals and percentages
2. **Storage Accounts with GRS Enabled** - Table with conditional formatting (red/yellow/green)
3. **Accounts Over Threshold** - Red-highlighted alert view
4. **Storage Accounts with GRS NOT Enabled** - List of non-geo-replicated accounts
5. **Lag Trend Over Time** - Time chart showing average/max/min lag
6. **Accounts by Status** - Donut chart breakdown
7. **Top 10 Accounts by Lag** - Bar chart of worst performers

## Troubleshooting

### If Conditional Formatting Doesn't Appear

The JSON includes conditional formatting, but Azure Workbooks sometimes requires manual verification:

1. Click on Widget 1 (GRS Enabled with Lag)
2. Click **"Column Settings"** (gear icon)
3. Verify the `LagMinutes_d_d` column has conditional formatting rules
4. If not, add them manually:
   - Red: `IsOverThreshold_b_b == true`
   - Yellow: `LagMinutes_d_d > 0 and IsOverThreshold_b_b == false`
   - Green: Default

### If Queries Don't Work

- Verify you've selected the correct Log Analytics workspace for each query
- Check that the table `StorageGeoReplication_CL` exists
- Verify column names match (double suffixes: `_s_s`, `_b_b`, `_d_d`)

### If Time Range Parameter Doesn't Work

- Make sure the parameter is at the top of the workbook
- Verify queries use `{TimeRange}` in the `ago()` function
- Check that parameter ID matches in all queries

## Notes

- All column names use **double suffixes** (`_s_s`, `_b_b`, `_d_d`) to match your actual schema
- **Environment column has been removed** from all queries
- The workbook uses the `{TimeRange}` parameter for flexible time filtering
- Conditional formatting is pre-configured but may need verification in the UI

