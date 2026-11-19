# AADAS - Auto Array Detection & Swap

**Swap whole disk sets in one Unraid server. At boot, the set that is installed is detected and its configuration is applied.**

Some Unraid servers hold more than one set of disks, for example a media set and a backup set, and only one set is installed at a time. Unraid keeps a single array configuration. Without help, every swap means reassigning slots, pools and shares by hand, and one wrong click can start the array with the wrong disks.

AADAS saves the configuration of each set: slot assignment (`super.dat`), pool and share configs, and the share list of the *Custom SMB Shares* plugin. It switches between sets as one unit.

## Features
- **Detect at boot** (optional): before Unraid reads its configuration, the one saved set whose disks are installed *exactly* is applied. The boot flash, global pools and ignored disks do not count.
- **Safe by default:** if anything is unclear (missing, extra, unknown or mixed disks, two matching sets, an incomplete set), nothing is changed. Array autostart is held and a notification says why.
- **Verified switch:** autostart is held first. A backup with SHA-256 checksums is written and checked, the target is staged, and a journal records each phase. The live files are replaced and compared. A failed switch is rolled back at once, an interrupted one at the next boot.
- **Preview:** the page shows what the next boot would do and why, with every disk and the set it belongs to. The preview is read-only.
- **Save on stop:** the active set is saved when the array stops, but only if its disks are exactly installed.
- **Global pools** (for example a cache SSD) stay in place for every set.

## Usage
Utilities → AADAS - Auto Array Detection & Swap. Save the current set, swap the disks, and either switch manually or turn on *Detect the installed set at boot*.

**Never format a disk because a set was not applied.** Check the notification and the preview first.

## Requirements
Unraid 7.0 or newer. The plugin adds one line to `/boot/config/go`, before `emhttp`; uninstalling removes it. Saved sets in `/boot/config/aadas` are kept when the plugin is removed.

## Status
0.1.0 RC1 (plugin version 2026.11.19), a release candidate. Tested on one server (Unraid 7.3.4, two sets of 9 disks plus a global SSD pool) and with isolated fixture tests of the boot and rollback paths. A real power loss during a switch has not been tested. Keep a flash backup.

Author: RaisonRed. License: GPLv3 or later.
