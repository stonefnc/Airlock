# Airlock

Airlock is a PowerShell 7 module that automates user onboarding and offboarding in Microsoft Entra ID. It uses the Microsoft Graph PowerShell SDK with app-only authentication, supports `-WhatIf` on every change, and writes a timestamped change log for each run so the result can be attached to a ticket.

This README is the spec. Anything not yet built is marked **planned**.

**Preview before you change anything.** Every command that changes a tenant accepts `-WhatIf`. Run it with `-WhatIf` first, read the plan and the change log it writes, and only then run it for real.

## Status

The onboarding and offboarding MVP is written. It has not yet been run against a tenant, and the Pester suite has been written but not yet executed. See Testing for exactly what has and has not been checked.

| Area | Status |
| --- | --- |
| Project scaffold and module loader | built |
| `Connect-Airlock` | built, tests written, not yet run (see Testing) |
| `New-AirlockUser` | built, tests written, not yet run (see Testing) |
| `Remove-AirlockUser` | built, tests written, not yet run (see Testing) |
| Change log (CSV) | built, tests written, not yet run (see Testing) |
| Pester test suite (all Graph calls mocked) | written, not yet run |
| `docs/permissions.md` | built, with a list of items to verify in a test tenant |
| OneDrive handover to the manager | planned |
| Removal of directory roles and group ownership at offboarding | planned |
| Intune compliance report | planned (later release) |
| Stale device report | planned (later release) |

## Quick start

1. Install PowerShell 7.2 or later, the Graph SDK (version 2) and Pester:

   ```powershell
   Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Users.Actions, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Files -Scope CurrentUser
   Install-Module Pester -MinimumVersion 5.3 -Scope CurrentUser
   ```

2. Run the tests. They need no tenant:

   ```powershell
   Invoke-Pester ./tests
   ```

3. Set up a test tenant app registration, `.env` and `config/roles.json` as described in Setup. Copy `config/users.example.csv` to `config/users.csv` and edit it. Real role maps and user lists are git-ignored.
4. Connect, then preview an onboarding with `-WhatIf` and open the change log it names:

   ```powershell
   Import-Module ./src/Airlock.psd1
   Connect-Airlock -Command New-AirlockUser
   New-AirlockUser -CsvPath ./config/users.csv -WhatIf
   ```

5. If the plan is what you expect, run the same command without `-WhatIf`.

New users are created with a random temporary password. It is returned on the result and nowhere else, so capture the result:

```powershell
$results = New-AirlockUser -CsvPath ./config/users.csv
$results | Select-Object UserPrincipalName, Outcome, OneDrive, LogPath
```

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

Alternatively, set the same names as environment variables. Environment variables take precedence over `.env`. Values read from `.env`, including the client secret, are kept in memory only and are not copied into the process environment, so child processes do not inherit them. The thumbprint and the secret are trimmed, and spaces are removed from the thumbprint, so a value pasted from a certificate viewer works.

## A note on scopes

With app-only authentication the Graph SDK does not request scopes at sign-in. The permissions are fixed on the app registration and arrive in the access token as application roles. Airlock handles this in two ways:

* Each command declares the exact application permissions it needs.
* `Connect-Airlock -Command <name>` reads the application roles from the `roles` claim of the access token and fails early with a clear message if one is missing, before any change is attempted. The Graph SDK does not hand over the token, so Airlock makes one small request and reads the token back from it. The scopes on the Graph context are not used first, because for an app-only session they are often empty. If the token cannot be read, the context scopes are used. If neither can be read, Airlock warns that the permissions were not checked and connects anyway, so a missing permission then shows up as an error on the first call that needs it. The token is never logged or stored.

Least privilege is therefore enforced by what you grant to the app registration, and Airlock verifies it rather than assuming it. Reading the token this way has not yet been confirmed against a live tenant, see `docs/permissions.md`.

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

Connects to Microsoft Graph with app-only authentication. Reads `AIRLOCK_TENANT_ID`, `AIRLOCK_CLIENT_ID`, and either `AIRLOCK_CERT_THUMBPRINT` or `AIRLOCK_CLIENT_SECRET`. If both a certificate and a secret are set, the certificate is used. Verifies the token carries the permissions required by each command named in `-Command`, and if any is missing it disconnects and fails before any change is attempted. Any earlier connection is cleared first, so a failed attempt never leaves a stale one behind. Returns the connection details (tenant, client, auth method, permissions, and whether and how they were checked) and never the secret or the token.

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

### Remove-AirlockUser

Offboards one or more users. Run `Connect-Airlock -Command Remove-AirlockUser` first. The parameter accepts several names and pipeline input, so `Import-Csv ./leavers.csv | Remove-AirlockUser -WhatIf` works for any CSV with a `UserPrincipalName` column. For each user it:

1. Records the user's manager in the change log as the recipient of the OneDrive content.
2. Blocks sign-in.
3. Revokes active sessions and refresh tokens.
4. Removes directly assigned licenses.
5. Removes the user from groups.

The account is not deleted. The OneDrive handover itself (granting the manager access) is planned for a later release. For now the manager is recorded in the log and on the result as `OneDriveRecipient` so the step can be completed from the ticket. If the user has no manager the log says so.

The command is idempotent. A user who is already offboarded is reported as `AlreadyOffboarded` and nothing is changed. Each step checks the current state first. Revoking sessions cannot be checked, so it runs only when something else is still to be done for the user. That means a run that stopped part way is finished by running it again.

