<#
.SYNOPSIS
  Saves, applies, and restores a reversible Windows clean-boot startup profile.

.AUTHOR
  AGilboa42

.VERSION
  1.0.0

.LINK
  Repository: https://github.com/AGilboa42/Manage-CleanBootStartup
  License: https://github.com/AGilboa42/Manage-CleanBootStartup/blob/main/LICENSE
  README: https://github.com/AGilboa42/Manage-CleanBootStartup/blob/main/README.md

.NOTES
  No support is provided. Use this script as-is and at your own risk.

.DESCRIPTION
  This script creates a JSON snapshot of startup-related settings, then can
  disable non-Microsoft services and common startup items for a clean boot.

  The snapshot includes:
    - Windows service startup modes
    - Registry Run startup entries for HKCU/HKLM, including Wow6432Node
    - Task Manager StartupApproved enabled/disabled state
    - Current-user and all-users Startup folder items
    - Logon/startup scheduled task enabled state

  CleanBoot mode:
    - Saves a snapshot first unless the target backup already exists
    - Disables non-Microsoft Win32 services
    - Removes saved Registry Run entries
    - Moves Startup-folder items into a sidecar folder
    - Disables non-Microsoft scheduled tasks with logon/startup triggers

  Restore mode restores from the JSON file and sidecar folder.

  Run CleanBoot and Restore from an elevated PowerShell session when applying
  real changes. Save, Status, and Restore -WhatIf can run without elevation,
  though an elevated Save may capture the most complete machine-wide data.

.EXAMPLE
  .\Manage-CleanBootStartup.ps1 -Action Save

.EXAMPLE
  .\Manage-CleanBootStartup.ps1 -Action CleanBoot

.EXAMPLE
  .\Manage-CleanBootStartup.ps1 -Action Restore -BackupPath .\StartupSettingsBackup-20260703-153000.json

.EXAMPLE
  .\Manage-CleanBootStartup.ps1 -Action Restore

  Prompts for a backup file from matching StartupSettingsBackup-*.json files.

.EXAMPLE
  .\Manage-CleanBootStartup.ps1 -Action Restore -BackupPath .\StartupSettingsBackup-20260703-153000.json -MissingItemAction Prompt
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Save', 'CleanBoot', 'Restore', 'Status')]
    [string]$Action = 'Status',

    [string]$BackupPath,

    [ValidateSet('Prompt', 'Skip', 'RestoreAnyway', 'Abort')]
    [string]$MissingItemAction = 'Prompt',

    [switch]$IncludeMicrosoftScheduledTasks
)

