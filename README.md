# JML (Joiner-Mover-Leaver) Lifecycle Automation Lab

**Tools:** PowerShell, Microsoft Entra ID, Microsoft Graph API, Privileged Identity Management (PIM)

## Overview

This lab simulates an enterprise identity lifecycle automation pipeline driven by an HR system of truth. Rather than manually provisioning, transferring, or offboarding accounts one at a time, a single PowerShell reconciliation script reads an HR export (CSV) and automatically applies the correct identity action based on each record's status — mirroring how real-world IGA platforms (SailPoint, Okta Workflows, etc.) operate under the hood.

The lab environment simulates a fictional company ("KhaledTech") with 6 departments — Engineering, Sales, Marketing, Finance, HR, and IT — and processes HR batches covering the full identity lifecycle: onboarding, department transfers, and offboarding with privileged access revocation.

## Architecture

- **Source of truth:** `HR_Roster_Batch*.csv` — simulates an HR system export with `Name`, `Department`, `Status`, `ManagerName`, `JobTitle` columns
- **Reconciliation engine:** A single PowerShell script reads the CSV and branches into Joiner / Mover / Leaver logic using a `switch` statement on the `Status` field per record
- **Identity platform:** Microsoft Entra ID (Microsoft Graph PowerShell SDK)
- **Access control:** Department-based security groups (Assigned type), enforced via RBAC
- **Privileged access:** PIM-eligible role assignments, automatically revoked on offboarding
- **Idempotency:** Every branch checks current state before acting — existing users are skipped rather than recreated, existing group memberships aren't duplicated, and re-running the script against already-processed records is safe
- **Audit trail:** Every lifecycle event (Joiner, Mover, Leaver) is logged with a timestamp to `JML_AuditLog.csv`

```
PS C:\JML-lab> Get-Content .\JML_AuditLog.csv -Head 10
"Timestamp","Event","User","Department","Manager","Action"
"2026-09-18 01:31:17","Joiner","Timothee Chalamet","Engineering","Leonardo DiCaprio","Provisioned via HR reconciliation"
"2026-09-18 01:31:18","Joiner","Zoe Saldana","Engineering","Leonardo DiCaprio","Provisioned via HR reconciliation"
"2026-09-18 01:31:18","Joiner","Idris Elba","Engineering","Leonardo DiCaprio","Provisioned via HR reconciliation"
"2026-09-18 01:31:18","Joiner","Florence Pugh","Engineering","Leonardo DiCaprio","Provisioned via HR reconciliation"
"2026-09-18 01:31:19","Joiner","Daniel Kaluuya","Sales","Scarlett Johansson","Provisioned via HR reconciliation"
"2026-09-18 01:31:19","Joiner","Anya Taylor-Joy","Sales","Scarlett Johansson","Provisioned via HR reconciliation"
```

![Connect to Graph and CSV import](screenshots/01-connect-and-import.png)

## Results

| Event Type | Count |
|---|---|
| Joiner | 26 |
| Mover | 4 |
| Leaver | 3 |
| PIM roles revoked | 1 |
| Total records processed | 33 |

## Section 1: Joiner

New identities provisioned in a single automated pass. For each record:

- Account created in Entra ID with department and job title attributes set
- Manager attribute linked to the correct department manager (a real user object, not just a text field)
- Added to the department-specific security group
- Event logged with timestamp
- Existing accounts are detected and skipped rather than recreated, so the script is safe to re-run

**Sample script logic:**

```powershell
$newUser = New-MgUser -DisplayName $record.Name -UserPrincipalName $upn `
    -MailNickname $mailNickname -AccountEnabled -PasswordProfile $passwordProfile `
    -GivenName $firstName -Surname $lastName -JobTitle $record.JobTitle -Department $record.Department

$group = Get-MgGroup -Filter "displayName eq '$($record.Department)'"
New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $newUser.Id
```

A dry-run mode was built and tested first, printing what the script *would* do before any real changes were made:

![Dry run output](screenshots/02-dry-run.png)

Real-world edge cases were handled along the way — a missing surname on a single-name record, and safe re-run behavior for already-existing users:

![Surname fix and skip logic](screenshots/03-surname-fix-and-skip-logic.png)

Verified in the portal after running against the full batch:

![Users created in portal](screenshots/04-users-created-portal.png)
![Group assignment](screenshots/05-group-assignment.png)
![Group membership verified in portal](screenshots/06-group-membership-portal.png)

## Section 2: Mover

Identities transferred between departments, simulating promotions/role changes. For each transfer:

- Removed from old department's security group
- Added to new department's security group
- Department attribute updated
- Job title updated where applicable
- Change reflects in real time, verified against the portal (both group memberships checked pre/post)

**Sample script logic:**

```powershell
Remove-MgGroupMemberByRef -GroupId $oldGroup.Id -DirectoryObjectId $existingUser.Id
New-MgGroupMember -GroupId $newGroup.Id -DirectoryObjectId $existingUser.Id
Update-MgUser -UserId $existingUser.Id -Department $newDepartment -JobTitle $record.JobTitle
```

![Mover logic output](screenshots/07-mover-logic.png)

Verified both sides of the transfer in the portal — added to the new department's group, and removed from the old one:

![Mover verified in new group](screenshots/08-mover-verified-portal.png)
![Mover verified removed from old group](screenshots/08b-mover-verified-portal.png)

## Section 3: Leaver

Identities offboarded using a 5-step deprovisioning sequence:

1. Disable account
2. Randomize password
3. Remove all group memberships
4. Revoke active PIM eligible role assignments
5. Hide from Global Address List

**Sample script logic:**

```powershell
Update-MgUser -UserId $existingUser.Id -AccountEnabled:$false

$memberships = Get-MgUserMemberOf -UserId $existingUser.Id -All
foreach ($m in $memberships) {
    Remove-MgGroupMemberByRef -GroupId $m.Id -DirectoryObjectId $existingUser.Id
}

$eligibleAssignments = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "principalId eq '$($existingUser.Id)'"
foreach ($assignment in $eligibleAssignments) {
    New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -BodyParameter @{
        Action = "adminRemove"
        Justification = "Automated offboarding - JML reconciliation"
        RoleDefinitionId = $assignment.RoleDefinitionId
        DirectoryScopeId = $assignment.DirectoryScopeId
        PrincipalId = $existingUser.Id
    }
}

Update-MgUser -UserId $existingUser.Id -ShowInAddressList:$false
```

![Leaver logic output](screenshots/09-leaver-logic.png)

Verified in the portal — account disabled, zero group memberships, zero assigned roles:

![Leaver verified in portal](screenshots/10-leaver-verified-portal.png)

## Access Governance

Every lifecycle event — provisioning, transfer, and offboarding — is written to `JML_AuditLog.csv` with a timestamp, the acting event type, and the affected user, department, and manager. This provides a compliance-ready record of every identity change the script made, independent of console output.

![Audit log contents](screenshots/14-audit-log.png)

Privileged access is governed through PIM eligible role assignments rather than standing access, and the Leaver branch automatically revokes any eligible role assignments on offboarding — closing a gap that manual deprovisioning processes commonly miss.

**Before:** a test user assigned an eligible PIM role.

![PIM eligible assignment before offboarding](screenshots/11-pim-assignment-before.png)

**During:** the Leaver branch programmatically revoking it.

![PIM revocation in script output](screenshots/12-pim-revocation.png)
![PIM revocation re-run, confirming idempotency](screenshots/12b-pim-revocation-rerun-idempotent.png)

**After:** the eligible assignment is gone from PIM.

![PIM eligible assignment revoked, verified in portal](screenshots/13-pim-revoked-portal.png)

## Key Takeaways

- Built a reconciliation pattern (HR source of truth to automated identity actions) rather than three disconnected manual scripts
- Demonstrated full JML lifecycle: provisioning, mid-lifecycle department/attribute changes, and secure offboarding with privileged access revocation
- Designed for idempotency, safe to re-run against the same data without duplicating actions or erroring on already-processed records
- Full audit trail for compliance/audit-readiness, separate from console output
- Access governed by department-based RBAC security groups, verified against the Entra portal at each stage

## Lessons Learned

- **Stale authentication tokens block privileged operations differently than standard ones.** A `New-MgUser` or `Update-MgUser` call for basic attributes succeeded on an older session token, but resetting another user's password (a Microsoft-classified sensitive/privileged action) returned a 403 until the session was fully disconnected and reconnected with a fresh token.
- **`Import-Csv` on a single-row CSV returns a scalar object, not an array** — breaking `.Count` and any code that assumes array behavior. Wrapping the import in `@(...)` forces consistent array behavior regardless of row count.
- **Not every HR record has a last name.** A single-name record (e.g. a mononymous user) will break a `-Surname` parameter if passed an empty string, handled by conditionally including the parameter only when a last name is present.
- **Idempotency has to be designed in, not bolted on.** Early versions of the script errored when re-run against already-processed records; the fix was checking current state (does this user exist? are they already in this group? is their department already correct?) before taking any action, rather than assuming every run starts from zero.


[LinkedIn](#)
