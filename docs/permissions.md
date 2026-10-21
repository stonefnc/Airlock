# Permissions

Airlock signs in as an application, with no user present. That means every permission below is a Microsoft Graph **application permission** that must be added to the app registration and given admin consent. Nothing is requested at sign-in. The permissions on the registration are what the token carries.

`Connect-Airlock -Command <name>` reads the roles from the access token and stops before any change is made if a required one is missing. The Graph SDK does not hand over the token, so Airlock makes one small request (`GET /users?$top=1&$select=id`) and reads the token back from the request, then decodes its `roles` claim. The scopes on the Graph context are only a fallback, because for an app-only session they are often empty. If neither can be read, Airlock warns that the permissions were not checked and carries on, so a missing permission then shows up as an error on the first call that needs it. The token is never logged or stored.

The lists in this document are the same lists the code uses, held in `Get-AirlockRequiredPermission` and `Get-AirlockOptionalPermission` in `src/Private/`. If you change one, change the other.

A permission marked optional never stops `Connect-Airlock`. If it is missing you get one warning, and the command skips the feature that needs it.

The Graph documentation was checked on 2026-10-20. Items that are marked **verify** could not be confirmed from documentation alone and should be checked in a test tenant before relying on them. They are collected at the end.

## Summary

| Permission | `New-AirlockUser` | `Remove-AirlockUser` | `Get-AirlockLicenseUsage` | `Get-AirlockComplianceReport` | `Get-AirlockStaleDevice` |
| --- | :---: | :---: | :---: | :---: | :---: |
| `User.ReadWrite.All` | yes | yes | no | no | no |
| `Group.Read.All` | yes | no | no | no | no |
| `GroupMember.ReadWrite.All` | yes | yes | no | no | no |
| `LicenseAssignment.Read.All` | yes | no | yes (verify) | no | no |
| `LicenseAssignment.ReadWrite.All` | yes | yes | no | no | no |
| `Files.Read.All` | optional (verify) | no | no | no | no |
| `User.RevokeSessions.All` | no | yes | no | no | no |
| `Directory.Read.All` | no | yes | no | no | no |
| `DeviceManagementManagedDevices.Read.All` | no | no | no | yes (verify) | yes (verify) |

The reporting commands only read. They never write to the tenant, so a report-only registration can hold read permissions and nothing else.

Grant only the column for the commands you will run. The two commands need different sets, so the safest setup is two app registrations, one for onboarding and one for offboarding, each with its own certificate. Then a problem with one credential cannot be used for the other job.

## New-AirlockUser

| Permission | Why it is needed | Graph calls (SDK command) |
| --- | --- | --- |
| `User.ReadWrite.All` | Find the user and the manager, create the user, set the usage location on an existing user, set the manager | `GET /users` (`Get-MgUser`), `POST /users` (`New-MgUser`), `PATCH /users/{id}` (`Update-MgUser`), `GET /users/{id}/manager` (`Get-MgUserManager`), `PUT /users/{id}/manager/$ref` (`Set-MgUserManagerByRef`) |
| `Group.Read.All` | Resolve each group display name in the role map to a group, and read its type so dynamic groups are skipped | `GET /groups` (`Get-MgGroup`) |
| `GroupMember.ReadWrite.All` | Add the user to each group in the role | `POST /groups/{id}/members/$ref` (`New-MgGroupMemberByRef`) |
| `LicenseAssignment.Read.All` | Read the tenant's license SKUs and how many units are free, so a CSV cannot run past the licenses available | `GET /subscribedSkus` (`Get-MgSubscribedSku`) |
| `LicenseAssignment.ReadWrite.All` | Assign the license in the role | `POST /users/{id}/assignLicense` (`Set-MgUserLicense`) |

Optional, not needed to onboard:

| Permission | What it adds | Graph calls (SDK command) |
| --- | --- | --- |
| `Files.Read.All` | The OneDrive check. Without it the check is skipped and reported as `NotChecked`. **Verify** that it works app-only, see below | `GET /users/{id}/drive` (`Get-MgUserDefaultDrive`) |

Also used, and covered by the permissions above: reading the members of each group so an existing user is not added twice (`Get-MgGroupMember`). **Verify** that `Group.Read.All` is enough for this in your tenant, because the group member listing page was not checked.

### Choices made on purpose

* `User.ReadWrite.All` is requested rather than the narrower `User.Create`. `User.Create` only allows creating users, and Airlock also reads users and updates the manager and usage location on existing ones.
* Existing group membership is checked with `Get-MgGroupMember`, group by group, so onboarding does not need `Directory.Read.All`. The cost is that a very large group (tens of thousands of members) makes the check slow for an existing user. New users are never checked, because a new user cannot be a member yet.
* Groups that can be assigned to Entra roles need an extra permission (`RoleManagement.ReadWrite.Directory`) to change membership. Airlock does not ask for it. A role that lists such a group will record a `Failed` entry for that group and carry on with the rest.