if (-not $PSBoundParameters.ContainsKey('WhatIf')) {
    $WhatIfPreference = $true
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Confirm-DestructiveExecution {
    param([string]$ActionName)

    if ($WhatIfPreference) {
        return
    }

    $response = Read-Host "This will make real changes while performing '$ActionName'. Type 'Yes' to continue"
    if ($response -ne 'Yes') {
        throw "Operation cancelled. Type 'Yes' to confirm the $ActionName action."
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    param([switch]$AllowWhatIf)

    if ($AllowWhatIf -and $WhatIfPreference) {
        Write-Host 'Running preview without elevation because -WhatIf was specified.'
        return
    }

    if (-not (Test-IsAdministrator)) {
        throw 'CleanBoot and Restore must be run from an elevated PowerShell session.'
    }
}

function Get-SidecarPath {
    param([string]$Path)

    return ('{0}.files' -f $Path)
}

function Get-BackupDirectory {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }

    return (Get-Location).Path
}

function New-DefaultBackupPath {
    return (Join-Path (Get-BackupDirectory) ("StartupSettingsBackup-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
}

function Select-StartupBackupPath {
    param([string]$Directory = (Get-BackupDirectory))

    $files = @(Get-ChildItem -LiteralPath $Directory -Filter 'StartupSettingsBackup-*.json' -File |
        Sort-Object LastWriteTime -Descending)

    if ($files.Count -eq 0) {
        throw "No backup files matching StartupSettingsBackup-*.json were found in $Directory. Run Save first or pass -BackupPath."
    }

    Write-Host "Select a startup backup from $Directory"
    for ($index = 0; $index -lt $files.Count; $index++) {
        $file = $files[$index]
        $sizeKb = [math]::Round($file.Length / 1KB, 1)
        Write-Host ("[{0}] {1}  {2}  {3} KB" -f ($index + 1), $file.Name, $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), $sizeKb)
    }

    do {
        $choice = Read-Host "Choose backup number 1-$($files.Count), or Q to abort"
        if ($choice.Trim().ToUpperInvariant() -eq 'Q') {
            throw 'Restore aborted by user.'
        }

        $selectedIndex = 0
        $isNumber = [int]::TryParse($choice, [ref]$selectedIndex)
    } while (-not $isNumber -or $selectedIndex -lt 1 -or $selectedIndex -gt $files.Count)

    return $files[$selectedIndex - 1].FullName
}

function ConvertTo-RegistryHiveInfo {
    param([string]$Path)

    if ($Path -like 'HKCU:\*') {
        return [pscustomobject]@{
            Hive    = [Microsoft.Win32.RegistryHive]::CurrentUser
            SubPath = $Path.Substring(6)
        }
    }

    if ($Path -like 'HKLM:\*') {
        return [pscustomobject]@{
            Hive    = [Microsoft.Win32.RegistryHive]::LocalMachine
            SubPath = $Path.Substring(6)
        }
    }

    throw "Unsupported registry path: $Path"
}

function Get-RegistryValueEntries {
    param([string]$Path)

    $info = ConvertTo-RegistryHiveInfo -Path $Path
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($info.Hive, [Microsoft.Win32.RegistryView]::Default)
    $key = $baseKey.OpenSubKey($info.SubPath, $false)
    if (-not $key) {
        return @()
    }

    try {
        foreach ($name in $key.GetValueNames()) {
            [pscustomobject]@{
                Path  = $Path
                Name  = $name
                Kind  = $key.GetValueKind($name).ToString()
                Value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        }
    }
    finally {
        $key.Close()
        $baseKey.Close()
    }
}

function Set-RegistryValueEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry
    )

    if (-not (Test-Path -LiteralPath $Entry.Path)) {
        New-Item -Path $Entry.Path -Force | Out-Null
    }

    $propertyType = switch ($Entry.Kind) {
        'String'       { 'String' }
        'ExpandString' { 'ExpandString' }
        'Binary'       { 'Binary' }
        'DWord'        { 'DWord' }
        'MultiString'  { 'MultiString' }
        'QWord'        { 'QWord' }
        default        { 'String' }
    }

    $value = switch ($Entry.Kind) {
        'Binary' {
            [byte[]]@($Entry.Value | ForEach-Object { [byte]$_ })
        }
        'DWord' {
            [int]$Entry.Value
        }
        'QWord' {
            [long]$Entry.Value
        }
        'MultiString' {
            [string[]]@($Entry.Value)
        }
        default {
            $Entry.Value
        }
    }

    if (Get-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -Force
    }

    New-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -Value $value -PropertyType $propertyType -Force | Out-Null
}

function Get-RunKeyPaths {
    @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'
    )
}

function Get-StartupApprovedKeyPaths {
    @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    )
}

function Get-StartupApprovedPathForRunEntry {
    param([object]$Entry)

    switch -Wildcard ($Entry.Path) {
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run*' {
            return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        }
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run*' {
            return 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
        }
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run*' {
            return 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        }
    }

    return $null
}

function Get-StartupApprovedPathForStartupFolderItem {
    param([object]$Item)

    if ($Item.Scope -eq 'CurrentUser') {
        return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    }

    if ($Item.Scope -eq 'AllUsers') {
        return 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    }

    return $null
}

function New-DisabledStartupApprovedEntry {
    param(
        [string]$Path,
        [string]$Name,
        [object]$ExistingEntry
    )

    $value = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    if ($ExistingEntry -and $ExistingEntry.Value) {
        $value = [byte[]]@($ExistingEntry.Value | ForEach-Object { [byte]$_ })
        if ($value.Length -gt 0) {
            $value[0] = 3
        }
    }

    [pscustomobject]@{
        Path  = $Path
        Name  = $Name
        Kind  = 'Binary'
        Value = $value
    }
}

