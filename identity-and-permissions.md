### Managed Identity and permissions design

This document describes the identity and RBAC configuration required for the Logic App that monitors Storage Account geo-replication.

#### 1. Logic App identity choice

- Use a **system-assigned managed identity** on the Logic App.
- This identity will be used for:
  - ARM calls (list subscriptions, list Storage Accounts).
  - Blob service stats calls (data-plane) where supported.

Steps (portal-level, not automated here):
1. Open the Logic App resource.
2. Enable **System assigned** managed identity.
3. Note the **Object (principal) ID** of the managed identity.

#### 2. ARM permissions (control plane)

For the ARM calls (`management.azure.com`), grant the Logic App managed identity:

- **Role**: `Reader` at the **subscription** or **management group** scope that contains the Storage Accounts.
  - Minimum needed for:
    - `GET /subscriptions`
    - `GET /subscriptions/{subscriptionId}/providers/Microsoft.Storage/storageAccounts`
- If you want to restrict to specific resource groups:
  - Assign `Reader` on the resource groups that contain the Storage Accounts instead of the full subscription.

RBAC assignment examples (conceptual):
- Scope: `/subscriptions/{subscriptionId}`
- Role: `Reader`
- Principal: `<Logic App managed identity objectId>`

#### 3. Storage data-plane permissions (Blob service stats)

The Blob service stats API is a **data-plane** operation. To call it with a managed identity, you have two main options:

1. **Use Azure RBAC for Storage data-plane** (recommended):
   - Assign one of the following roles at the Storage Account level:
     - `Storage Blob Data Reader`
   - Scope example:
     - `/subscriptions/{subscriptionId}/resourceGroups/{rgName}/providers/Microsoft.Storage/storageAccounts/{accountName}`
   - Principal: Logic App managed identity.

2. **Use a Shared Access Signature (SAS) or account key** (less preferred):
   - Store the secret (SAS token or key) in **Azure Key Vault**.
   - Grant the Logic App access to Key Vault via:
     - `Key Vault Secrets User` or `Key Vault Secrets Officer`, or a custom role with `secrets/get` permission.
   - The Logic App reads the secret and appends it to the Blob stats URI.

Recommended approach: **Azure RBAC for Storage data-plane** with `Storage Blob Data Reader`, to avoid explicit key usage.

#### 4. Key Vault integration (optional but recommended)

If you use any secrets (SMTP credentials, SAS tokens, or non-O365 email connectors), configure:

- A **Key Vault** resource per environment (e.g., dev / prod).
- Grant the Logic App managed identity:
  - Role: `Key Vault Secrets User` at the Key Vault scope.
- Store secrets:
  - `smtp-connection-string` (if applicable).
  - Any SAS tokens or sensitive configuration not suitable as plain Logic App parameters.

In the Logic App:
- Use the Key Vault connector or direct REST calls (with managed identity) to retrieve secrets at runtime.

#### 5. Office 365 email connector permissions

For sending emails via Office 365:

- Use the Office 365 Outlook connector.
- Auth is typically **delegated** (user account) or **service principal**:
  - For delegated:
    - An administrator or service account signs in and grants connector access.
  - For service principal:
    - Configure an application registration and grant it Send Mail permissions, then use that connection.

Security considerations:
- Prefer a **dedicated service account** / app registration for automation, not a personal user account.
- Limit mailbox send-as rights to what is necessary.

#### 6. Cross-subscription and multi-tenant scenarios

- **Single tenant, multiple subscriptions**:
  - The Logic App’s managed identity exists in one tenant.
  - Assign necessary RBAC roles (`Reader`, `Storage Blob Data Reader`) **in each subscription** the Logic App should monitor.

- **Multi-tenant** (rare for this scenario):
  - You cannot directly use a managed identity across tenants.
  - You would instead:
    - Use separate Logic Apps per tenant, or
    - Use a service principal with consent in each tenant (more complex; not covered in the base design).

#### 7. Summary of required roles

Per monitored subscription/resource group:
- **ARM**:
  - `Reader` (scope: subscription or resource group).

Per monitored Storage Account:
- **Data-plane**:
  - `Storage Blob Data Reader` (scope: Storage Account).

Optional:
- **Key Vault**:
  - `Key Vault Secrets User` (scope: Key Vault).


