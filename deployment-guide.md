# Azure Storage Geo-Replication Monitor - Deployment Guide

This guide provides step-by-step instructions to deploy the Azure Logic App solution for monitoring geo-replication last sync times across multiple Azure subscriptions.

## Prerequisites

Before starting, ensure you have:

- **Azure Portal access** with permissions to:
  - Create Logic Apps
  - Assign RBAC roles (Owner or User Access Administrator)
  - Configure managed identities
- **Office 365 account** or service mailbox for sending emails
- **List of subscription IDs** you want to monitor
- **Access to the workflow JSON file**: `logicapp-geo-replication-workflow.json`

## Step 1: Prepare Configuration Decisions

Decide on the following before deployment:

- **Resource Group**: Name and region for the Logic App (e.g., `rg-storage-monitoring`, region close to your storage accounts)
- **Logic App Name**: e.g., `la-storage-geo-replication-monitor`
- **Operating Mode**: 
  - `alert` - Only send emails when lag exceeds threshold (production)
  - `report` - Always send status report (testing/visibility)
- **Email Recipients**: Primary email addresses or distribution lists
- **Threshold**: Default lag threshold in minutes (e.g., 30 minutes)
- **Schedule**: How often to run (e.g., hourly, every 30 minutes)

## Step 2: Create the Logic App in Azure Portal

