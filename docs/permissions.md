# Permissions

Airlock signs in as an application, with no user present. That means every permission below is a Microsoft Graph **application permission** that must be added to the app registration and given admin consent. Nothing is requested at sign-in. The permissions on the registration are what the token carries.

`Connect-Airlock -Command <name>` reads the roles from the access token and stops before any change is made if a required one is missing. The Graph SDK does not hand over the token, so Airlock makes one small request (`GET /users?$top=1&$select=id`) and reads the token back from the request, then decodes its `roles` claim. The scopes on the Graph context are only a fallback, because for an app-only session they are often empty. If neither can be read, Airlock warns that the permissions were not checked and carries on, so a missing permission then shows up as an error on the first call that needs it. The token is never logged or stored.

The lists in this document are the same lists the code uses, held in `Get-AirlockRequiredPermission` and `Get-AirlockOptionalPermission` in `src/Private/`. If you change one, change the other.

A permission marked optional never stops `Connect-Airlock`. If it is missing you get one warning, and the command skips the feature that needs it.

The Graph documentation was checked on 2026-10-20, and again on 2026-10-21 for the three optional offboarding permissions. Items that are marked **verify** could not be confirmed from documentation alone and should be checked in a test tenant before relying on them. They are collected at the end.

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
| `RoleManagement.ReadWrite.Directory` | no | optional, higher privilege (verify) | no | no | no |
| `Group.ReadWrite.All` | no | optional, higher privilege (verify) | no | no | no |
| `Files.ReadWrite.All` | no | optional, higher privilege (verify) | no | no | no |
| `DeviceManagementManagedDevices.Read.All` | no | no | no | yes (verify) | yes (verify) |

The reporting commands only read. They never write to the tenant, so a report-only registration can hold read permissions and nothing else.

Grant only the column for the commands you will run. The two commands need different sets, so the safest setup is two app registrations, one for onboarding and one for offboarding, each with its own certificate. Then a problem with one credential cannot be used for the other job.

The three optional offboarding permissions are the highest privilege Airlock uses. `RoleManagement.ReadWrite.Directory` lets the app change who holds directory roles, `Group.ReadWrite.All` lets it change who owns groups, and `Files.ReadWrite.All` is write access to files across the tenant. Keep them on the offboarding registration only, never on the onboarding one, and grant each only if you want the step it enables. Without them offboarding still blocks sign-in, revokes sessions, and removes licenses and group memberships.

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

### Optional steps, higher privilege

Three offboarding steps need permissions that are higher privilege than anything else Airlock uses, so they are optional on purpose. A registration without them keeps working. Each missing permission is recorded as `Skipped` for every user, with the permission named in the change log, and `Connect-Airlock` warns once. `-SkipStep` turns any of the three off for one run even when the permission is granted. Granting one is a decision to let this registration do more than disable and strip an account.

| Permission | What it adds | Graph calls (SDK command) |
| --- | --- | --- |
| `RoleManagement.ReadWrite.Directory` | Removes the user's active directory roles. This is the only application permission Microsoft lists for deleting a role assignment | `GET /roleManagement/directory/roleAssignments?$filter=principalId eq '{id}'` (`Get-MgRoleManagementDirectoryRoleAssignment`), `DELETE /roleManagement/directory/roleAssignments/{id}` (`Remove-MgRoleManagementDirectoryRoleAssignment`), and `GET /roleManagement/directory/roleDefinitions` for names in the log (`Get-MgRoleManagementDirectoryRoleDefinition`). The SDK commands are in `Microsoft.Graph.Identity.Governance` |
| `Group.ReadWrite.All` | Moves group ownership. It is the least privileged application permission for both adding and removing an owner | `GET /users/{id}/ownedObjects` (`Get-MgUserOwnedObjectAsGroup`, **verify**), `GET /groups/{id}/owners` (`Get-MgGroupOwner`), `POST /groups/{id}/owners/$ref` (`New-MgGroupOwnerByRef`), `DELETE /groups/{id}/owners/{id}/$ref` (`Remove-MgGroupOwnerDirectoryObjectByRef`, or the older `Remove-MgGroupOwnerByRef`) |
| `Files.ReadWrite.All` | Gives the manager write access to the leaver's OneDrive. It is the least privileged application permission Microsoft lists for sharing a drive item, and it is write access to files across the tenant | `GET /users/{id}/drive` (`Get-MgUserDefaultDrive`), `GET /drives/{id}/items/root/permissions` (`Get-MgDriveItemPermission`), `POST /drives/{id}/items/root/invite` (`Invoke-MgInviteDriveItem`) |

The reads that these steps make are covered by permissions already held. Listing role assignments and group owners accepts `Directory.Read.All`, and `Files.ReadWrite.All` is a higher permission than `Files.Read.All` for the two OneDrive reads.

What each step does:

* **Directory roles.** The leaver's active role assignments are read when the step runs and each one is removed on its own, so `-WhatIf` lists exactly which roles would go and one failure does not stop the rest. Roles that are only eligible through Privileged Identity Management are not read or removed, and blocking sign-in already stops the account using them. Airlock has no guard for removing the last Global Administrator, so keep a break-glass account and run `-WhatIf` first.
* **Group ownership.** This is separate from membership. Where the leaver is one of several owners they are removed as an owner and nobody new is given ownership. Where they are the only owner, the manager is added as owner first and the leaver is removed after. With no manager, or with `-OwnershipAction Remove`, a sole owner is left in place and the reason is logged. Microsoft documents that the last owner of a group cannot be removed, and a group with no owner is worse than a disabled owner. Dynamic groups are handled like any other, because dynamic membership does not affect owners. Groups synced from on-premises, and mail-enabled groups that are not Microsoft 365 groups, are skipped with the reason. Only groups are covered, not applications or service principals.
* **OneDrive handover.** The manager is invited with the write role on the root folder of the leaver's drive, which the rest of the OneDrive inherits. This grants access. It does not transfer ownership and does not copy files, because Graph has no call that transfers ownership of a OneDrive. The invitation is granted directly with no email. Microsoft says permissions cannot be created on the root of a personal OneDrive, which is not a work or school drive. The step is skipped when there is no manager or no OneDrive, and nothing is shared if the current access cannot be read. It runs before licenses are removed.

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

No permission to read mail, calendars or chat, and none to delete users or reset passwords. By default Airlock does not change directory roles, group ownership or access to files. Those become possible only if you grant the three optional offboarding permissions above, and each one is limited to the step it enables. `Files.Read.All` is optional and is used only to ask whether a OneDrive exists, and the check is skipped if it is not granted.

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

10. **Group ownership: finding the groups the leaver owns.** Microsoft's page for `GET /users/{id}/ownedObjects` lists application permissions as "Not supported". Airlock uses that call (`Get-MgUserOwnedObjectAsGroup`) to find the groups. If it is refused app-only, the ownership step records one `Failed` entry per user and changes nothing, and the rest of offboarding still runs. If that happens there is no workaround built in. Confirm it first, because it decides whether the step is usable at all.
11. **Group ownership: `Group.ReadWrite.All` and the SDK command names.** Confirm `Group.ReadWrite.All` is enough for adding and removing owners and that `Directory.Read.All` is enough for `GET /groups/{id}/owners`. Confirm which of `Remove-MgGroupOwnerDirectoryObjectByRef` and `Remove-MgGroupOwnerByRef` exists in your pinned SDK version. Airlock uses the first one it finds, and records a failure that names both if neither exists.
12. **Group ownership: last owner.** Confirm that Graph refuses to remove the last owner of a group, as the documentation says. Airlock never asks it to, but this is the guard it relies on.
13. **Directory roles: delete works app-only.** Confirm that `RoleManagement.ReadWrite.Directory` is enough to delete a role assignment for the user types you offboard. Confirm what happens when the assignment is for the last Global Administrator, and for a user who holds a role through a role-assignable group, which this step does not change. Confirm that `Directory.Read.All` is enough to list assignments and read role definitions.
14. **Directory roles: scope.** Confirm that an assignment scoped to an administrative unit is listed by the principal filter and removed by the same call.
15. **OneDrive handover: root and inheritance.** Confirm that inviting a recipient on `root` works for a work or school OneDrive with application access, that the rest of the OneDrive inherits the permission, and that the manager can open it. Confirm that `Files.ReadWrite.All` is enough and that `Get-MgDriveItemPermission -DriveItemId root` is accepted by the SDK version you pin.
16. **OneDrive handover: recipient and idempotency.** Airlock identifies the manager by object id in the invitation. Confirm that Graph accepts that, that no notification is sent with `sendInvitation` set to false, and that a manager who has been given access appears in the permission list in a shape Airlock recognises (`grantedToV2`, `grantedTo`, or a list of identities). If it does not, a second run would invite again, which is harmless but noisy.
17. **OneDrive handover: unlicensed or disabled users.** Confirm that the drive of a user who is blocked and still licensed can be looked up and shared at the point the step runs.

### Resolved

* `Directory.Read.All` is enough to read license names from `Get-MgSubscribedSku` during offboarding. The Microsoft Learn page for listing subscribed SKUs lists `Directory.Read.All` for application access, so `LicenseAssignment.Read.All` is not needed for offboarding.

Run every command with `-WhatIf` first. The preview still reads from the tenant, so it exercises the read permissions without changing anything.

## Setting up the registration

1. In Microsoft Entra admin center, create an app registration in the test tenant.
2. Add a certificate (preferred) or a client secret. Put the thumbprint or the secret in `.env`, never in the repository.
3. Under API permissions, add the Microsoft Graph application permissions listed for the commands you will run.
4. Select Grant admin consent.
5. Run `Connect-Airlock -Command <name>`. If a permission is missing the error lists exactly which ones.
