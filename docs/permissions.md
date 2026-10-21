# Permissions

Airlock signs in as an application, with no user present. That means every permission below is a Microsoft Graph **application permission** that must be added to the app registration and given admin consent. Nothing is requested at sign-in. The permissions on the registration are what the token carries.

`Connect-Airlock -Command <name>` reads the roles from the token and stops before any change is made if one that command needs is missing. The list in this document is the same list the code uses, held in `Get-AirlockRequiredPermission` in `src/Private/`. If you change one, change the other.

The Graph documentation was checked on 2026-10-20. Items that are marked **verify** could not be confirmed from documentation alone and should be checked in a test tenant before relying on them. They are collected at the end.

## Summary

| Permission | `New-AirlockUser` | `Remove-AirlockUser` |
| --- | :---: | :---: |
| `User.ReadWrite.All` | yes | yes |
| `Group.Read.All` | yes | no |
| `GroupMember.ReadWrite.All` | yes | yes |
| `LicenseAssignment.Read.All` | yes | no |
| `LicenseAssignment.ReadWrite.All` | yes | yes |
| `Files.Read.All` | yes (verify) | no |
| `User.RevokeSessions.All` | no | yes |
| `Directory.Read.All` | no | yes |

Grant only the column for the commands you will run. The two commands need different sets, so the safest setup is two app registrations, one for onboarding and one for offboarding, each with its own certificate. Then a problem with one credential cannot be used for the other job.

## New-AirlockUser

| Permission | Why it is needed | Graph calls (SDK command) |
| --- | --- | --- |
| `User.ReadWrite.All` | Find the user and the manager, create the user, set the usage location on an existing user, set the manager | `GET /users` (`Get-MgUser`), `POST /users` (`New-MgUser`), `PATCH /users/{id}` (`Update-MgUser`), `GET /users/{id}/manager` (`Get-MgUserManager`), `PUT /users/{id}/manager/$ref` (`Set-MgUserManagerByRef`) |
| `Group.Read.All` | Resolve each group display name in the role map to a group, and read its type so dynamic groups are skipped | `GET /groups` (`Get-MgGroup`) |
| `GroupMember.ReadWrite.All` | Add the user to each group in the role | `POST /groups/{id}/members/$ref` (`New-MgGroupMemberByRef`) |
| `LicenseAssignment.Read.All` | Read the tenant's license SKUs and how many units are free, so a CSV cannot run past the licenses available | `GET /subscribedSkus` (`Get-MgSubscribedSku`) |
| `LicenseAssignment.ReadWrite.All` | Assign the license in the role | `POST /users/{id}/assignLicense` (`Set-MgUserLicense`) |
| `Files.Read.All` | Check whether the user's OneDrive exists yet. **Verify.** The check is best effort, see below | `GET /users/{id}/drive` (`Get-MgUserDefaultDrive`) |

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

Also used, and covered by the permissions above: reading license names for the log (`Get-MgSubscribedSku`), which `Directory.Read.All` allows. This is best effort. If it fails, the log shows the license id instead.

### Directory.Read.All is the broadest permission in this set

For application access, listing another user's group memberships requires `Directory.Read.All`, according to the Graph documentation. There is no narrower application permission for that call. `Directory.Read.All` lets the app read most of the directory, so it is the main reason to keep offboarding on its own app registration with a certificate that is protected and rotated.

## What Airlock does not ask for

No permission to read mail, files, calendars or chat. No permission to delete users, reset passwords, or change directory roles. `Files.Read.All` is requested only for the OneDrive check and can be left off if you accept that the check will report `Unknown`.

## OneDrive check is best effort

Microsoft's page for `GET /users/{id}/drive` currently lists application permissions as "Not supported", although `Files.Read.All` is widely reported to work for app-only access. Airlock therefore never lets this check block onboarding. If the call is refused, the result shows `OneDrive` as `Unknown` with the reason in the change log, and the user is still created, grouped and licensed. A drive that does not exist yet is reported as `Pending`, which is normal just after a license is assigned.

`Connect-Airlock -Command New-AirlockUser` still requires `Files.Read.All` to be on the registration. If you decide not to grant it, remove it from `Get-AirlockRequiredPermission` and from this document together.

## Verify in a test tenant

The unit tests mock every Graph call, so they cannot tell you any of the following. Check them once, in a test tenant, before using Airlock on a real one.

1. `Files.Read.All` works for `GET /users/{id}/drive` with app-only access.
2. `Group.Read.All` is enough to list group members for the existing-membership check.
3. `GroupMember.ReadWrite.All` is enough to remove a member from a group.
4. `Directory.Read.All` is enough to read license names from `Get-MgSubscribedSku` during offboarding.
5. The app can block sign-in on users who hold an administrator role. Microsoft restricts what an app can change on privileged accounts, and the app may need a directory role such as User Administrator as well. Airlock records the failure and carries on if it cannot.
6. The Graph PowerShell SDK command and parameter names match what the code calls: `-BodyParameter` on the write commands, `Get-MgUserDefaultDrive`, `Get-MgUserMemberOfAsGroup`, `Remove-MgGroupMemberByRef -DirectoryObjectId`, `Revoke-MgUserSignInSession`. The tests replace these commands with stand-ins, so a renamed parameter would only show up against a live tenant.
7. The roles in the access token are returned in `Get-MgContext` `Scopes` for both certificate and secret sign-in, which is what `Connect-Airlock` relies on.

Run every command with `-WhatIf` first. The preview still reads from the tenant, so it exercises the read permissions without changing anything.

## Setting up the registration

1. In Microsoft Entra admin center, create an app registration in the test tenant.
2. Add a certificate (preferred) or a client secret. Put the thumbprint or the secret in `.env`, never in the repository.
3. Under API permissions, add the Microsoft Graph application permissions listed for the commands you will run.
4. Select Grant admin consent.
5. Run `Connect-Airlock -Command <name>`. If a permission is missing the error lists exactly which ones.