A failed step is recorded and the remaining steps still run, because a half offboarded account is worse than a report with one failure. The user is then reported as `Failed`. If the user cannot be found, or the lookups fail, nothing is changed.

Some things cannot be removed through Graph and are skipped with the reason in the log:

* Groups with dynamic membership, because their members are set by rule.
* Groups synced from an on-premises directory, which must be changed there.
* Mail-enabled distribution lists, which are managed in Exchange.
* A license that comes from a group. It is removed when the group membership is removed. If a license is assigned both directly and through a group, only the direct assignment is removed.

Directory roles, group ownership and administrative unit membership are not changed. Blocking sign-in already stops the account from using them, but check them as part of your offboarding checklist. Removing them is planned.

With `-WhatIf` nothing is changed. The lookups still run, so the preview reflects the real state of the tenant. Without `-WhatIf` the command does not prompt by default. Use `-WhatIf` first, or add `-Confirm` to be asked before each step.

Each user produces one result object:

| Property | Meaning |
| --- | --- |
| `UserPrincipalName` | As supplied |
| `Outcome` | `Offboarded`, `AlreadyOffboarded`, `WhatIf` or `Failed` |
| `OneDriveRecipient` | The manager who receives the OneDrive content, or empty |
| `Error` | The first failure, if any |
| `Actions` | The change log entries for this user, in order (see Change log) |

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

## Change log

Every run writes one CSV file to `./logs` (or `AIRLOCK_LOG_DIR`, created if it does not exist) named `airlock-<command>-<yyyyMMdd-HHmmss>-<runid8>.csv`, for example `airlock-new-airlockuser-20261020-143000-5b0e1f6a.csv`. The time is UTC and the last part is the first eight characters of the run id, so two runs in the same second never overwrite each other. The path is on every result as `LogPath`, and the same entries are on each result as `Actions`. One row is written per action. Columns:

| Column | Meaning |
| --- | --- |
| Timestamp | UTC time of the action in ISO 8601 |
| RunId | Identifier shared by all rows from one run |
| Command | The Airlock command that ran |
| Target | The user principal name acted on |
| Action | For example `CreateUser`, `AddGroup`, `AssignLicense`, `BlockSignIn` |
| Status | `Applied`, `Skipped`, `WhatIf`, `Failed`, or `Info` (a check that changes nothing, such as the OneDrive check) |
| Detail | Group name, license SKU, error text, or manager, depending on the action |

A `-WhatIf` run writes the same file with every change recorded as `WhatIf`, so the plan can be reviewed or attached to an approval ticket before the real run. Previews are logged because a preview is the log you most want to attach.

The log never contains the temporary password or any secret. Values that begin with `=`, `+`, `-` or `@` are written with a leading apostrophe so that a spreadsheet does not read them as a formula. If the log file cannot be written, for example because the folder is read only, a warning is shown and the results of the run are still returned. The `logs` directory is git-ignored.

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.3 -Scope CurrentUser
Invoke-Pester ./tests
```

The tests mock every Graph call and do not need a tenant, a network connection, or the Graph SDK installed. The Graph commands are replaced by stand-in functions in `tests/TestHelpers.ps1`, and a small in-memory tenant stands behind the mocks so that running a command twice can be checked. They cover:

* `-WhatIf` making no changes, for one user, a CSV, an existing user and offboarding.
* Idempotency, by running each command twice against the state the first run left behind.
* A missing role, and bad CSV rows of every kind: bad or missing user principal name, missing display name, undefined role, invalid manager, duplicates, and a file with a missing column.
* Failure handling, including one failed step not stopping the others.
* The change log: file name, columns, `-WhatIf` runs, formula protection, an unwritable folder, and that the temporary password never reaches the file.

### What has and has not been checked

The Pester suite was written on a machine that has only Windows PowerShell 5.1 and Pester 3.4, so it has **not been run**. What was checked there:

* Every script in the repository parses without error.
* The module functions were run under Windows PowerShell 5.1 against stand-in Graph functions, and the same scenarios as the tests behaved as described in this README.

That is evidence the logic is right. It is not a passing Pester run. The first run of `Invoke-Pester` on PowerShell 7 with Pester 5.3 may well turn up small problems in the test files, such as mock scoping. The module itself has also never been run against a real tenant. `docs/permissions.md` lists what the mocks cannot confirm and what to verify in a test tenant first.

## Known limitations

* Offboarding does not remove directory roles, group ownership or administrative unit membership. Check these as part of your offboarding checklist.
* The OneDrive content is not handed over. The manager is recorded as the recipient so it can be done from the ticket.
* Onboarding checks existing group membership by reading each group's members. For a very large group this is slow when the user already exists.
* Groups that can be assigned to Entra roles, dynamic groups, groups synced from on-premises, and mail-enabled distribution lists cannot be changed through these calls. They are skipped or recorded as failed, with the reason in the log.
* A user principal name containing a character outside letters, digits and `. _ % + ! # ^ ~ ' -` is rejected.
* The Graph PowerShell SDK command and parameter names are not confirmed against a live tenant yet.

## Layout

```
src/
  Airlock.psd1       module manifest
  Airlock.psm1       loads Private and Public scripts
  Public/            exported commands
  Private/           internal helpers
config/              example role map and example CSV
tests/               Pester tests and the Graph stand-ins they use
docs/                permissions.md
logs/                change logs written at run time (git-ignored)
```

## Data and safety

Use a test tenant. The examples use the reserved `contoso.example` domain and fictional names. Never commit `.env`, certificates, real role maps, or real user lists. The `.gitignore` excludes them.
