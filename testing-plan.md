### Testing plan – Storage geo-replication Logic App

This document describes how to validate the Logic App implementation end-to-end.

#### 1. Prerequisites

- Logic App deployed with:
  - Parameters set appropriately (subscriptions, thresholdMinutes, mode, emailTo, emailSubjectPrefix).
  - Managed identity enabled and RBAC assignments in place:
    - `Reader` on target subscriptions/resource groups.
    - `Storage Blob Data Reader` on geo-replicated Storage Accounts.
- Office 365 email connector configured and tested with a simple test email.

#### 2. Small-scope functional test

1. **Limit scope**:
   - Set `subscriptions` parameter to a **single non-production subscription**.
   - Optionally tag a few test Storage Accounts and add tag-based filters later if desired.
2. **Run in report mode**:
   - Set `mode = report`.
   - Set `thresholdMinutes` to a reasonable value (e.g., 30).
3. **Trigger a run**:
   - Use the Logic App designer’s *Run Trigger* feature or wait for the next scheduled recurrence.
4. **Validate**:
   - Confirm the run succeeds in the Logic App run history.
   - Check the email:
     - Ensure all expected Storage Accounts appear.
     - Validate that `Last Sync (UTC)` and `Lag (min)` look reasonable (non-negative, roughly aligned with expectations).

#### 3. Alert path test (forced alerts)

1. Set:
   - `mode = alert`.
   - `thresholdMinutes = 0` or `1` (to deliberately flag any non-zero lag).
2. Trigger a run.
3. Validate:
   - At least one account (for which geo-replication is active) appears in the alert email.
   - Subject line follows the pattern:  
     - `[Storage Geo-Replication] ALERT - {N} accounts over {ThresholdMinutes} minutes`
   - Body table lists only accounts over threshold.

4. Reset:
   - After validation, reset `thresholdMinutes` to the desired production value.

#### 4. No-alert scenario test

1. Keep `mode = alert`.
2. Choose a relatively **high** `thresholdMinutes` (e.g., 1440 for 24 hours) where you expect no accounts to exceed this lag.
3. Trigger a run.
4. Validate:
   - Run history shows success.
   - **No email** is received (silent success).

#### 5. Error handling tests

1. Temporarily remove `Storage Blob Data Reader` on one test Storage Account.
2. Trigger a run.
3. Validate:
   - The HTTP call to Blob stats fails for that account.
   - The Logic App’s retry policy and error paths behave as configured (e.g., run shows a clear failure or warning).
   - Based on your chosen design, either:
     - The account appears in an error section of the report (if you extend the workflow), or
     - The run is marked as failed and can be investigated.

4. Restore the role assignment.

#### 6. Scale-out / performance sanity check

1. Run the Logic App against **all target subscriptions**.
2. Observe:
   - Run duration (time from start to end).
   - Number of Storage Accounts processed.
   - Any throttling or rate-limiting errors from ARM or Storage APIs.
3. If needed, tune:
   - `For each` parallelism degree.
   - Recurrence interval (e.g., run hourly instead of every 5 minutes).

#### 7. Ongoing monitoring

- Configure:
  - Logic App run failure alerts (e.g., via Action Group or custom alert rules).
  - Optional logging of per-account results to Log Analytics for dashboards.


