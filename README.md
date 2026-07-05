# Manage Clean Boot Startup

This repository contains a PowerShell script that saves, inspects, and restores Windows startup-related settings for a reversible clean-boot profile.

This is useful before installing software, changing drivers, or troubleshooting startup issues. You can later compare the saved snapshot with the current state to see what changed.

## What it does

The script can:
- Save a snapshot of startup-related settings
- Report the current startup state
- Compare snapshots to identify what changed between saved backups
- Compare the current state to a saved backup to highlight drift or recent changes
- Stage clean-boot changes by disabling non-Microsoft services and startup items
- Restore the saved startup state from a backup

## Safety notice

This tool makes real changes to Windows startup behavior, including:
- service startup modes
- registry Run entries
- Task Manager startup approvals
- startup folder items
- scheduled tasks with startup/logon triggers

## Safety story

This script is intentionally conservative:
- it defaults to WhatIf mode so it previews changes first
- it requires you to type `Yes` before performing a real CleanBoot or Restore action
- it saves a backup first and can restore from it later
- it is meant for advanced troubleshooting and system administration use

Use it at your own risk. It is provided as-is, without warranties of any kind. No support is provided.

## Default behavior

The script defaults to WhatIf mode, so it will preview changes instead of applying them unless you explicitly disable preview mode.

### Examples:

Save the current startup state to a file:

```powershell
powershell -ExecutionPolicy Bypass -File .\Manage-CleanBootStartup.ps1 -Action Save
```

Inspect the current startup state:

```powershell
powershell -ExecutionPolicy Bypass -File .\Manage-CleanBootStartup.ps1 -Action Status
```

To preview a clean-boot change without modifying anything:

```powershell
powershell -ExecutionPolicy Bypass -File .\Manage-CleanBootStartup.ps1 -Action CleanBoot
```

To actually apply changes:

```powershell
powershell -ExecutionPolicy Bypass -File .\Manage-CleanBootStartup.ps1 -Action CleanBoot -WhatIf:$false
```

## Why this can be useful

Saving a startup snapshot before installing software, or troubleshooting startup issues gives you a reliable baseline. Later, you can compare the saved snapshot with the current state to spot what changed, identify suspicious startup entries or services, and narrow down whether a recent change introduced a problem.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Windows-only; this script uses Windows-specific APIs and registry/service access
- Run from an elevated PowerShell session when performing real changes

## Known limitations

- Some services and startup items may be protected by security products and cannot be changed
- Some startup entries may restore differently depending on the current Windows build or installed software
- The script is intended as a safety-focused backup and restore utility, not a guaranteed universal clean-boot tool

## Changelog

### v1.0.0
- Initial public release
- Save, inspect, compare, and restore startup snapshots
- Safe preview mode by default
- Confirmation required before performing real CleanBoot or Restore actions
- Documentation, license, and repository scaffolding added

## License

This project is licensed under the MIT License. See the LICENSE file for details.
