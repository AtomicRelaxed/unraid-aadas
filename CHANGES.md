###2026.11.19d (0.1.0 RC1)
- Updates now replace the plugin files (the plugin manager skips files that already exist, so 2026.11.19c did not apply its README)

###2026.11.19c (0.1.0 RC1)
- Plugin list: short README (bold title instead of a large heading); the full description is on the project page

###2026.11.19b (0.1.0 RC1)
- Autosave schedule is active right after a fresh install (before: only after the next reboot)

###2026.11.19a (0.1.0 RC1)
- Custom SMB Shares: after a set was applied at boot, its Samba config is rebuilt when the array has started (that plugin writes its config before the boot step and its own start handler does not run), so the new set's SMB shares are exported instead of the old ones

###2026.11.19 (0.1.0 RC1)
- Renamed to AADAS - Auto Array Detection and Swap (was "Disk Sets"); author RaisonRed; own icon; README in the plugin manager
- Detect the installed set at boot (switch on the page, off by default): the one saved set whose disks are installed EXACTLY is applied; boot flash, global pools and ignored disks (IGNORE_IDS) do not count. Missing, extra, unknown or mixed disks, two matches or an empty manifest: nothing is applied, autostart is held
- Staged, verified switch: autostart hold first, verified backup, staged target, journal; the live files are replaced and compared, only then the set becomes active. A failed switch is rolled back at once, an interrupted one at the next boot
- Preview "Next boot" on the page (plan): what the boot step would do and why, with every disk and its set; read-only
- The active set is saved when the array stops (on by default), only if its disks are exactly installed and unchanged
- Notification after boot: set applied, or not applied with the reason
- A set without its own SMB share list gets an empty list instead of keeping the previous set's exports; a set that contains a pool that is global now is not applied
- Read-only commands write nothing; actions are serialized; the newest pre-switch backup is never pruned; scheduled autosave writes to the log
- Known limit: a switch needs at least one pool config (global pools always count); an Unraid without any pool cannot switch sets
###2026.11.10
- Share list of the "Custom SMB Shares" plugin is saved with each set and switched with it (applied at boot, the plugin rebuilds its Samba config when the array starts); status shows the enabled SMB shares
###2026.11.09
- Array autostart is handled by the boot step: held off while the installed disks do not match a saved set (pending switch, new set, swapped disks), restored to the user's setting once they match. The switch no longer requires autostart to be off.
- A new, empty set gets its name when switching ("switch new NAME"); after the boot it is the active set and can be saved under that name
- Errors from an action stay on screen (dialog) instead of disappearing with the page reload
- Tested on Unraid 7.3.4
###2026.11.08c
- Schedule button renamed: Unraid disables every button labelled "Apply" until a form changes
###2026.11.08b
- Rename and delete sets (delete moves the set to backups; the active or pending set cannot be deleted)
- Scheduled automatic backup of the active set (off / daily / weekly), only when the installed disks match; keeps the newest 20 backups
###2026.11.08a
- First local version: status, saved sets, save, switch (two-phase, applied at boot before emhttp), mismatch notification