## Remove-AirlockUser

| Permission | Why it is needed | Graph calls (SDK command) |
| --- | --- | --- |
| `User.ReadWrite.All` | Find the user, block sign-in, read the manager | `GET /users` (`Get-MgUser`), `PATCH /users/{id}` with `accountEnabled` false (`Update-MgUser`), `GET /users/{id}/manager` (`Get-MgUserManager`) |
| `User.RevokeSessions.All` | Invalidate refresh tokens and session cookies. This is the least privileged permission Graph offers for the call | `POST /users/{id}/revokeSignInSessions` (`Revoke-MgUserSignInSession`) |
| `Directory.Read.All` | List the groups the user belongs to. See the note below | `GET /users/{id}/memberOf/microsoft.graph.group` (`Get-MgUserMemberOfAsGroup`) |
| `GroupMember.ReadWrite.All` | Remove the user from each group. **Verify** against the delete members page, which was not checked | `DELETE /groups/{id}/members/{id}/$ref` (`Remove-MgGroupMemberByRef`) |
| `LicenseAssignment.ReadWrite.All` | Remove directly assigned licenses | `POST /users/{id}/assignLicense` (`Set-MgUserLicense`) |

Also used, and covered by the permissions above: reading license names for the log (`Get-MgSubscribedSku`). The Microsoft Learn page for listing subscribed SKUs lists `Directory.Read.All` as sufficient for application access, so offboarding does not need `LicenseAssignment.Read.All`. Reading the names is best effort. If it fails, the log shows the license id instead.

Group memberships are removed with `Remove-MgGroupMemberByRef`. A review of the Microsoft Learn page for removing a group member reports that the SDK command shown there is `Remove-MgGroupMemberDirectoryObjectByRef`, which is a different name. The author has not checked this, and the command can be renamed between SDK releases. Check that the command Airlock calls exists in the SDK version you pin, see the verify list.

### Directory.Read.All is the broadest permission in this set

For application access, listing another user's group memberships requires `Directory.Read.All`, according to the Graph documentation. There is no narrower application permission for that call. `Directory.Read.All` lets the app read most of the directory, so it is the main reason to keep offboarding on its own app registration with a certificate that is protected and rotated.

## Get-AirlockLicenseUsage

Read only. Reports total, assigned and available units for each license SKU.

| Permission | Why it is needed | Graph calls (SDK command) |
| --- | --- | --- |
| `LicenseAssignment.Read.All` | Read each SKU's purchased and consumed units. **Verify** that this is the least privileged application permission for the call. The Microsoft Learn page for listing subscribed SKUs also lists `Directory.Read.All`, which is broader | `GET /subscribedSkus` (`Get-MgSubscribedSku`) |

Total is the enabled prepaid units, Assigned is the consumed units, and Available is the difference.
## Get-AirlockComplianceReport

Read only. Reports Intune device compliance grouped by platform.

| Permission | Why it is needed | Graph calls (SDK command) |
| --- | --- | --- |
| `DeviceManagementManagedDevices.Read.All` | Read each managed device's operating system and compliance state. **Verify** that this is the least privileged application permission for the call | `GET /deviceManagement/managedDevices` (`Get-MgDeviceManagementManagedDevice`) |

The platform is the device's `operatingSystem` value, and a device with none is reported as `Unknown`. The compliance states counted are `compliant`, `noncompliant`, `inGracePeriod` and `unknown`. Any other state is counted as `Other`. The Graph PowerShell SDK command lives in the `Microsoft.Graph.DeviceManagement` module, so install it alongside the other Graph modules.
## Get-AirlockStaleDevice

Read only. Lists Intune managed devices whose last check-in is older than `-Days` days (default 30).

| Permission | Why it is needed | Graph calls (SDK command) |
| --- | --- | --- |
| `DeviceManagementManagedDevices.Read.All` | Read each managed device's last sync time, operating system and primary user. **Verify** that this is the least privileged application permission for the call | `GET /deviceManagement/managedDevices` (`Get-MgDeviceManagementManagedDevice`) |

A device is stale when `lastSyncDateTime` is more than `-Days` days in the past. A device whose last sync is exactly that old is not listed. A device that has never synced is always listed, with an empty last sync and days value. Owner is the device's `userPrincipalName` and is empty when Intune has no primary user. Intune can report a user other than the person who uses the device day to day, so treat Owner as a lead and not a fact. The call is the same one `Get-AirlockComplianceReport` makes.
## What Airlock does not ask for