function Get-StartupFolderPaths {
    $shell = New-Object -ComObject WScript.Shell

    @(
        [pscustomobject]@{
            Scope = 'CurrentUser'
            Path  = $shell.SpecialFolders.Item('Startup')
        }
        [pscustomobject]@{
            Scope = 'AllUsers'
            Path  = $shell.SpecialFolders.Item('AllUsersStartup')
        }
    ) | Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path -PathType Container) }
}

function Get-ServiceImagePath {
    param([string]$PathName)

    if ([string]::IsNullOrWhiteSpace($PathName)) {
        return $null
    }

    $trimmed = $PathName.Trim()
    if ($trimmed.StartsWith('"')) {
        $endQuote = $trimmed.IndexOf('"', 1)
        if ($endQuote -gt 1) {
            return [Environment]::ExpandEnvironmentVariables($trimmed.Substring(1, $endQuote - 1))
        }
    }

    $match = [regex]::Match($trimmed, '^(.+?\.exe)(?:\s|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return [Environment]::ExpandEnvironmentVariables($match.Groups[1].Value)
    }

    return [Environment]::ExpandEnvironmentVariables($trimmed.Split(' ')[0])
}

function Get-CommandTargetPath {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return $null
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ($expanded.StartsWith('"')) {
        $endQuote = $expanded.IndexOf('"', 1)
        if ($endQuote -gt 1) {
            return $expanded.Substring(1, $endQuote - 1)
        }
    }

    $exeMatch = [regex]::Match($expanded, '^(.+?\.exe)(?:\s|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($exeMatch.Success) {
        return $exeMatch.Groups[1].Value
    }

    $firstToken = $expanded.Split(' ')[0]
    if ($firstToken -match '^[A-Za-z]:\\|^\\\\|^%') {
        return $firstToken
    }

    return $null
}

function Test-MicrosoftSignedFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path
        if (-not $signature.SignerCertificate) {
            return $false
        }

        $subject = $signature.SignerCertificate.Subject
        return ($signature.Status -eq 'Valid' -and $subject -match 'Microsoft')
    }
    catch {
        return $false
    }
}

function Get-FileCompanyName {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Item -LiteralPath $Path).VersionInfo.CompanyName
    }
    catch {
        return $null
    }
}

function Test-MicrosoftOwnedFile {
    param([string]$Path)

    $companyName = Get-FileCompanyName -Path $Path
    return (-not [string]::IsNullOrWhiteSpace($companyName) -and $companyName -match 'Microsoft')
}

function Get-ServiceSnapshot {
    Get-CimInstance Win32_Service | ForEach-Object {
        $imagePath = Get-ServiceImagePath -PathName $_.PathName
        $companyName = Get-FileCompanyName -Path $imagePath
        [pscustomobject]@{
            Name              = $_.Name
            DisplayName       = $_.DisplayName
            StartMode         = $_.StartMode
            State             = $_.State
            ServiceType       = $_.ServiceType
            StartName         = $_.StartName
            PathName          = $_.PathName
            ImagePath         = $imagePath
            CompanyName       = $companyName
            IsMicrosoftSigned = Test-MicrosoftSignedFile -Path $imagePath
            IsMicrosoftOwned  = (-not [string]::IsNullOrWhiteSpace($companyName) -and $companyName -match 'Microsoft')
        }
    }
}

function Test-IsStartupTask {
    param([object]$Task)

    foreach ($trigger in $Task.Triggers) {
        $className = $trigger.CimClass.CimClassName
        if ($className -in @('MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger', 'MSFT_TaskRegistrationTrigger')) {
            return $true
        }
    }

    return $false
}

