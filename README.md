# Airlock

Airlock is a PowerShell 7 module that automates user onboarding and offboarding in Microsoft Entra ID. It uses the Microsoft Graph PowerShell SDK with app-only authentication, supports `-WhatIf` on every change, and writes a timestamped change log for each run so the result can be attached to a ticket.

This README is the spec. Anything not yet built is marked **planned**.

## Status

| Area | Status |
| --- | --- |
| Project scaffold and module loader | built |
| `Connect-Airlock` | built, tests written, not yet run (see Testing) |
| `New-AirlockUser` | built, tests written, not yet run (see Testing) |
| `Remove-AirlockUser` | planned |
| Change log (CSV) | planned |
| Pester test suite (all Graph calls mocked) | planned |
| `docs/permissions.md` | planned |
| Intune compliance report | planned (later release) |
| Stale device report | planned (later release) |

## Requirements

* PowerShell 7.2 or later
* Microsoft Graph PowerShell SDK (`Microsoft.Graph.Authentication`, `Microsoft.Graph.Users`, `Microsoft.Graph.Groups`, `Microsoft.Graph.Identity.DirectoryManagement`, `Microsoft.Graph.Users.Actions`, `Microsoft.Graph.Files`)
* Pester 5.3 or later for running the tests
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

### Connect-Airlock

Connects to Microsoft Graph with app-only authentication. Reads `AIRLOCK_TENANT_ID`, `AIRLOCK_CLIENT_ID`, and either `AIRLOCK_CERT_THUMBPRINT` or `AIRLOCK_CLIENT_SECRET`. If both a certificate and a secret are set, the certificate is used. Verifies the token carries the permissions required by each command named in `-Command`, and if any is missing it disconnects and fails before any change is attempted. Returns the connection details (tenant, client, auth method, permissions) and never the secret.

### New-AirlockUser

Accepts one user through parameters or many through `-CsvPath`. Run `Connect-Airlock -Command New-AirlockUser` first. For each user it:

1. Looks up everything it needs before changing anything: the user, the manager, each group in the role, and the license SKU with its free unit count.
2. Creates the Entra ID user if it does not exist.
3. Sets the manager if one is given.
4. Adds the user to the groups mapped to the role in `roles.json`.
5. Assigns the license mapped to the role.
6. Checks whether the OneDrive has been provisioned.

A new account gets a random 20 character temporary password and must change it at first sign-in. The password is returned once on the result as a `SecureString` named `TemporaryPassword` and is never written to the change log. Pass it to the new user through your approved channel. It is not recoverable afterwards.

The command is idempotent. Re-running it for an existing user does not create a second user, does not duplicate group membership, does not reset the manager if it is already correct, and does not reassign a license that is already present. Each such step is recorded as `Skipped`. If an existing user has no usage location, one is set from `defaults.usageLocation` before the license is assigned. Dynamic membership groups are skipped because their members are set by rule.

Because all lookups happen first, these problems fail that user without changing anything: a role that is not in `roles.json`, a group that is missing or whose name matches more than one group, a manager that does not exist, a license SKU the tenant does not have, and no free units left for the license. In a CSV the free units are counted down as users are processed, so a large file cannot run past the licenses available. A problem with one row never stops the other rows. A failure while applying a step (for example one group that cannot be added) is recorded, the remaining steps still run, and that user is reported as `Failed`.

The OneDrive check is best effort and never blocks onboarding. It reports `Ready`, `Pending` (the drive is not provisioned yet, which is normal just after a license is assigned), `Unknown` (the check itself failed, for example for lack of permission) or `NotChecked` (the role has no license, or this is a preview of a user that does not exist yet).

With `-WhatIf` nothing is changed. The lookups still run, so the preview reflects the real state of the tenant, and each planned change is recorded as `WhatIf`.

Each user produces one result object:

| Property | Meaning |
| --- | --- |
| `UserPrincipalName`, `Role` | As supplied |
| `Outcome` | `Created`, `Existing`, `WhatIf` or `Failed` |
| `Created` | True if this run created the account |
| `OneDrive` | `Ready`, `Pending`, `Unknown` or `NotChecked` |
| `TemporaryPassword` | A `SecureString`, only when this run created the account |
| `Error` | The first failure, if any |
| `Actions` | The change log entries for this user, in order (see Change log) |

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

Status: the entries described here are already recorded in memory and returned on each result as `Actions`. Writing them to the CSV file below is planned.

Every run will write one CSV file to `./logs` (or `AIRLOCK_LOG_DIR`) named `airlock-<command>-<yyyyMMdd-HHmmss>.csv`. One row is written per action. Columns:

| Column | Meaning |
| --- | --- |
| Timestamp | UTC time of the action in ISO 8601 |
| RunId | Identifier shared by all rows from one run |
| Command | The Airlock command that ran |
| Target | The user principal name acted on |
| Action | For example `CreateUser`, `AddGroup`, `AssignLicense`, `BlockSignIn` |
| Status | `Applied`, `Skipped`, `WhatIf`, `Failed`, or `Info` (a check that changes nothing, such as the OneDrive check) |
| Detail | Group name, license SKU, error text, or manager, depending on the action |

A `-WhatIf` run writes the same file with every change recorded as `WhatIf`, so the plan can be reviewed or attached to an approval ticket before the real run. The `logs` directory is git-ignored.

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.3 -Scope CurrentUser
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
