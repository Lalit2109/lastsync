### Geo-replication monitoring – API design

This document summarizes which Azure APIs and fields are used to read `geoReplication.lastSyncTime` and related metadata for Storage Accounts.

#### 1. Enumerate subscriptions (optional if you already know them)

- **API**: Azure Resource Manager – List subscriptions  
- **Method**: `GET`  
- **URL**: `https://management.azure.com/subscriptions?api-version=2020-01-01`  
- **Auth**: Managed Identity / AAD bearer token for resource `https://management.azure.com/`
- **Usage in Logic App**: HTTP action.

Important fields:
- `value[*].subscriptionId`
- `value[*].displayName`

If you prefer to control the scope manually, you can skip this call and provide subscription IDs as a Logic App parameter.

#### 2. List Storage Accounts in a subscription

- **API**: Azure Resource Manager – List Storage Accounts  
- **Method**: `GET`  
- **URL**:  
  - Per subscription:  
    `https://management.azure.com/subscriptions/{subscriptionId}/providers/Microsoft.Storage/storageAccounts?api-version=2023-01-01`  
- **Auth**: Managed Identity / AAD bearer token for ARM.

Important fields per account:
- `name`
- `id`
- `location`
- `kind`
- `sku.name` (e.g., `Standard_RAGRS`, `Standard_GZRS`, `Standard_RAGZRS`)
- `properties.primaryLocation`
- `properties.secondaryLocation`
- `properties.geoReplicationStats` (for some API versions, but not always populated)

The Logic App will iterate over this list in a `For each` loop.

#### 3. Get Blob service geo-replication stats per account

To obtain the authoritative `geoReplication.lastSyncTime`, use the **Blob service stats** (data-plane) API. This is supported for RA-GRS / RA-GZRS style accounts with read-access geo-replication.

- **API**: Get Blob Service Stats  
- **Method**: `GET`  
- **URL**:  
  `https://{accountName}.blob.core.windows.net/?restype=service&comp=stats`  
- **Headers**:  
  - `x-ms-version: 2020-10-02` (or a current supported version)  
  - Authorization via Managed Identity (via Logic App HTTP with Managed Identity) or SAS if needed.

Sample response shape (simplified):

```xml
<?xml version="1.0" encoding="utf-8"?>
<StorageServiceStats>
  <GeoReplication>
    <Status>live</Status>
    <LastSyncTime>Mon, 09 Dec 2024 11:34:52 GMT</LastSyncTime>
  </GeoReplication>
</StorageServiceStats>
```

Fields we care about:
- `GeoReplication.Status` – e.g., `live`, `bootstrap`, `unavailable`.
- `GeoReplication.LastSyncTime` – UTC timestamp we will compare with `utcNow()`.

In Logic Apps:
- Use an HTTP action with **Managed Identity** authentication.
- Parse the XML with a `Parse XML` action or cast to JSON with `xml()` expression and then access:  
  `body('Blob_Stats')?['StorageServiceStats']['GeoReplication']['LastSyncTime']`

#### 4. Determine eligible accounts (replication type)

We should only call the Blob service stats API for accounts that support geo-replication stats:

- From the Storage Account ARM response (`sku.name`):
  - Eligible values usually include:  
    - `Standard_RAGRS`  
    - `Standard_RAGZRS`  
    - `Standard_GZRS` (geo-redundant; may need to verify stats support)  
  - Non-eligible / ignore for this workflow:  
    - `Standard_LRS`, `Standard_ZRS`, `Premium_LRS`, etc. (non-geo-replicated).

Logic App filter (pseudo):
- Condition per account:  
  `@or(equals(item()?['sku']?['name'], 'Standard_RAGRS'), equals(item()?['sku']?['name'], 'Standard_RAGZRS'), equals(item()?['sku']?['name'], 'Standard_GZRS'))`

Only if this condition is true do we call the Blob stats API.

#### 5. Lag calculation

Once `LastSyncTime` is obtained:

- Convert to a Logic Apps expression:
  - Use `ticks()` to convert times to 100-nanosecond intervals.
  - Example:  
    - `ticks(utcNow())`  
    - `ticks(outputs('Parse_XML')?['body/StorageServiceStats/GeoReplication/LastSyncTime'])`
- Compute lag in minutes:

```text
LagMinutes = (ticks(utcNow()) - ticks(lastSyncTime)) / (600000000 * 60)
```

In Logic Apps expression form (simplified for readability):

```text
div(
  sub(
    ticks(utcNow()),
    ticks(variables('lastSyncTime'))
  ),
  36000000000
)
```

Where:
- `36000000000 = 600000000 * 60` (ticks per minute).

Alternatively, you can use `subtractFromTime()` and `dateDifference()` if you prefer:

```text
dateDifference(
  lastSyncTime,
  utcNow(),
  'Minute'
)
```

> Note: `dateDifference` is often simpler and more readable; use it if available in your Logic Apps runtime.

#### 6. Output object per Storage Account

For each eligible Storage Account, build a structured object (as a Logic App variable or in an array) with at least:

- `subscriptionId`
- `resourceGroupName`
- `storageAccountName`
- `location`
- `skuName`
- `primaryLocation`
- `secondaryLocation`
- `geoReplicationStatus` (from `GeoReplication.Status`)
- `lastSyncTime` (raw string or ISO 8601)
- `lagMinutes` (integer)

This object will be used later to:
- Filter accounts where `lagMinutes > ThresholdMinutes` (for alerts).
- Build the aggregated email report in both `alert` and `report` modes.

#### 7. Error and edge-case handling

- If `GeoReplication` or `LastSyncTime` is absent:
  - Mark the account with `geoReplicationStatus = 'unknown'` and `lagMinutes = null`.
  - Optionally treat this as a warning in the email report.
- If the Blob stats call fails:
  - Use retry policies on the HTTP action.
  - On persistent failure, add the account to a separate “failed-to-query” list and include it in the email.