function Get-ScheduledTaskSnapshot {
    Get-ScheduledTask | Where-Object { Test-IsStartupTask -Task $_ } | ForEach-Object {
        [pscustomobject]@{
            TaskName    = $_.TaskName
            TaskPath    = $_.TaskPath
            State       = $_.State.ToString()
            IsMicrosoft = ($_.TaskPath -like '\Microsoft\*')
        }
    }
}

function New-StartupSnapshot {
    $runEntries = foreach ($path in Get-RunKeyPaths) {
        Get-RegistryValueEntries -Path $path
    }

    $startupApprovedEntries = foreach ($path in Get-StartupApprovedKeyPaths) {
        Get-RegistryValueEntries -Path $path
    }

    $startupFolderItems = foreach ($folder in Get-StartupFolderPaths) {
        Get-ChildItem -LiteralPath $folder.Path -Force | ForEach-Object {
            [pscustomobject]@{
                Scope        = $folder.Scope
                OriginalPath = $_.FullName
                Name         = $_.Name
                ItemType     = if ($_.PSIsContainer) { 'Directory' } else { 'File' }
                DisabledPath = $null
            }
        }
    }

    [pscustomobject]@{
        CreatedAt          = (Get-Date).ToString('o')
        ComputerName       = $env:COMPUTERNAME
        UserName           = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Services           = @(Get-ServiceSnapshot)
        RunEntries         = @($runEntries)
        StartupApprovedEntries = @($startupApprovedEntries)
        StartupFolderItems = @($startupFolderItems)
        ScheduledTasks     = @(Get-ScheduledTaskSnapshot)
    }
}

function Save-StartupSnapshot {
    param([string]$Path)

    $snapshot = New-StartupSnapshot
    $resolvedParent = Split-Path -Parent $Path
    if ($resolvedParent -and -not (Test-Path -LiteralPath $resolvedParent)) {
        New-Item -Path $resolvedParent -ItemType Directory -Force | Out-Null
    }

    $snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
    Write-Host "Saved startup snapshot: $Path"
    return $snapshot
}

function Read-StartupSnapshot {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Backup file was not found: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Add-MissingStartupApprovedSnapshot {
    param(
        [object]$Snapshot,
        [string]$BackupFile
    )

    if (Get-Member -InputObject $Snapshot -Name 'StartupApprovedEntries' -MemberType NoteProperty) {
        return $Snapshot
    }

    $startupApprovedEntries = foreach ($path in Get-StartupApprovedKeyPaths) {
        Get-RegistryValueEntries -Path $path
    }

    $Snapshot | Add-Member -MemberType NoteProperty -Name 'StartupApprovedEntries' -Value @($startupApprovedEntries)
    $Snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $BackupFile -Encoding UTF8
    Write-Host "Added StartupApprovedEntries to older backup: $BackupFile"

    return $Snapshot
}

function Get-RestoreMissingItems {
    param([object]$Snapshot)

    $missing = New-Object System.Collections.Generic.List[object]

    foreach ($service in @($Snapshot.Services)) {
        if ([string]::IsNullOrWhiteSpace($service.ImagePath)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $service.ImagePath -PathType Leaf)) {
            $missing.Add([pscustomobject]@{
                Area       = 'Service'
                Name       = $service.Name
                TargetPath = $service.ImagePath
                Detail     = $service.DisplayName
            })
        }
    }

    foreach ($entry in @($Snapshot.RunEntries)) {
        $targetPath = Get-CommandTargetPath -Command $entry.Value
        if ([string]::IsNullOrWhiteSpace($targetPath)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            $missing.Add([pscustomobject]@{
                Area       = 'RunEntry'
                Name       = $entry.Name
                TargetPath = $targetPath
                Detail     = "$($entry.Path)\$($entry.Name)"
            })
        }
    }

    foreach ($item in @($Snapshot.StartupFolderItems)) {
        if ([string]::IsNullOrWhiteSpace($item.DisabledPath)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $item.DisabledPath)) {
            $missing.Add([pscustomobject]@{
                Area       = 'StartupFolderItem'
                Name       = $item.Name
                TargetPath = $item.DisabledPath
                Detail     = "Saved copy for $($item.OriginalPath)"
            })
        }
    }

    return $missing.ToArray()
}