1. Log in to the [Azure Portal](https://portal.azure.com)

2. Click **Create a resource** (or use the search bar)

3. Search for **"Logic App"** and select **Logic App (Consumption)**

4. Click **Create**

5. Fill in the **Basics** tab:
   - **Subscription**: Choose the subscription where the Logic App will reside
   - **Resource Group**: Create new or select existing (e.g., `rg-storage-monitoring`)
   - **Logic App name**: e.g., `la-storage-geo-replication-monitor`
   - **Region**: Choose a region close to your storage accounts
   - **Enable Log Analytics**: Optional but recommended for monitoring

6. Click **Review + create** → **Create**

7. Wait for deployment to complete, then click **Go to resource**

## Step 3: Enable System-Assigned Managed Identity

The Logic App needs a managed identity to authenticate to Azure Resource Manager and Storage Accounts.

1. In your Logic App resource, navigate to **Identity** in the left menu

2. Under **System assigned** tab:
   - Toggle **Status** to **On**
   - Click **Save**
   - Confirm when prompted

3. **Copy the Object (principal) ID** - you'll need this for role assignments

   > **Note**: The Object ID looks like: `12345678-1234-1234-1234-123456789abc`

## Step 4: Assign RBAC Roles - ARM Access

Grant the managed identity permission to read subscription and storage account information.

### For Each Subscription to Monitor:

1. Navigate to **Subscriptions** in Azure Portal

2. Select the subscription you want to monitor

3. Click **Access control (IAM)** in the left menu

4. Click **Add** → **Add role assignment**

5. Configure:
   - **Role**: Select **Reader**
   - **Assign access to**: Select **Managed identity**
   - **Members**: Click **Select members**
     - **Managed identity**: Select **Logic App**
     - **Select**: Choose your Logic App (e.g., `la-storage-geo-replication-monitor`)
     - Click **Select**
   - Click **Review + assign** → **Review + assign**

6. Repeat for each subscription you want to monitor

> **Tip**: If you have many subscriptions, you can assign the Reader role at the Management Group level if all subscriptions are under the same management group.

## Step 5: Assign RBAC Roles - Storage Data Plane Access

Grant the managed identity permission to read blob service statistics (geo-replication data).

### Option A: Per Storage Account (Recommended for Testing)

1. Navigate to each **Storage Account** you want to monitor

2. Click **Access control (IAM)** in the left menu

3. Click **Add** → **Add role assignment**

4. Configure:
   - **Role**: Select **Storage Blob Data Reader**
   - **Assign access to**: Select **Managed identity**
   - **Members**: Select your Logic App managed identity
   - Click **Review + assign**

### Option B: At Resource Group Level (Recommended for Production)

1. Navigate to the **Resource Group** containing your storage accounts

2. Click **Access control (IAM)** → **Add** → **Add role assignment**

3. Configure:
   - **Role**: **Storage Blob Data Reader**
   - **Assign access to**: **Managed identity**
   - **Members**: Select your Logic App managed identity
   - Click **Review + assign**

   > This grants access to all storage accounts in that resource group.

### Option C: At Subscription Level (Broadest Scope)

1. Navigate to the **Subscription**

2. Click **Access control (IAM)** → **Add** → **Add role assignment**

3. Configure:
   - **Role**: **Storage Blob Data Reader**
   - **Assign access to**: **Managed identity**
   - **Members**: Select your Logic App managed identity
   - Click **Review + assign**

   > This grants access to all storage accounts in the subscription.

## Step 6: Create Office 365 Email Connection

The Logic App needs an Office 365 connection to send emails.

1. In your Logic App, click **Logic app designer** in the left menu

2. Click **+ Add** to add a new step

3. Search for and add **Recurrence** trigger (temporary - we'll replace this)

4. Click **+ New step**

5. Search for **"Office 365 Outlook"** and select **Send an email (V2)**

6. When prompted to **Sign in**:
   - Use a **service account** or dedicated mailbox (not a personal account)
   - Complete the authentication flow
   - Grant permissions when prompted

7. Click **Save** in the designer toolbar

   > This creates the `office365` connection that will be referenced in your workflow JSON.

8. **Note the connection name** - it should be `office365` (or check in **API connections** in the left menu)

## Step 7: Import Your Workflow Definition

1. In your Logic App, ensure you're in **Logic app designer**

2. Click **Code view** button (top right of the designer)

3. Open the file `logicapp-geo-replication-workflow.json` from your repository

4. **Copy the entire JSON content**

5. **Paste it into the Code view**, replacing all existing content

6. **Important**: Verify the `$connections` section references `office365`:
   ```json
   "$connections": {
     "office365": {
       "connectionId": "/subscriptions/.../resourceGroups/.../providers/Microsoft.Web/connections/office365",
       "connectionName": "office365",
       "id": "/subscriptions/.../providers/Microsoft.Web/locations/.../managedApis/office365"
     }
   }
   ```

   > If the connection name differs, update it in the JSON or recreate the connection with the name `office365`.

7. Click **Save**

8. Switch back to **Designer view** to verify the workflow appears correctly:
   - You should see a **Recurrence** trigger
   - HTTP actions for listing subscriptions and storage accounts
   - Loops for processing accounts
   - Email actions at the end

## Step 8: Configure Workflow Parameters

Set the configuration parameters that control the monitoring behavior.

1. In the Logic App designer, look for **Parameters** section (usually at the top or in a sidebar)

2. Configure each parameter:

   ### `subscriptions` (Array)
   - **For testing**: Add a single subscription ID as an array item
     - Example: `["12345678-1234-1234-1234-123456789abc"]`
   - **For production**: 
     - Add all subscription IDs you want to monitor, OR
     - Leave empty `[]` to automatically discover all accessible subscriptions

   ### `thresholdMinutes` (Integer)
   - **Default**: `30`
   - **Testing**: Set to `1` or `0` to force alerts
   - **Production**: Set based on your SLA (e.g., `15`, `30`, or `60` minutes)

   ### `mode` (String)
   - **Options**: `"alert"` or `"report"`
   - **Testing**: Use `"report"` to see all accounts
   - **Production**: Use `"alert"` to only email when issues are detected

   ### `emailTo` (String)
   - **Format**: Comma-separated email addresses
   - **Example**: `"storageteam@contoso.com,ops@contoso.com"`
   - **Required**: Must be set for emails to be sent

   ### `emailSubjectPrefix` (String, Optional)
   - **Default**: `"[Storage Geo-Replication]"`
   - **Customize**: e.g., `"[Prod] Storage Geo-Replication"` or `"[Monitoring] Geo-Replication"`

3. Click **Save** in the designer

## Step 9: Configure Schedule (Recurrence Trigger)

Set how often the Logic App should run.

1. In the designer, click on the **Recurrence** trigger

2. Configure:
   - **Frequency**: 
     - `Hour` - Run every X hours
     - `Minute` - Run every X minutes
     - `Day` - Run daily
   - **Interval**: Number of units (e.g., `1` for every hour, `30` for every 30 minutes)

3. **Advanced options** (optional):
   - **At these hours**: For daily runs, specify hours (e.g., `9, 12, 15`)
   - **At these minutes**: Specify minutes (e.g., `0, 30`)
   - **Time zone**: Select your time zone

4. Click **Save**

   > **Example schedules**:
   > - Production: Every 1 hour
   > - High-frequency monitoring: Every 15-30 minutes
   > - Daily report: Once per day at 9 AM

## Step 10: Initial Testing

Follow these tests to validate the deployment.

### Test 1: Small-Scope Report Mode

1. Set parameters:
   - `mode`: `"report"`
   - `thresholdMinutes`: `30`
   - `subscriptions`: Single test subscription ID
   - `emailTo`: Your test email address

2. In the Logic App designer, click **Run trigger** → **Recurrence** → **Run**

3. Monitor the run:
   - Go to **Overview** → **Runs history**
   - Wait for the run to complete (should show **Succeeded**)

4. Verify:
   - Check your email inbox for the status report
   - Verify the report includes storage accounts from the test subscription
   - Check that lag values are displayed correctly
   - Verify account details (subscription, name, location, replication type)

### Test 2: Alert Mode - Force Alert

1. Set parameters:
   - `mode`: `"alert"`
   - `thresholdMinutes`: `0` or `1` (very low to force alerts)
   - `subscriptions`: Test subscription
   - `emailTo`: Your test email

2. Run the Logic App manually

3. Verify:
   - You receive an **ALERT** email (subject should contain "ALERT")
   - Email includes accounts with lag > threshold
   - Alert formatting is clear and actionable

### Test 3: Alert Mode - No Issues

1. Set parameters:
   - `mode`: `"alert"`
   - `thresholdMinutes`: `1440` (24 hours - should not trigger)
   - `subscriptions`: Test subscription
   - `emailTo`: Your test email

2. Run the Logic App manually

3. Verify:
   - Run completes successfully
   - **No email is sent** (because no accounts exceed threshold)

### Test 4: Error Handling

1. Temporarily set an invalid subscription ID in `subscriptions`

2. Run the Logic App

3. Verify:
   - Run shows appropriate error handling
   - Errors are logged in run history
   - No partial emails are sent

## Step 11: Production Deployment

Once testing is successful, configure for production:

1. **Update Parameters**:
   - `subscriptions`: All production subscription IDs (or leave empty for auto-discovery)
   - `thresholdMinutes`: Your production SLA threshold (e.g., `30`)
   - `mode`: `"alert"` for production monitoring
   - `emailTo`: Production distribution list or team email

2. **Verify Schedule**: Ensure recurrence is set to your desired frequency

3. **Enable the Logic App**:
   - In **Overview**, ensure the Logic App is **Enabled**
   - If disabled, click **Enable**

4. **Monitor Initial Runs**:
   - Check **Runs history** for the first few scheduled runs
   - Verify emails are being sent correctly
   - Check for any errors or warnings

## Step 12: Optional Enhancements

### Add Monitoring and Alerts

1. **Logic App Run Failures**:
   - Go to **Alerts** → **Create** → **Alert rule**
   - Condition: Logic App run failed
   - Action: Email/SMS to operations team

2. **Log Analytics Integration** (Future):
   - Consider sending results to Log Analytics workspace
   - Create dashboards for trend analysis
   - Set up alerts based on historical patterns

### Create Separate Report Workflow (Optional)

If you want both alerting and periodic reports:

1. **Duplicate the Logic App**:
   - Export the Logic App definition
   - Create a new Logic App with a different name (e.g., `la-storage-geo-replication-report`)

2. **Configure for Reports**:
   - Set `mode`: `"report"`
   - Set schedule: Daily at a specific time (e.g., 9 AM)
   - Set `emailTo`: Management/distribution list

3. **Keep Alert Workflow**:
   - Original Logic App with `mode`: `"alert"`
   - More frequent schedule (e.g., hourly)

## Troubleshooting

### Common Issues

#### Issue: "Unauthorized" or "Forbidden" errors

**Solution**: 
- Verify managed identity is enabled
- Check RBAC role assignments (Reader on subscriptions, Storage Blob Data Reader on storage accounts)
- Ensure role assignments have propagated (wait 5-10 minutes after assignment)

#### Issue: No emails received

**Solution**:
- Verify `emailTo` parameter is set correctly
- Check Office 365 connection is authenticated
- Review run history for errors
- Check spam/junk folder
- Verify email action is executing (check run details)

#### Issue: "Storage account not found" or missing accounts

**Solution**:
- Verify storage accounts have geo-replication enabled (RA-GRS, RA-GZRS, etc.)
- Check RBAC permissions on storage accounts
- Verify subscription IDs in `subscriptions` parameter are correct
- Check if storage accounts are in different regions (some APIs may be region-specific)

#### Issue: "Invalid JSON" or workflow import fails

**Solution**:
- Verify JSON syntax is valid (use a JSON validator)
- Check that `$connections` section matches your Office 365 connection name
- Ensure all required parameters are defined
- Try importing in smaller sections if the workflow is very large

#### Issue: Lag calculation seems incorrect

**Solution**:
- Verify storage accounts actually have geo-replication enabled
- Check that `LastSyncTime` is being parsed correctly (review run details)
- Some storage accounts may not have synced yet (new accounts or during failover)

### Reviewing Run History

1. Go to **Overview** → **Runs history**

2. Click on a specific run to see details

3. Expand each action to see:
   - Inputs and outputs
   - Status (Succeeded/Failed)
   - Duration
   - Error messages (if failed)

4. Use **Resubmit** to rerun a specific workflow if needed

## Maintenance

### Regular Tasks

- **Monthly**: Review email recipients and update if team changes
- **Quarterly**: Review threshold values and adjust based on SLA changes
- **As needed**: Add/remove subscriptions from monitoring list
- **Monitor costs**: Logic App Consumption pricing based on executions and actions

### Updating the Workflow

1. Make changes to `logicapp-geo-replication-workflow.json` locally
2. Test changes in a test Logic App first
3. Import updated JSON into production Logic App via Code view
4. Verify parameters are preserved
5. Test with a manual run before enabling scheduled runs

## Security Considerations

- **Managed Identity**: Uses system-assigned managed identity (no secrets to manage)
- **RBAC**: Follows principle of least privilege (Reader + Storage Blob Data Reader)
- **Email**: Office 365 connection uses OAuth (no passwords stored)
- **Parameters**: Consider storing sensitive parameters in Azure Key Vault if needed

## Support and Documentation

- **API Documentation**: See `apis-geo-replication.md` for API details
- **Workflow Design**: See `logicapp-geo-replication-workflow.json` for workflow structure
- **Email Templates**: See `email-templates.md` for email formatting
- **Testing**: See `testing-plan.md` for detailed test scenarios
- **Identity Setup**: See `identity-and-permissions.md` for RBAC details

## Next Steps

After successful deployment:

1. Monitor the first few scheduled runs
2. Gather feedback from email recipients
3. Adjust thresholds and schedules as needed
4. Consider adding Log Analytics integration for long-term trend analysis
5. Document any customizations for your environment

---

**Last Updated**: [Date]
**Version**: 1.0

