# Identity and Permissions for Azure Pipeline

This document describes the identity and RBAC configuration required for the Azure Pipeline that monitors Storage Account geo-replication.

## Overview

The pipeline uses an **Azure Resource Manager service connection** in Azure DevOps. This service connection authenticates using a **service principal (SPN)** that needs specific RBAC roles to read storage account information.

## Required Roles

### 1. Reader Role (ARM Control Plane)

**Purpose**: List subscriptions and read Storage Account properties, including geo-replication stats.

**Scope**: Each subscription you want to monitor (or at Management Group level if all subscriptions are under the same management group).

**Assignment**:
- Go to **Subscription** → **Access control (IAM)**
- Click **Add** → **Add role assignment**
- **Role**: `Reader`
- **Assign access to**: `Service principal`
- **Select**: Your service connection's service principal
- Click **Review + assign**

**Minimum required for**:
- `Get-AzSubscription` (to discover subscriptions)
- `Get-AzStorageAccount` (to list storage accounts)
- `Get-AzStorageAccount -IncludeGeoReplicationStats` (to get geo-replication data)

### 2. No Blob Data Access Required

**Important**: The script uses `Get-AzStorageAccount -IncludeGeoReplicationStats`, which is an **ARM (control plane) operation**, not a blob data-plane call.

**You do NOT need**:
- ❌ `Storage Blob Data Reader` role
- ❌ `Storage Account Contributor` role
- ❌ Any blob data-plane permissions

The `-IncludeGeoReplicationStats` parameter tells the ARM API to include geo-replication statistics in the response, so it's still a control-plane operation that only requires `Reader` role.

## Service Connection Setup in Azure DevOps

1. In Azure DevOps → **Project Settings** → **Service connections**
2. Click **Create service connection** → **Azure Resource Manager**
3. Choose **Service principal (automatic)** or **Service principal (manual)**
4. Select the subscription(s) and scope
5. **Name**: e.g., `Azure-Infra-Monitoring-SPN`
6. Click **Save**

The service connection will create a service principal automatically (if using automatic) or you'll use an existing one (if using manual).

## Cross-Subscription Scenarios

### Single Tenant, Multiple Subscriptions

- The service principal exists in one tenant
- Assign `Reader` role **in each subscription** you want to monitor
- The script will auto-discover all subscriptions where the SPN has access

### Multi-Tenant (Rare)

- You cannot use a single service principal across tenants
- Options:
  - Create separate service connections per tenant
  - Use separate pipelines per tenant
  - Use a service principal with consent in each tenant (more complex)

## Verification

To verify permissions:

1. **Test subscription access**:
   ```powershell
   Get-AzSubscription
   ```
   Should list all subscriptions where SPN has Reader role.

2. **Test storage account access**:
   ```powershell
   Get-AzStorageAccount -ResourceGroupName <rg> -Name <account> -IncludeGeoReplicationStats
   ```
   Should return storage account with `GeoReplicationStats` property populated.

3. **Check in Azure Portal**:
   - Subscription → Access control (IAM)
   - Search for your service principal
   - Verify `Reader` role is assigned

## Summary

**Per monitored subscription:**
- ✅ **Reader** role (scope: subscription or resource group)

**Not required:**
- ❌ Storage Blob Data Reader
- ❌ Storage Account Contributor
- ❌ Any data-plane permissions

## Security Best Practices

1. **Principle of least privilege**: Only grant `Reader` role, nothing more
2. **Scope appropriately**: If possible, assign at resource group level instead of subscription level
3. **Regular audits**: Periodically review role assignments
4. **Use separate SPNs**: Consider separate service connections for different environments (Prod vs NonProd)