function Get-MissingItemKey {
    param([object]$MissingItem)

    return "$($MissingItem.Area)|$($MissingItem.Name)|$($MissingItem.TargetPath)"
}

function Resolve-MissingRestoreItems {
    param(
        [object[]]$MissingItems,
        [string]$Action
    )

    $result = [pscustomobject]@{
        SkipAll  = $false
        SkipKeys = @{}
    }

    if ($MissingItems.Count -eq 0) {
        return $result
    }

    Write-Warning "Restore validation found $($MissingItems.Count) referenced item(s) that do not currently exist."
    $MissingItems | Select-Object Area, Name, TargetPath, Detail | Format-Table -AutoSize | Out-Host

    switch ($Action) {
        'Abort' {
            throw 'Restore aborted because missing referenced items were found.'
        }
        'Skip' {
            foreach ($item in $MissingItems) {
                $result.SkipKeys[(Get-MissingItemKey -MissingItem $item)] = $true
            }

            return $result
        }
        'RestoreAnyway' {
            return $result
        }
        'Prompt' {
            foreach ($item in $MissingItems) {
                Write-Host ''
                Write-Host "Missing $($item.Area): $($item.Name)"
                Write-Host "Target: $($item.TargetPath)"
                if (-not [string]::IsNullOrWhiteSpace($item.Detail)) {
                    Write-Host "Detail: $($item.Detail)"
                }

                do {
                    $choice = Read-Host 'Restore this item anyway? [Y]es/[N]o/[A]bort'
                    $choice = $choice.Trim().ToUpperInvariant()
                } while ($choice -notin @('Y', 'YES', 'N', 'NO', 'A', 'ABORT'))

                if ($choice -in @('A', 'ABORT')) {
                    throw 'Restore aborted by user.'
                }

                if ($choice -in @('N', 'NO')) {
                    $result.SkipKeys[(Get-MissingItemKey -MissingItem $item)] = $true
                }
            }

            return $result
        }
    }
}

function Test-ShouldSkipMissingRestoreItem {
    param(
        [object]$SkipPlan,
        [string]$Area,
        [string]$Name,
        [string]$TargetPath
    )

    if (-not $SkipPlan) {
        return $false
    }

    if ($SkipPlan.SkipAll) {
        return $true
    }

    $key = "$Area|$Name|$TargetPath"
    return $SkipPlan.SkipKeys.ContainsKey($key)
}

function Write-ServiceChangeFailures {
    param(
        [object[]]$Failures,
        [string]$ActionText
    )

    if (-not $Failures -or $Failures.Count -eq 0) {
        return
    }

    Write-Warning "$($Failures.Count) service(s) could not be changed while trying to $ActionText."
    $Failures | Select-Object Name, DisplayName, StartMode, Error | Format-Table -AutoSize | Out-Host
    Write-Warning 'Access denied on security products is commonly caused by tamper/self-protection. Use the vendor app to temporarily disable protection, or leave those services unchanged.'
}

function Disable-NonMicrosoftServices {
    param([object]$Snapshot)

    $failures = New-Object System.Collections.Generic.List[object]

    foreach ($service in $Snapshot.Services) {
        $isWin32Service = $service.ServiceType -like '*Process*'
        $isMicrosoft = if (Get-Member -InputObject $service -Name 'IsMicrosoftOwned' -MemberType NoteProperty) {
            $service.IsMicrosoftOwned
        }
        else {
            $service.IsMicrosoftSigned
        }

        if (-not $isWin32Service -or $isMicrosoft -or $service.StartMode -eq 'Disabled') {
            continue
        }

        if ($PSCmdlet.ShouldProcess($service.Name, 'Disable non-Microsoft service startup')) {
            try {
                Set-Service -Name $service.Name -StartupType Disabled -ErrorAction Stop
            }
            catch {
                $failures.Add([pscustomobject]@{
                    Name        = $service.Name
                    DisplayName = $service.DisplayName
                    StartMode   = $service.StartMode
                    Error       = $_.Exception.Message
                })
            }
        }
    }

    return $failures.ToArray()
}

