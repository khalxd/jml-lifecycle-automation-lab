Connect-MgGraph -Scopes "User.ReadWrite.All","Group.ReadWrite.All","RoleManagement.ReadWrite.Directory"

$csvPath = ".\HR_Roster_Batch2.csv"
$records = @(Import-Csv -Path $csvPath)
$auditLogPath = ".\JML_AuditLog.csv"

Write-Host "Loaded $($records.Count) records from HR roster."

function Write-AuditLog {
    param($Event, $User, $Department, $Manager, $Action)
    [PSCustomObject]@{
        Timestamp  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Event      = $Event
        User       = $User
        Department = $Department
        Manager    = $Manager
        Action     = $Action
    } | Export-Csv -Path $auditLogPath -Append -NoTypeInformation
}

foreach ($record in $records) {

    $nameParts = $record.Name -split " ", 2
    $firstName = $nameParts[0]
    $lastName = if ($nameParts.Count -gt 1) { $nameParts[1] } else { "" }
    $mailNickname = ($firstName + $lastName) -replace '[^a-zA-Z0-9]', ''
    $upn = "$mailNickname@ahmedcyberlab.onmicrosoft.com"

    switch ($record.Status) {

        "New" {
            $existingUser = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue

            if ($existingUser) {
                Write-Host "Skipped (already exists): $($record.Name)"
                $userId = $existingUser.Id
            }
            else {
                $passwordProfile = @{
                    Password = "TempPass!2026"
                    ForceChangePasswordNextSignIn = $true
                }
                $userParams = @{
                    DisplayName       = $record.Name
                    UserPrincipalName = $upn
                    MailNickname      = $mailNickname
                    AccountEnabled    = $true
                    PasswordProfile   = $passwordProfile
                    GivenName         = $firstName
                    JobTitle          = $record.JobTitle
                    Department        = $record.Department
                }
                if ($lastName -ne "") { $userParams["Surname"] = $lastName }

                $newUser = New-MgUser @userParams
                $userId = $newUser.Id
                Write-Host "Joiner: Created $($record.Name) | UPN: $upn"
            }

            $group = Get-MgGroup -Filter "displayName eq '$($record.Department)'"
            $alreadyMember = Get-MgGroupMember -GroupId $group.Id -All | Where-Object { $_.Id -eq $userId }
            if (-not $alreadyMember) {
                New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $userId
                Write-Host "  -> Added to group: $($record.Department)"
            }

            Write-AuditLog -Event "Joiner" -User $record.Name -Department $record.Department -Manager $record.ManagerName -Action "Provisioned via HR reconciliation"
        }

        "Transfer" {
            $existingUser = Get-MgUser -Filter "userPrincipalName eq '$upn'" -Property "Id,Department" -ErrorAction SilentlyContinue

            if (-not $existingUser) {
                Write-Host "Mover FAILED (user not found): $($record.Name)"
                continue
            }

            $oldDepartment = $existingUser.Department
            $newDepartment = $record.Department

            if ($oldDepartment -eq $newDepartment) {
                Write-Host "Mover: $($record.Name) already in $newDepartment, no change"
                continue
            }

            $oldGroup = Get-MgGroup -Filter "displayName eq '$oldDepartment'"
            $newGroup = Get-MgGroup -Filter "displayName eq '$newDepartment'"

            Remove-MgGroupMemberByRef -GroupId $oldGroup.Id -DirectoryObjectId $existingUser.Id
            New-MgGroupMember -GroupId $newGroup.Id -DirectoryObjectId $existingUser.Id

            Update-MgUser -UserId $existingUser.Id -Department $newDepartment -JobTitle $record.JobTitle

            Write-Host "Mover: $($record.Name) moved $oldDepartment -> $newDepartment"

            Write-AuditLog -Event "Mover" -User $record.Name -Department $newDepartment -Manager $record.ManagerName -Action "Transferred from $oldDepartment to $newDepartment"
        }

        "Terminated" {
            $existingUser = Get-MgUser -Filter "userPrincipalName eq '$upn'" -Property "Id,DisplayName" -ErrorAction SilentlyContinue

            if (-not $existingUser) {
                Write-Host "Leaver FAILED (user not found): $($record.Name)"
                continue
            }

            Update-MgUser -UserId $existingUser.Id -AccountEnabled:$false

            $randomPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object {[char]$_})
            Update-MgUser -UserId $existingUser.Id -PasswordProfile @{ Password = $randomPassword; ForceChangePasswordNextSignIn = $true }

            $memberships = Get-MgUserMemberOf -UserId $existingUser.Id -All
            foreach ($m in $memberships) {
                Remove-MgGroupMemberByRef -GroupId $m.Id -DirectoryObjectId $existingUser.Id -ErrorAction SilentlyContinue
            }

            $eligibleAssignments = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "principalId eq '$($existingUser.Id)'"
            foreach ($assignment in $eligibleAssignments) {
                $params = @{
                    Action = "adminRemove"
                    Justification = "Automated offboarding - JML reconciliation"
                    RoleDefinitionId = $assignment.RoleDefinitionId
                    DirectoryScopeId = $assignment.DirectoryScopeId
                    PrincipalId = $existingUser.Id
                }
                New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -BodyParameter $params | Out-Null
                Write-Host "  -> Revoked PIM eligible role: $($assignment.RoleDefinitionId)"
            }

            Update-MgUser -UserId $existingUser.Id -ShowInAddressList:$false

            Write-Host "Leaver: $($record.Name) disabled, password randomized, removed from $($memberships.Count) group(s), hidden from GAL"

            Write-AuditLog -Event "Leaver" -User $record.Name -Department $record.Department -Manager $record.ManagerName -Action "Offboarded - disabled, password reset, groups removed, PIM revoked"
        }

        default {
            Write-Host "Unhandled status '$($record.Status)' for $($record.Name) -- skipping"
        }
    }
}
