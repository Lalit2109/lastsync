### Azure Pipelines – Storage geo-replication monitor (SendGrid, self-hosted agents)

This folder contains a minimal Azure Pipelines implementation of the storage geo-replication monitor using:

- **Self-hosted agents** (to keep costs down and support private endpoints)
- **AzurePowerShell** task with an Azure Resource Manager service connection
- **SendGrid** for sending consolidated HTML emails

Files:

- `azure-pipelines-geo-replication.yml` – pipeline definition
- `check-geo-replication.ps1` – script that performs the checks and sends the email

#### 1. Prerequisites

- An **Azure DevOps project**.
- A **self-hosted agent pool** (Linux or Windows) with:
  - PowerShell Core (for `pwsh`) or Windows PowerShell 5.1.
  - **Az PowerShell modules** installed (`Az.Accounts`, `Az.Storage`).
  - Network access to:
    - `management.azure.com` (ARM)
    - Your Storage Accounts (including via private endpoints if applicable)
    - `https://api.sendgrid.com` (for email sending).
- An **Azure Resource Manager service connection** in Azure DevOps:
  - With at least `Reader` role on subscriptions you want to monitor (the script auto-discovers all accessible subscriptions).
- A **SendGrid API key** with permission to send mail.

#### 2. Configure the pipeline YAML

Open `azure-pipelines-geo-replication.yml` and update:

- `pool.name`:
  - Set to your **self-hosted agent pool name**, e.g.:
  - `name: 'SelfHosted-Infra'`

- `variables.ThresholdMinutes`:
  - Set your preferred lag threshold in minutes (e.g., `15`, `30`).

- `variables.Mode`:
  - `alert` – only send email when at least one account is over threshold.
  - `report` – always send a status report for all geo-replicated accounts.

- `variables.Environment`:
  - Logical label for the environment, used in the email subject (e.g., `Prod`, `NonProd`).

- `azureSubscription`:
  - Replace `YOUR-AZURE-RM-SERVICE-CONNECTION` with the name of your **Azure RM service connection**.

#### 3. Define SendGrid variables (secret)

In Azure DevOps, for the pipeline or a variable group:

- Add secrets:
  - `SendGridApiKey` – your SendGrid API key (mark as secret).
  - `SendGridFrom` – sender email (e.g., `storage-monitor@contoso.com`).
  - `SendGridTo` – comma-separated recipient list (e.g., `team@contoso.com,opsteam@contoso.com`).

These are referenced in the YAML as `$(SendGridApiKey)`, `$(SendGridFrom)`, `$(SendGridTo)`.

#### 4. Script behaviour (`check-geo-replication.ps1`)

The script:

- Uses the Azure context provided by the AzurePowerShell task (service connection) – **no credentials in code**.
- **Auto-discovers all accessible subscriptions** using `Get-AzSubscription` (requires Reader role on subscriptions).
- For each discovered subscription:
  - Sets context with `Set-AzContext`.
  - Lists Storage Accounts via `Get-AzStorageAccount`.
  - Filters to RA-GRS / RA-GZRS / GZRS SKUs.
  - For each geo-replicated account:
    - Uses `Get-AzStorageAccount -IncludeGeoReplicationStats` to obtain:
      - `GeoReplicationStats.Status`
      - `GeoReplicationStats.LastSyncTime`
    - Computes lag in minutes vs. current UTC time.
- Collects results into an in-memory list:
  - `SubscriptionId`, `ResourceGroup`, `StorageAccount`, `Location`, `SkuName`,
    `GeoStatus`, `LastSyncTimeUtc`, `LagMinutes`, `IsOverThreshold`, `ThresholdMinutes`, `Environment`.

Email logic:

- **Mode `alert`**:
  - Filters to `IsOverThreshold -eq $true`.
  - If none, **no email is sent**.
  - If one or more, sends a **single consolidated email**.

- **Mode `report`**:
  - Includes **all** geo-replicated accounts.
  - Always sends an email.

Email format:

- HTML table with:
  - `Subscription`, `Resource Group`, `Storage Account`, `Location`, `SKU`, `Geo Status`,
    `Last Sync (UTC)`, `Lag (min)`, `Threshold (min)`.
- Rows over threshold are highlighted with a light red background.
- Subject:
  - `[$Environment] Storage Geo-Replication ALERT - N accounts over X minutes` (alert mode).
  - `[$Environment] Storage Geo-Replication Status Report` (report mode).

#### 5. Run schedule and costs

- Schedule is defined in the YAML under `schedules`:
  - Default: every hour (`cron: "0 * * * *"`).
  - You can adjust to run less frequently (e.g., every 3 hours) to reduce agent usage.
- Cost considerations:
  - **Self-hosted agents** mean you are not paying extra for Microsoft-hosted parallel jobs time beyond your DevOps plan.
  - Storage and control-plane operations are lightweight; the primary cost is your agent VM compute, which you already own.

#### 6. First-time test

1. Commit this folder and YAML to your repo.
2. In Azure DevOps:
   - Create a new pipeline from `azure-pipelines/geo-replication-monitor/azure-pipelines-geo-replication.yml`.
3. Set variables:
   - `SubscriptionsCsv`, `ThresholdMinutes`, `Mode`, `Environment`.
   - Secrets: `SendGridApiKey`, `SendGridFrom`, `SendGridTo`.
4. Manually **Run** the pipeline once:
   - Verify the job uses your self-hosted agent.
   - Check logs for any Az module issues.
   - Confirm you receive an email from SendGrid.