function Disable-RunEntries {
    param([object]$Snapshot)

    foreach ($entry in $Snapshot.RunEntries) {
        if ($PSCmdlet.ShouldProcess("$($entry.Path)\$($entry.Name)", 'Remove saved startup Run entry')) {
            Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Force -ErrorAction SilentlyContinue
        }
    }
}

function Disable-StartupApprovedEntries {
    param([object]$Snapshot)

    $existingByPathAndName = @{}
    $startupApprovedEntries = @()
    if (Get-Member -InputObject $Snapshot -Name 'StartupApprovedEntries' -MemberType NoteProperty) {
        $startupApprovedEntries = @($Snapshot.StartupApprovedEntries)
        foreach ($entry in $startupApprovedEntries) {
            $existingByPathAndName["$($entry.Path)|$($entry.Name)"] = $entry
        }
    }

    $disabledEntries = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $startupApprovedEntries) {
        $disabledEntries.Add((New-DisabledStartupApprovedEntry -Path $entry.Path -Name $entry.Name -ExistingEntry $entry))
    }

    foreach ($entry in @($Snapshot.RunEntries)) {
        $approvedPath = Get-StartupApprovedPathForRunEntry -Entry $entry
        if ([string]::IsNullOrWhiteSpace($approvedPath)) {
            continue
        }

        $key = "$approvedPath|$($entry.Name)"
        $existingEntry = $existingByPathAndName[$key]
        $disabledEntries.Add((New-DisabledStartupApprovedEntry -Path $approvedPath -Name $entry.Name -ExistingEntry $existingEntry))
    }

    foreach ($item in @($Snapshot.StartupFolderItems)) {
        $approvedPath = Get-StartupApprovedPathForStartupFolderItem -Item $item
        if ([string]::IsNullOrWhiteSpace($approvedPath)) {
            continue
        }

        $key = "$approvedPath|$($item.Name)"
        $existingEntry = $existingByPathAndName[$key]
        $disabledEntries.Add((New-DisabledStartupApprovedEntry -Path $approvedPath -Name $item.Name -ExistingEntry $existingEntry))
    }

    foreach ($entry in @($disabledEntries.ToArray() | Sort-Object Path, Name -Unique)) {
        if ($PSCmdlet.ShouldProcess("$($entry.Path)\$($entry.Name)", 'Mark startup item disabled in StartupApproved')) {
            Set-RegistryValueEntry -Entry $entry
        }
    }
}

function Disable-StartupFolderItems {
    param(
        [object]$Snapshot,
        [string]$BackupFile
    )

    $sidecar = Get-SidecarPath -Path $BackupFile
    $changed = $false

    foreach ($item in $Snapshot.StartupFolderItems) {
        if (-not (Test-Path -LiteralPath $item.OriginalPath)) {
            continue
        }

        $targetDir = Join-Path $sidecar ('StartupFolder\{0}' -f $item.Scope)
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
        }

        $disabledPath = Join-Path $targetDir $item.Name
        if (Test-Path -LiteralPath $disabledPath) {
            $uniqueName = '{0}-{1}' -f ([guid]::NewGuid().ToString('N')), $item.Name
            $disabledPath = Join-Path $targetDir $uniqueName
        }

        if ($PSCmdlet.ShouldProcess($item.OriginalPath, "Move to $disabledPath")) {
            Move-Item -LiteralPath $item.OriginalPath -Destination $disabledPath -Force
            $item.DisabledPath = $disabledPath
            $changed = $true
        }
    }

    if ($changed) {
        $Snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $BackupFile -Encoding UTF8
    }
}

function Disable-StartupScheduledTasks {
    param([object]$Snapshot)

    foreach ($task in $Snapshot.ScheduledTasks) {
        if ($task.State -eq 'Disabled') {
            continue
        }

        if ($task.IsMicrosoft -and -not $IncludeMicrosoftScheduledTasks) {
            continue
        }

        if ($PSCmdlet.ShouldProcess("$($task.TaskPath)$($task.TaskName)", 'Disable startup scheduled task')) {
            Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Continue | Out-Null
        }
    }
}

