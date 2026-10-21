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
| OneDrive handover to the manager at offboarding (grants access, optional) | built, tests written, not yet run, the Graph calls are unconfirmed (see Testing) |
| Directory role removal at offboarding (optional) | built, tests written, not yet run, the Graph calls are unconfirmed (see Testing) |
| Group ownership transfer or removal at offboarding (optional) | built, tests written, not yet run, one Graph call is documented as unsupported for apps (see `docs/permissions.md`) |
| Removal of Privileged Identity Management eligible roles, and of application or service principal ownership | planned |
| Intune compliance report (`Get-AirlockComplianceReport`, read only) | built, tests written, not yet run, the Graph call is unconfirmed (see Testing) |
| Stale device report (`Get-AirlockStaleDevice`, read only) | built, tests written, not yet run, the Graph call is unconfirmed (see Testing) |
| License usage report (`Get-AirlockLicenseUsage`, read only) | built, tests written, not yet run, the Graph call is unconfirmed (see Testing) |

## Quick start

1. Install PowerShell 7.2 or later, the Graph SDK (version 2) and Pester:

   ```powershell
   Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Users.Actions, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.Governance, Microsoft.Graph.DeviceManagement, Microsoft.Graph.Files -MinimumVersion 2.0.0 -Scope CurrentUser
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
* Microsoft Graph PowerShell SDK **2.0.0 or later** (`Microsoft.Graph.Authentication`, `Microsoft.Graph.Users`, `Microsoft.Graph.Groups`, `Microsoft.Graph.Identity.DirectoryManagement`, `Microsoft.Graph.Identity.Governance` for the directory role commands, `Microsoft.Graph.DeviceManagement` for the Intune reports, `Microsoft.Graph.Users.Actions`, `Microsoft.Graph.Files`). Version 2 is the floor because the code uses `Connect-MgGraph -NoWelcome` and the version 2 command names. No particular 2.x release has been tested yet, so once you have validated one in your test tenant, pin that exact version. Command names can change between SDK releases, see `docs/permissions.md`.
* Pester 5.3 or later for running the tests
* A Microsoft 365 test tenant and an app registration (see Setup)

The tests need none of the Graph modules to be signed in. Every Graph call is mocked.

## Setup

1. Register an application in your test tenant and add a certificate (preferred) or a client secret.
2. Grant the application permissions listed in `docs/permissions.md` and give admin consent. Grant only what you plan to use. Onboarding and offboarding need different permission sets. `Files.Read.All` is optional: without it onboarding skips the OneDrive check and reports it as `NotChecked`. Three offboarding permissions are optional and higher privilege, and you should grant each only if you want the step it enables: `RoleManagement.ReadWrite.Directory` (remove directory roles), `Group.ReadWrite.All` (move group ownership) and `Files.ReadWrite.All` (give the manager access to the OneDrive). Keep them on the offboarding app registration only.
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

The command is idempotent. Re-running it for an existing user does not create a second user, does not duplicate group membership, does not reset the manager if it is already correct, and does not reassign a license that is already present. Each such step is recorded as `Skipped`. If an existing user has no usage location, one is set from `defaults.usageLocation` before the license is assigned.

Some groups cannot be changed through Graph, so Airlock works this out in the lookups and records them as `Skipped` with the reason, instead of failing after the user has been created. They are: groups with dynamic membership (members are set by rule), groups synced from an on-premises directory, and mail-enabled groups that are not Microsoft 365 groups, which means distribution lists and mail-enabled security groups (managed in Exchange). Microsoft 365 groups are mail-enabled but can be changed, so they are added normally. The user does not end up in a skipped group, so check the log if a role maps to one of these types.

A new Entra user can take a few seconds to become visible to the calls that follow. When the account was created in this run, Airlock retries the manager, group and license calls if Graph says the object does not exist, pausing 2, 4, 8 and then 16 seconds. If it still fails the log says so and tells you to run the command again, which finishes the job without repeating anything.

Because all lookups happen first, these problems fail that user without changing anything: a role that is not in `roles.json`, a group that is missing or whose name matches more than one group, a manager that does not exist, a license SKU the tenant does not have, and no free units left for the license. In a CSV the free units are counted down as users are processed, so a large file cannot run past the licenses available. A problem with one row never stops the other rows. A failure while applying a step (for example one group that cannot be added) is recorded, the remaining steps still run, and that user is reported as `Failed`.

The OneDrive check is best effort and never blocks onboarding. It reports `Ready`, `Pending` (the drive is not provisioned yet, which is normal just after a license is assigned), `Unknown` (the check itself failed, for example for lack of permission) or `NotChecked` (the role has no license, this is a preview of a user that does not exist yet, or `Files.Read.All` is not granted to the app, in which case `Connect-Airlock` warns once). Microsoft documents the underlying call as not supported for application permissions, which is why the permission is optional and why this needs checking in a test tenant.

With `-WhatIf` nothing is changed. The lookups still run, so the preview reflects the real state of the tenant, and each planned change is recorded as `WhatIf`.

Each user produces one result object:

| Property | Meaning |
| --- | --- |
| `UserPrincipalName`, `Role` | As supplied |
| `Outcome` | `Created`, `Existing`, `WhatIf`, `Declined` or `Failed`. `Declined` means a step was declined at a `-Confirm` prompt, see `Actions` for which |
| `Created` | True if this run created the account |
| `OneDrive` | `Ready`, `Pending`, `Unknown` or `NotChecked` |
| `TemporaryPassword` | A `SecureString`, only when this run created the account |
| `Error` | The first failure, if any |
| `Actions` | The change log entries for this user, in order (see Change log) |

### Remove-AirlockUser

Offboards one or more users. Run `Connect-Airlock -Command Remove-AirlockUser` first. The parameter accepts several names and pipeline input, so `Import-Csv ./leavers.csv | Remove-AirlockUser -WhatIf` works for any CSV with a `UserPrincipalName` column. For each user it:

1. Records the user's manager in the change log, and on the result as `OneDriveRecipient`.
2. Blocks sign-in.
3. Revokes active sessions and refresh tokens.
4. Removes the user's active directory roles (optional, see below).
5. Gives the manager write access to the user's OneDrive (optional, see below).
6. Takes the user out of the groups they own, without leaving a group ownerless (optional, see below).
7. Removes directly assigned licenses.
8. Removes the user from groups.

The order is deliberate. Privilege goes first. The OneDrive is handed over before the licenses are removed, because removing a license is what starts the clock on a OneDrive being cleaned up. Ownership is moved before membership is removed. The account is not deleted.

#### The three optional steps

Steps 4, 5 and 6 each need a higher privilege application permission that you must grant on purpose. A registration without them keeps working exactly as before. `Connect-Airlock` warns once, and each missing permission is recorded as `Skipped` with the permission named, for every user. `-SkipStep DirectoryRoles`, `-SkipStep GroupOwnership` and `-SkipStep OneDriveHandover` (several can be given) skip a step on request even when the permission is granted. These steps read from the tenant when they run, so a failed read in one is recorded for that step only and the next step still runs.

* **Directory roles** (`RoleManagement.ReadWrite.Directory`). Each active role assignment the user holds is removed on its own, so `-WhatIf` lists exactly which roles would go. The log names the role and, for an administrative unit scope, the scope. Roles that are only eligible through Privileged Identity Management are not read or removed, and blocking sign-in already stops the account using them. There is no guard against removing the last Global Administrator, so keep a break-glass account and run `-WhatIf` first.
* **OneDrive handover** (`Files.ReadWrite.All`). The manager is invited with the write role on the root folder of the user's drive, directly and with no email. This grants access. It does not transfer ownership or copy files, because Graph has no call that transfers ownership of a OneDrive. It is skipped, with the reason, when the user has no manager, when the manager could not be read, or when the user has no OneDrive. If the manager already has write access it does nothing. If the current access cannot be read, nothing is shared.
* **Group ownership** (`Group.ReadWrite.All`). This is separate from membership removal and is logged as `AddGroupOwner` and `RemoveGroupOwner`. The safe default is `-OwnershipAction TransferToManager`. Where the user is one of several owners they are removed as an owner and nobody new is given ownership. Where they are the only owner, the manager is added as owner first and the user is removed after. If the manager cannot be added, or there is no manager, the user is left as owner and the reason is logged, because Graph does not allow the last owner to be removed and a group without an owner is worse than a disabled owner. With `-OwnershipAction Remove` the manager is never added, and a sole owner is left in place. Groups synced from on-premises, and mail-enabled groups that are not Microsoft 365 groups, are skipped with the reason. Dynamic groups are not skipped, because dynamic membership does not affect owners. Only groups are covered.

Reading the groups a user owns is documented by Microsoft as not supported for application permissions. If your tenant refuses it, the ownership step records one failure per user and changes nothing, and the rest of offboarding still runs. Check this first, see `docs/permissions.md`.

```powershell
Remove-AirlockUser -UserPrincipalName ada.example@contoso.example -WhatIf
Remove-AirlockUser -UserPrincipalName ada.example@contoso.example -SkipStep OneDriveHandover -OwnershipAction Remove -WhatIf
```

The command is idempotent. A user who is already offboarded is reported as `AlreadyOffboarded` and nothing is changed. Each step checks the current state first. Revoking sessions cannot be checked, so it runs only when something else is still to be done for the user. That means a run that stopped part way is finished by running it again.

A failed step is recorded and the remaining steps still run, because a half offboarded account is worse than a report with one failure. The user is then reported as `Failed`. If the user cannot be found, or the lookups fail, nothing is changed.

Some things cannot be removed through Graph and are skipped with the reason in the log:

* Groups with dynamic membership, because their members are set by rule.
* Groups synced from an on-premises directory, which must be changed there.
* Mail-enabled groups that are not Microsoft 365 groups, that is distribution lists and mail-enabled security groups, which are managed in Exchange.
* A license that comes from a group. It is removed when the group membership is removed. If a license is assigned both directly and through a group, only the direct assignment is removed.

Administrative unit membership is not changed, and neither are directory roles that are only eligible through Privileged Identity Management, nor applications and service principals the user owns. Blocking sign-in already stops the account from using them, but check them as part of your offboarding checklist. Removing them is planned.

With `-WhatIf` nothing is changed. The lookups still run, so the preview reflects the real state of the tenant. Without `-WhatIf` the command does not prompt by default. Use `-WhatIf` first, or add `-Confirm` to be asked before each step.

The names are read from the pipeline first and processed once the input ends, so the results appear together at the end. This is so the change log is always written, even if the run is stopped with Ctrl+C or ends with an unexpected error.

Each user produces one result object:

| Property | Meaning |
| --- | --- |
| `UserPrincipalName` | As supplied |
| `Outcome` | `Offboarded`, `AlreadyOffboarded`, `WhatIf`, `Declined` or `Failed`. `Declined` means a step was declined at a `-Confirm` prompt, so the user is not fully offboarded, see `Actions` |
| `OneDriveRecipient` | The manager recorded as the person who receives the OneDrive, or empty |
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
| Status | `Applied`, `Skipped` (already in place, or cannot be changed, with the reason), `WhatIf`, `Failed`, `Declined` (declined at a `-Confirm` prompt), or `Info` (a check that changes nothing, such as the OneDrive check) |
| Detail | Group name, license SKU, error text, or manager, depending on the action |

A `-WhatIf` run writes the same file with every change recorded as `WhatIf`, so the plan can be reviewed or attached to an approval ticket before the real run. Previews are logged because a preview is the log you most want to attach.

The file is UTF-8 with a byte order mark, so Excel shows names with accents correctly. The log never contains the temporary password or any secret. Values that begin with `=`, `+`, `-` or `@` are written with a leading apostrophe so that a spreadsheet does not read them as a formula. If the log file cannot be written, for example because the folder is read only, a warning is shown and the results of the run are still returned. The `logs` directory is git-ignored.

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
* The three optional offboarding steps, each on its own and through `Remove-AirlockUser`: the happy path, `-WhatIf` making no write, an idempotent re-run, a partial run finished by a second run, no manager, no OneDrive, a user who owns nothing, `-SkipStep`, a missing permission, and a Graph failure recorded without stopping the rest of the offboarding. For group ownership the tests also prove that a last owner is never removed.
* The change log: file name, columns, `-WhatIf` runs, formula protection, an unwritable folder, and that the temporary password never reaches the file.

### What has and has not been checked

The Pester suite was written on a machine that has only Windows PowerShell 5.1 and Pester 3.4, so it has **not been run**. What was checked there:

* Every script in the repository parses without error.
* The module functions were run under Windows PowerShell 5.1 against stand-in Graph functions, and the same scenarios as the tests behaved as described in this README.

That is evidence the logic is right. It is not a passing Pester run. The first run of `Invoke-Pester` on PowerShell 7 with Pester 5.3 may well turn up small problems in the test files, such as mock scoping. The module itself has also never been run against a real tenant. `docs/permissions.md` lists what the mocks cannot confirm and what to verify in a test tenant first.

## Known limitations

* Offboarding does not change administrative unit membership, directory roles that are only eligible through Privileged Identity Management, or applications and service principals the user owns. Check these as part of your offboarding checklist.
* The OneDrive handover grants the manager write access. It does not transfer ownership or copy files. Whether the invitation on the root folder works for a work or school OneDrive with application access, and whether the rest of the OneDrive inherits it, has not been confirmed against a live tenant.
* The directory role, group ownership and OneDrive steps are optional and need high privilege permissions. Their Graph calls have only been checked against Microsoft's documentation and against mocks. One of them, reading the groups a user owns, is documented as unsupported for application permissions.
* There is no guard against removing the last Global Administrator through the directory role step. Run `-WhatIf` first and keep a break-glass account.
* Onboarding checks existing group membership by reading each group's members. For a very large group this is slow when the user already exists.
* Groups that can be assigned to Entra roles, dynamic groups, groups synced from on-premises, and mail-enabled groups that are not Microsoft 365 groups cannot be changed through these calls. They are skipped or recorded as failed, with the reason in the log. A role that maps a user to one of them leaves the user outside that group.
* The permission check reads the app roles from the access token by making one small request and reading the token back from it. That has not been confirmed against a live tenant. If it fails, Airlock falls back to the context scopes and then to a warning, so it never blocks a login by itself.
* The Graph SDK command for removing a group member may have a different name in some SDK releases, see `docs/permissions.md`.
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

**Do not run onboarding with `-Debug` or `-Verbose`, or with debug output turned on in the Graph SDK, unless you will throw the output away.** Those switches can print request bodies, and the request that creates a user contains its temporary password. The password is kept out of the change log and out of Airlock's own messages, but it cannot be kept out of output that the SDK itself prints.

Use a test tenant. The examples use the reserved `contoso.example` domain and fictional names. Never commit `.env`, certificates, real role maps, or real user lists. The `.gitignore` excludes them.
