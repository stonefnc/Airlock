# Airlock

Airlock is a PowerShell 7 module that automates user onboarding and offboarding in Microsoft Entra ID. It uses the Microsoft Graph PowerShell SDK with app-only authentication, supports `-WhatIf` on every change, and writes a timestamped change log for each run so the result can be attached to a ticket.

This README is the spec. Anything not yet built is marked **planned**.

## Status

| Area | Status |
| --- | --- |
| Project scaffold and module loader | built |
| `Connect-Airlock` | planned |
| `New-AirlockUser` | planned |
| `Remove-AirlockUser` | planned |
| Change log (CSV) | planned |
| Pester test suite (all Graph calls mocked) | planned |
| `docs/permissions.md` | planned |
| Intune compliance report | planned (later release) |
| Stale device report | planned (later release) |

## Requirements

* PowerShell 7.2 or later
* Microsoft Graph PowerShell SDK (`Microsoft.Graph.Authentication`, `Microsoft.Graph.Users`, `Microsoft.Graph.Groups`, `Microsoft.Graph.Identity.DirectoryManagement`, `Microsoft.Graph.Users.Actions`, `Microsoft.Graph.Files`)
* Pester 5 for running the tests
* A Microsoft 365 test tenant and an app registration (see Setup)

The tests need none of the Graph modules to be signed in. Every Graph call is mocked.

## Setup

1. Register an application in your test tenant and add a certificate (preferred) or a client secret.
2. Grant the application permissions listed in `docs/permissions.md` and give admin consent. Grant only what you plan to use. Onboarding and offboarding need different permission sets.
3. Copy `.env.example` to `.env` and fill in the tenant ID, client ID, and either a certificate thumbprint or a client secret. `.env` is git-ignored.
4. Copy `config/roles.example.json` to `config/roles.json` and edit it to match your groups and license SKUs.

Alternatively, set the same names as environment variables. Environment variables take precedence over `.env`.

## A note on scopes

With app-only authentication the Graph SDK does not request scopes at sign-in. The permissions are fixed on the app registration and arrive in the access token as application roles. Airlock handles this in two ways:

* Each command declares the exact application permissions it needs.
* `Connect-Airlock -Command <name>` reads the roles from the token and fails early with a clear message if one is missing, before any change is attempted.

Least privilege is therefore enforced by what you grant to the app registration, and Airlock verifies it rather than assuming it.

## Usage

Import the module:

```powershell
Import-Module ./src/Airlock.psd1
```

Connect (reads `.env` or environment variables):

```powershell
Connect-Airlock -Command New-AirlockUser
```

Onboard one user, previewing first:

```powershell
New-AirlockUser -UserPrincipalName ada.example@contoso.example `
    -DisplayName 'Ada Example' -Role engineer `
    -Manager grace.manager@contoso.example -WhatIf
```

Onboard from a CSV:

```powershell
New-AirlockUser -CsvPath ./config/users.example.csv -RolesPath ./config/roles.json
```

Offboard a user, previewing first:

```powershell
Connect-Airlock -Command Remove-AirlockUser
Remove-AirlockUser -UserPrincipalName ada.example@contoso.example -WhatIf
```

All commands that change anything accept `-WhatIf` and `-Confirm`.

## Commands

### Connect-Airlock (planned)

Connects to Microsoft Graph with app-only authentication. Reads `AIRLOCK_TENANT_ID`, `AIRLOCK_CLIENT_ID`, and either `AIRLOCK_CERT_THUMBPRINT` or `AIRLOCK_CLIENT_SECRET`. Verifies the token carries the permissions required by the named command.

### New-AirlockUser (planned)

Accepts one user through parameters or many through `-CsvPath`. For each user it:

1. Creates the Entra ID user if it does not exist.
2. Adds the user to the groups mapped to the role in `roles.json`.
3. Assigns the license mapped to the role.
4. Sets the manager if one is given.
5. Checks whether the OneDrive has been provisioned and reports `Ready` or `Pending`. A pending OneDrive is normal for a new license and is not treated as a failure.

The command is idempotent. Re-running it for an existing user does not create a second user, does not duplicate group membership, and does not reassign a license that is already present. Each such step is logged as `Skipped`.

A user whose role is missing from `roles.json` is rejected before anything is created. In CSV mode a bad row is logged as `Failed` with the reason, and processing continues with the next row.

### Remove-AirlockUser (planned)

For the named user it:

1. Blocks sign-in.
2. Revokes active sessions and refresh tokens.
3. Removes assigned licenses.
4. Removes the user from groups that allow direct membership changes. Dynamic groups are skipped and logged.
5. Records the user's manager in the change log as the recipient of the OneDrive content.

The OneDrive handover itself (granting the manager access) is planned for a later release. For now the manager is recorded so the step can be completed from the ticket.

The account is not deleted.

## Role map

`config/roles.example.json` shows the format. Groups are referenced by display name. If a display name matches more than one group the user is not changed and the row is logged as `Failed`. Licenses are referenced by SKU part number.

```json
{
  "defaults": { "usageLocation": "US" },
  "roles": {
    "engineer": {
      "groups": ["Engineering", "VPN Users", "Source Access"],
      "licenseSku": "ENTERPRISEPACK"
    }
  }
}
```

## CSV format

`config/users.example.csv` shows the format. Required columns are `UserPrincipalName`, `DisplayName`, and `Role`. Optional columns are `GivenName`, `Surname`, `Manager`, `Department`, and `JobTitle`.

## Change log (planned)

Every run writes one CSV file to `./logs` (or `AIRLOCK_LOG_DIR`) named `airlock-<command>-<yyyyMMdd-HHmmss>.csv`. One row is written per action. Columns:

| Column | Meaning |
| --- | --- |
| Timestamp | UTC time of the action in ISO 8601 |
| RunId | Identifier shared by all rows from one run |
| Command | The Airlock command that ran |
| Target | The user principal name acted on |
| Action | For example `CreateUser`, `AddGroup`, `AssignLicense`, `BlockSignIn` |
| Status | `Applied`, `Skipped`, `WhatIf`, or `Failed` |
| Detail | Group name, license SKU, error text, or manager, depending on the action |

A `-WhatIf` run writes the same file with every change recorded as `WhatIf`, so the plan can be reviewed or attached to an approval ticket before the real run. The `logs` directory is git-ignored.

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Invoke-Pester ./tests
```

The tests mock every Graph call and do not need a tenant, a network connection, or the Graph SDK to be signed in. They cover `-WhatIf` making no changes, idempotency, a missing role, and bad CSV rows.

## Layout

```
src/
  Airlock.psd1       module manifest
  Airlock.psm1       loads Private and Public scripts
  Public/            exported commands
  Private/           internal helpers
config/              example role map and example CSV
tests/               Pester tests
docs/                permissions and notes
```

## Data and safety

Use a test tenant. The examples use the reserved `contoso.example` domain and fictional names. Never commit `.env`, certificates, real role maps, or real user lists. The `.gitignore` excludes them.