function Restore-Services {
    param(
        [object]$Snapshot,
        [object]$SkipPlan
    )

    $failures = New-Object System.Collections.Generic.List[object]

    foreach ($service in $Snapshot.Services) {
        if (Test-ShouldSkipMissingRestoreItem -SkipPlan $SkipPlan -Area 'Service' -Name $service.Name -TargetPath $service.ImagePath) {
            Write-Host "Skipping missing service target: $($service.Name)"
            continue
        }

        $startupType = switch ($service.StartMode) {
            'Auto'     { 'Automatic' }
            'Manual'   { 'Manual' }
            'Disabled' { 'Disabled' }
            default    { $null }
        }

        if (-not $startupType) {
            continue
        }

        if ($PSCmdlet.ShouldProcess($service.Name, "Restore service startup type to $startupType")) {
            try {
                Set-Service -Name $service.Name -StartupType $startupType -ErrorAction Stop
            }
            catch {
                $failures.Add([pscustomobject]@{
                    Name        = $service.Name
                    DisplayName = $service.DisplayName
                    StartMode   = $service.StartMode
                    Error       = $_.Exception.Message
                })
            }
        }
    }

    return $failures.ToArray()
}

function Restore-RunEntries {
    param(
        [object]$Snapshot,
        [object]$SkipPlan
    )

    foreach ($entry in $Snapshot.RunEntries) {
        $targetPath = Get-CommandTargetPath -Command $entry.Value
        if (Test-ShouldSkipMissingRestoreItem -SkipPlan $SkipPlan -Area 'RunEntry' -Name $entry.Name -TargetPath $targetPath) {
            Write-Host "Skipping missing Run entry target: $($entry.Name)"
            continue
        }

        if ($PSCmdlet.ShouldProcess("$($entry.Path)\$($entry.Name)", 'Restore startup Run entry')) {
            Set-RegistryValueEntry -Entry $entry
        }
    }
}

function Restore-StartupApprovedEntries {
    param([object]$Snapshot)

    if (-not (Get-Member -InputObject $Snapshot -Name 'StartupApprovedEntries' -MemberType NoteProperty)) {
        Write-Warning 'Backup does not contain StartupApprovedEntries. Task Manager startup enabled/disabled state cannot be restored from this backup.'
        return
    }

    foreach ($entry in $Snapshot.StartupApprovedEntries) {
        if ($PSCmdlet.ShouldProcess("$($entry.Path)\$($entry.Name)", 'Restore Task Manager startup enabled/disabled state')) {
            Set-RegistryValueEntry -Entry $entry
        }
    }
}

function Restore-StartupFolderItems {
    param(
        [object]$Snapshot,
        [object]$SkipPlan
    )

    foreach ($item in $Snapshot.StartupFolderItems) {
        if (Test-ShouldSkipMissingRestoreItem -SkipPlan $SkipPlan -Area 'StartupFolderItem' -Name $item.Name -TargetPath $item.DisabledPath) {
            Write-Host "Skipping missing Startup folder saved copy: $($item.Name)"
            continue
        }

        if ([string]::IsNullOrWhiteSpace($item.DisabledPath) -or -not (Test-Path -LiteralPath $item.DisabledPath)) {
            continue
        }

        $targetDir = Split-Path -Parent $item.OriginalPath
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
        }

        if ($PSCmdlet.ShouldProcess($item.DisabledPath, "Move back to $($item.OriginalPath)")) {
            Move-Item -LiteralPath $item.DisabledPath -Destination $item.OriginalPath -Force
        }
    }
}

function Restore-ScheduledTasks {
    param([object]$Snapshot)

    foreach ($task in $Snapshot.ScheduledTasks) {
        if ($PSCmdlet.ShouldProcess("$($task.TaskPath)$($task.TaskName)", "Restore scheduled task state to $($task.State)")) {
            if ($task.State -eq 'Disabled') {
                Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Continue | Out-Null
            }
            else {
                Enable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Continue | Out-Null
            }
        }
    }
}