No permission to read mail, files, calendars or chat. No permission to delete users, reset passwords, or change directory roles. `Files.Read.All` is the only permission that reads file data, and it is optional: it is used only to ask whether a OneDrive exists, and the check is skipped if it is not granted.

## OneDrive check is optional and best effort

Microsoft's page for `GET /users/{id}/drive` currently lists application permissions as "Not supported", although `Files.Read.All` is widely reported to work for app-only access. Because of that, a tenant must be able to onboard users without it, and Airlock never lets this check block onboarding:

* If `Files.Read.All` is not granted, `Connect-Airlock` warns once and `New-AirlockUser` skips the check. The result shows `OneDrive` as `NotChecked`, and the change log says why.
* If it is granted but the call is refused, the result shows `OneDrive` as `Unknown` with the reason in the change log, and the user is still created, grouped and licensed.
* A drive that does not exist yet is reported as `Pending`, which is normal just after a license is assigned. Note that app-only calls cannot trigger provisioning, so a drive for a newly licensed user may take a while to appear.
* If `Connect-Airlock` could not read the permissions at all, the check is attempted and reports `Unknown` if it fails.

## Verify in a test tenant

The unit tests mock every Graph call, so they cannot tell you any of the following. Check them once, in a test tenant, before using Airlock on a real one.

1. `Files.Read.All` works for `GET /users/{id}/drive` with app-only access. The permission is optional, so this only decides whether the OneDrive check is worth turning on.
2. `Group.Read.All` is enough to list group members for the existing-membership check.
3. `GroupMember.ReadWrite.All` is enough to remove a member from a group.
4. The app can block sign-in on users who hold an administrator role. Microsoft restricts what an app can change on privileged accounts, and the app may need a directory role such as User Administrator as well. Airlock records the failure and carries on if it cannot.
5. The Graph PowerShell SDK command and parameter names match what the code calls: `-BodyParameter` on the write commands, `Get-MgUserDefaultDrive`, `Get-MgUserMemberOfAsGroup`, `Remove-MgGroupMemberByRef -DirectoryObjectId` (see the note above about a possible different name), `Revoke-MgUserSignInSession`. The tests replace these commands with stand-ins, so a renamed command or parameter would only show up against a live tenant. Do this against the exact SDK version you intend to pin.
6. Reading the token back works. Airlock calls `Invoke-MgGraphRequest -OutputType HttpResponseMessage` and reads `RequestMessage.Headers.Authorization.Parameter`, and expects a token whose `roles` claim lists the granted application permissions. This is a widely used technique, but it has not been confirmed against SDK version 2 here. If it fails, Airlock falls back to the context scopes and then to a warning, so it cannot block a sign-in by itself, but the permission check would not be doing its job.
7. A fresh user becomes visible to the manager, group and license calls within the retry window (2, 4, 8 and 16 seconds). If your tenant is slower, widen the pauses in `Invoke-AirlockStep`.

8. `LicenseAssignment.Read.All` is enough for `GET /subscribedSkus` with app-only access, as `Get-AirlockLicenseUsage` needs. The cmdlet has not been run against a live tenant, and its tests mock Graph.

9. `DeviceManagementManagedDevices.Read.All` is enough for `GET /deviceManagement/managedDevices` with app-only access, and `Get-MgDeviceManagementManagedDevice -All` and the property names `OperatingSystem`, `ComplianceState`, `UserPrincipalName` and `LastSyncDateTime` match the SDK version you pin. `Get-AirlockComplianceReport` and `Get-AirlockStaleDevice` have not been run against a live tenant, and their tests mock Graph. Also confirm that Intune returns the minimum date for a device that never synced, which the stale report reads as never checked in.

### Resolved

* `Directory.Read.All` is enough to read license names from `Get-MgSubscribedSku` during offboarding. The Microsoft Learn page for listing subscribed SKUs lists `Directory.Read.All` for application access, so `LicenseAssignment.Read.All` is not needed for offboarding.

Run every command with `-WhatIf` first. The preview still reads from the tenant, so it exercises the read permissions without changing anything.

## Setting up the registration

1. In Microsoft Entra admin center, create an app registration in the test tenant.
2. Add a certificate (preferred) or a client secret. Put the thumbprint or the secret in `.env`, never in the repository.
3. Under API permissions, add the Microsoft Graph application permissions listed for the commands you will run.
4. Select Grant admin consent.
5. Run `Connect-Airlock -Command <name>`. If a permission is missing the error lists exactly which ones.
