### Email templates – geo-replication monitoring

This document defines the email layouts and subjects for the Logic App’s **alert** and **report** modes.

#### 1. Common subject prefix

- Parameter: `emailSubjectPrefix`
  - Default: `[Storage Geo-Replication]`

#### 2. Alert mode email

- Triggered when:
  - `mode == 'alert'`
  - At least one Storage Account has `lagMinutes > thresholdMinutes`.

- **Subject**:
  - `"{emailSubjectPrefix} ALERT - {N} accounts over {ThresholdMinutes} minutes"`
  - Example: `[Storage Geo-Replication] ALERT - 3 accounts over 30 minutes`

- **Body (HTML)** – implemented as an HTML table in the Logic App:

Header:
- Title: `Storage Accounts with geo-replication lag over {ThresholdMinutes} minutes`
- Timestamp: `Run time: {utcNow()}`

Table columns:
- `Subscription`
- `Storage Account`
- `Location`
- `SKU`
- `Replication status`
- `Last Sync (UTC)`
- `Lag (minutes)`

Row style:
- Every row in **alert** mode represents an account already over threshold, so no extra highlighting is strictly needed, but you can:
  - Use a light red background for all rows.

Example HTML snippet (conceptual – actual is generated via an expression in the workflow):

```html
<h2>Storage Accounts with geo-replication lag over 30 minutes</h2>
<p>Run time (UTC): 2025-12-04T10:15:00Z</p>
<table border="1" cellspacing="0" cellpadding="3">
  <tr>
    <th>Subscription</th>
    <th>Account</th>
    <th>Location</th>
    <th>SKU</th>
    <th>Status</th>
    <th>Last Sync (UTC)</th>
    <th>Lag (min)</th>
  </tr>
  <!-- One row per account over threshold -->
</table>
```

#### 3. Report mode email

- Triggered when:
  - `mode == 'report'` (runs regardless of whether any account is over threshold).

- **Subject**:
  - `"{emailSubjectPrefix} Status Report"`
  - Example: `[Storage Geo-Replication] Status Report`

- **Body (HTML)**:

Header:
- Title: `Storage Account geo-replication status report`
- Subheading: `Threshold: {ThresholdMinutes} minutes (rows above threshold are highlighted).`
- Timestamp: `Run time: {utcNow()}`

Table columns:
- Same as alert mode:
  - `Subscription`
  - `Storage Account`
  - `Location`
  - `SKU`
  - `Replication status`
  - `Last Sync (UTC)`
  - `Lag (minutes)`

Row style:
- If `lagMinutes > thresholdMinutes`:
  - Add a light red background, e.g. `style="background-color:#ffcccc;"`.
- Else:
  - No special styling.

Example conceptual HTML:

```html
<h2>Storage Account geo-replication status report</h2>
<p>Threshold: 30 minutes (rows above threshold are highlighted).</p>
<p>Run time (UTC): 2025-12-04T10:15:00Z</p>
<table border="1" cellspacing="0" cellpadding="3">
  <tr>
    <th>Subscription</th>
    <th>Account</th>
    <th>Location</th>
    <th>SKU</th>
    <th>Status</th>
    <th>Last Sync (UTC)</th>
    <th>Lag (min)</th>
  </tr>
  <!-- Rows for all monitored accounts -->
</table>
```

#### 4. No-alert outcome in alert mode

- If `mode == 'alert'` and there are **no** accounts over threshold:
  - No email is sent (silent success).
  - If desired, you can later extend the workflow to send a “no issues” email or write a heartbeat log to Log Analytics.