function Show-StartupStatus {
    $snapshot = New-StartupSnapshot
    $nonMicrosoftServices = @($snapshot.Services | Where-Object {
        $_.ServiceType -like '*Process*' -and -not $_.IsMicrosoftOwned -and $_.StartMode -ne 'Disabled'
    })
    $startupTasks = @($snapshot.ScheduledTasks | Where-Object { -not $_.IsMicrosoft -and $_.State -ne 'Disabled' })

    [pscustomobject]@{
        NonMicrosoftEnabledServices = $nonMicrosoftServices.Count
        RegistryRunEntries          = @($snapshot.RunEntries).Count
        StartupApprovedEntries      = @($snapshot.StartupApprovedEntries).Count
        StartupFolderItems          = @($snapshot.StartupFolderItems).Count
        NonMicrosoftStartupTasks    = $startupTasks.Count
    } | Format-List
}

switch ($Action) {
    'Save' {
        if ([string]::IsNullOrWhiteSpace($BackupPath)) {
            $BackupPath = New-DefaultBackupPath
        }

        Save-StartupSnapshot -Path $BackupPath | Out-Null
    }

    'CleanBoot' {
        Assert-Administrator -AllowWhatIf
        Confirm-DestructiveExecution -ActionName 'CleanBoot'

        if ([string]::IsNullOrWhiteSpace($BackupPath)) {
            $BackupPath = New-DefaultBackupPath
        }

        if (Test-Path -LiteralPath $BackupPath -PathType Leaf) {
            Write-Host "Using existing startup snapshot: $BackupPath"
            $snapshot = Read-StartupSnapshot -Path $BackupPath
            $snapshot = Add-MissingStartupApprovedSnapshot -Snapshot $snapshot -BackupFile $BackupPath
        }
        else {
            $snapshot = Save-StartupSnapshot -Path $BackupPath
        }

        $serviceFailures = @(Disable-NonMicrosoftServices -Snapshot $snapshot)
        Disable-RunEntries -Snapshot $snapshot
        Disable-StartupApprovedEntries -Snapshot $snapshot
        Disable-StartupFolderItems -Snapshot $snapshot -BackupFile $BackupPath
        Disable-StartupScheduledTasks -Snapshot $snapshot

        Write-ServiceChangeFailures -Failures $serviceFailures -ActionText 'stage clean boot'

        Write-Host 'Clean-boot startup changes are staged. Restart Windows to boot with them.'
        Write-Host "Restore later with: .\Manage-CleanBootStartup.ps1 -Action Restore -BackupPath `"$BackupPath`""
    }

    'Restore' {
        Assert-Administrator -AllowWhatIf
        Confirm-DestructiveExecution -ActionName 'Restore'

        if ([string]::IsNullOrWhiteSpace($BackupPath)) {
            $BackupPath = Select-StartupBackupPath
            Write-Host "Using startup snapshot: $BackupPath"
        }

        $snapshot = Read-StartupSnapshot -Path $BackupPath
        $missingItems = Get-RestoreMissingItems -Snapshot $snapshot
        $skipPlan = Resolve-MissingRestoreItems -MissingItems $missingItems -Action $MissingItemAction

        $serviceFailures = @(Restore-Services -Snapshot $snapshot -SkipPlan $skipPlan)
        Restore-RunEntries -Snapshot $snapshot -SkipPlan $skipPlan
        Restore-StartupApprovedEntries -Snapshot $snapshot
        Restore-StartupFolderItems -Snapshot $snapshot -SkipPlan $skipPlan
        Restore-ScheduledTasks -Snapshot $snapshot

        Write-ServiceChangeFailures -Failures $serviceFailures -ActionText 'restore service startup modes'

        if ($WhatIfPreference) {
            Write-Host 'Restore preview completed. No startup settings were changed.'
        }
        else {
            Write-Host 'Startup settings restored from snapshot. Restart Windows to return fully to the saved mode.'
        }
    }

    'Status' {
        Show-StartupStatus
    }
}
