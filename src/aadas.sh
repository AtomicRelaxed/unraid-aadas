#!/bin/bash
# aadas.sh - swap whole disk sets on Unraid 7.x
# Copyright (C) 2026 AtomicRelaxed. License: GPLv3 or later.
#
# A disk set = the non-global pools (pools/*.cfg incl. subpools), the shares that live on them, the array assignment
# (super.dat) and, if the "Custom SMB Shares" plugin is installed, its share list. Global pools (an always-installed
# SSD with appdata/system) are never touched.
#
# Identity of a set = its manifest (profiles/<set>/disks.txt, one disk id per line). A set is INSTALLED when the
# managed disks (present - boot flash - global pool disks - IGNORE_IDS) are EXACTLY its manifest.
#
# Switching is two-phase:
#   1. "switch <set>" (array stopped): save the current set, mark <set> as pending.
#   2. "boot" runs from /boot/config/go BEFORE emhttp starts and applies the pending set - or, with AUTO_DETECT="yes",
#      the one saved set that is installed - if its disks are exactly present. Otherwise nothing changes and the array
#      autostart is held off until the disks match.
# Apply is staged: autostart hold -> verified backup -> staged target -> journal -> swap -> verify -> publish.
# An interrupted swap is rolled back from the backup at the next boot. The array is never started by this tool.
#
# Read-only commands (status, list, detect, check, plan, boot --dry-run) write nothing.
# Test hooks: AADAS_ROOT (prefix for /boot/config), AADAS_BYID, AADAS_EMHTTP, AADAS_FLASHDEV, AADAS_SETTLE=0.
set -u
umask 077
ROOT=${AADAS_ROOT:-}
CFG=$ROOT/boot/config
BYID=${AADAS_BYID:-/dev/disk/by-id}
EMH=${AADAS_EMHTTP:-/var/local/emhttp}
BASE=$CFG/aadas
PROF=$BASE/profiles
BAK=$BASE/backups
LOG=$BASE/aadas.log
GLOBALCFG=$BASE/global.cfg          # GLOBAL_POOLS="ssd"  AUTO_DETECT="no"  SAVE_ON_STOP="yes"  IGNORE_IDS=""
JOURNAL=$BASE/journal
LASTBOOT=$BASE/last_boot
STAGE=$BASE/.staging
VAR=$EMH/var.ini
DISKS=$EMH/disks.ini
SMBDIR=$CFG/plugins/custom.smb.shares
SMBJSON=$SMBDIR/shares.json

GLOBAL_POOLS=""; AUTO_DETECT="no"; AUTOSAVE="off"; KEEP_BACKUPS=20; SAVE_ON_STOP="yes"; IGNORE_IDS=""
# shellcheck source=/dev/null
[ -f "$GLOBALCFG" ] && . "$GLOBALCFG"
RO=1                                # 1 = read-only command: no log, no directories, no files

log()  { [ "$RO" = 1 ] || echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; echo "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
is_global() { local p=${1%%~*} g; for g in $GLOBAL_POOLS; do [ "$p" = "$g" ] && return 0; done; return 1; }
md_state() { grep -oP '^mdState="\K[^"]+' "$VAR" 2>/dev/null; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "set name must be 1-32 chars [A-Za-z0-9_-]"; }
active()  { cat "$BASE/active" 2>/dev/null; }
pending() { cat "$BASE/pending" 2>/dev/null; }

# ---------------------------------------------------------------- inventory
# One line "<id> <dev>" per physical disk. Preferred alias: ata- > nvme- > scsi- > usb- (wwn-, nvme-eui., nvme-nvme. and
# partitions never count). id = link name without its bus prefix, as Unraid writes it into diskId.
inventory() {
  local pref f b t
  for pref in ata nvme scsi usb; do
    for f in "$BYID"/"$pref"-*; do
      [ -e "$f" ] || continue
      b=${f##*/}
      [[ "$b" =~ -part[0-9]+$ ]] && continue
      [[ "$b" =~ ^nvme-(eui|nvme)\. ]] && continue
      t=$(readlink -f "$f" 2>/dev/null) || continue
      echo "${b#*-} ${t##*/}"
    done
  done | awk '!seen[$2]++' | sort
}
# boot devices (class "flash"): whole-disk kernel names that hold /boot, space-separated.
# USB flash (sda1 -> sda), internal boot since Unraid 7.3 (SATA sdb1 -> sdb, NVMe nvme0n1p1 -> nvme0n1),
# or every disk of a ZFS boot pool (mirror). Unknown -> empty: the boot disk then counts as "unknown" and nothing is applied.
flash_dev() {
  if [ -n "${AADAS_FLASHDEV:-}" ]; then echo "$AADAS_FLASHDEV"; return; fi
  local s t d p
  s=$(findmnt -no SOURCE /boot 2>/dev/null | head -n1); s=${s%%\[*}
  t=$(findmnt -no FSTYPE /boot 2>/dev/null | head -n1)
  { if [ "$t" = zfs ]; then
      for d in $(zpool list -vHP "${s%%/*}" 2>/dev/null | awk '$1 ~ /^\/dev\// {print $1}'); do
        p=$(lsblk -no PKNAME "$d" 2>/dev/null | head -n1); d=$(readlink -f "$d"); echo "${p:-${d##*/}}"
      done
    elif [ -b "$s" ]; then
      p=$(lsblk -no PKNAME "$s" 2>/dev/null | head -n1); echo "${p:-${s##*/}}"
    fi; } | grep . | sort -u | tr '\n' ' ' | sed 's/ $//'
}
# inventory twice until stable (devices that show up late must not make a set look incomplete or different)
settle() {
  [ "${AADAS_SETTLE:-1}" = 0 ] && { INV=$(inventory); return 0; }
  command -v udevadm >/dev/null 2>&1 && udevadm settle -t 10 >/dev/null 2>&1
  local a i; a=$(inventory)
  for i in 1 2 3 4 5; do sleep 2; INV=$(inventory); [ "$a" = "$INV" ] && return 0; a=$INV; done
  return 1
}
global_ids() {
  local g f
  for g in $GLOBAL_POOLS; do
    for f in "$CFG/pools/$g.cfg" "$CFG/pools/$g"~*.cfg; do [ -f "$f" ] && grep -oP '^diskId(\.\d+)?="\K[^"]+' "$f"; done
  done
  for g in $IGNORE_IDS; do echo "$g"; done
}
# needs $INV
managed_ids() {
  local fd; fd=" $(flash_dev) "
  comm -23 <(awk -v fd="$fd" 'index(fd, " " $2 " ") == 0 {print $1}' <<< "$INV" | sort -u) <(global_ids | sort -u) | grep .
}
# manifest of a profile: readable, non-empty -> sorted ids on stdout, else return 1
manifest() {
  local f=$PROF/$1/disks.txt m
  [ -r "$f" ] || return 1
  m=$(grep -v '^[[:space:]]*$' "$f" | sort -u) || return 1
  [ -n "$m" ] || return 1
  echo "$m"
}
profiles() { local d; for d in "$PROF"/*/; do [ -d "$d" ] && basename "$d"; done; }
# all saved sets whose manifest equals the managed disks (needs $INV)
exact_hits() {
  local n m man; man=$(managed_ids)
  [ -n "$man" ] || return 0
  for n in $(profiles); do m=$(manifest "$n") || continue; [ "$m" = "$man" ] && echo "$n"; done
}
# the one saved set that is installed exactly, else return 1 (none or ambiguous)
detect_exact() {
  local h; h=$(exact_hits)
  [ "$(echo "$h" | grep -c .)" -eq 1 ] && { echo "$h"; return 0; }
  return 1
}
# by-id links of disks that point to no device (a disk vanished or is still coming up)
broken_links() {
  local pref f
  for pref in ata nvme scsi usb; do
    for f in "$BYID"/"$pref"-*; do
      [ -L "$f" ] && [ ! -e "$f" ] && ! [[ "${f##*/}" =~ -part[0-9]+$ ]] && echo "${f##*/}"
    done
  done
}
class_of() {   # <id> -> flash|global|ignored|set:NAME|unknown (needs $INV)
  local id=$1 dev n g
  dev=$(awk -v i="$id" '$1 == i {print $2; exit}' <<< "$INV")
  [ -n "$dev" ] && [[ " $(flash_dev) " == *" $dev "* ]] && { echo flash; return; }
  for g in $IGNORE_IDS; do [ "$g" = "$id" ] && { echo ignored; return; }; done
  global_ids | grep -qxF "$id" && { echo global; return; }
  for n in $(profiles); do manifest "$n" 2>/dev/null | grep -qxF "$id" && { echo "set:$n"; return; }; done
  echo unknown
}

# ---------------------------------------------------------------- decision (read-only)
# sets: DECISION TARGET AUTO AUTOSTART REASON REF (set whose disks are compared for missing/extra)
decide() {
  DECISION=none; TARGET=""; AUTO=no; AUTOSTART=unchanged; REASON=""; REF=""
  if [ -f "$JOURNAL" ]; then
    DECISION=recover; TARGET=$(grep -oP '^target=\K.*' "$JOURNAL"); AUTOSTART=hold
    REASON="an interrupted switch was found (journal) - the previous configuration is restored from its backup"; return
  fi
  [ "${STABLE:-yes}" = yes ] || { DECISION=hold; AUTOSTART=hold; REASON="disk inventory not stable after 10 s"; return; }
  local bl; bl=$(broken_links)
  [ -z "$bl" ] || { DECISION=hold; AUTOSTART=hold; REASON="disk link(s) without a device: $(echo "$bl" | tr '\n' ' ')"; return; }
  local hits; hits=$(exact_hits)
  if [ "$(echo "$hits" | grep -c .)" -gt 1 ]; then
    DECISION=hold; AUTOSTART=hold; REASON="ambiguous: the installed disks are exactly the sets $(echo "$hits" | tr '\n' ' ')"; return
  fi
  local a n m man g p; a=$(active); n=$(pending); man=$(managed_ids)
  if [ -z "$n" ] && [ "$AUTO_DETECT" = yes ]; then
    if p=$(detect_exact) && [ "$p" != "$a" ]; then n=$p; AUTO=yes; fi
  fi
  if [ -z "$n" ]; then
    if [ -n "$a" ] && [ -d "$PROF/$a" ]; then
      REF=$a
      if m=$(manifest "$a") && [ "$m" = "$man" ]; then
        DECISION=keep; TARGET=$a; AUTOSTART=restore; REASON="the installed disks are exactly the active set '$a'"
      elif ! manifest "$a" >/dev/null; then
        DECISION=hold; AUTOSTART=hold; REASON="the manifest of the active set '$a' is missing or empty"
      else
        DECISION=hold; AUTOSTART=hold
        REASON="the installed disks are not the active set '$a' and no switch is pending$([ "$AUTO_DETECT" = yes ] && echo " and no other saved set matches exactly")"
      fi
    else
      REASON="no saved active set - nothing to do"
    fi
    return
  fi
  TARGET=$n
  if [ "$n" = new ]; then
    if [ -z "$man" ]; then DECISION=hold; AUTOSTART=hold; REASON="'new' pending, but no disks for a new set are installed"; return; fi
    local d
    for d in $(profiles); do
      m=$(manifest "$d") || continue
      [ -n "$(comm -12 <(echo "$m") <(echo "$man"))" ] && { DECISION=hold; AUTOSTART=hold; REASON="'new' pending, but disks of saved set '$d' are installed"; return; }
    done
    DECISION=apply; AUTOSTART=hold; REASON="new empty set$([ -n "$(cat "$BASE/newname" 2>/dev/null)" ] && echo " '$(cat "$BASE/newname")'") - create the pool, then save the set"
    return
  fi
  REF=$n
  [ -d "$PROF/$n" ] || { DECISION=hold; AUTOSTART=hold; REASON="pending set '$n' does not exist"; return; }
  m=$(manifest "$n") || { DECISION=hold; AUTOSTART=hold; REASON="the manifest of set '$n' is missing or empty"; return; }
  for p in "$PROF/$n"/pools/*.cfg; do [ -f "$p" ] || continue; g=$(basename "$p" .cfg)
    is_global "$g" && { DECISION=hold; AUTOSTART=hold; REASON="set '$n' contains pool '${g%%~*}', which is a global pool now"; return; }
  done
  if [ "$m" != "$man" ]; then DECISION=hold; AUTOSTART=hold; REASON="the installed disks are not exactly set '$n'"; return; fi
  DECISION=apply; AUTOSTART=restore
  REASON="$([ "$AUTO" = yes ] && echo "detected" || echo "pending") set '$n' is installed exactly"
}
print_plan() {
  echo "decision=$DECISION"; echo "target=$TARGET"; echo "auto=$AUTO"; echo "autostart=$AUTOSTART"; echo "reason=$REASON"
  local id dev m man; man=$(managed_ids)
  while read -r id dev; do [ -n "$id" ] && echo "disk=$id $(class_of "$id")"; done <<< "$INV"
  if [ -n "$REF" ] && m=$(manifest "$REF"); then
    comm -23 <(echo "$m") <(echo "$man") | sed 's/^/missing=/'
    comm -13 <(echo "$m") <(echo "$man") | grep . | sed 's/^/extra=/'
  fi
  return 0
}
cmd_plan() { STABLE=yes; settle || STABLE=no; decide; print_plan; }

# ---------------------------------------------------------------- helpers that write
autostart_get() { grep -oP '^startArray="\K[^"]+' "$CFG/disk.cfg" 2>/dev/null; }
# remember the user's value once, then force "no" (before emhttp reads disk.cfg); returns 1 if the hold is not in effect
autostart_off() {
  local cur; cur=$(autostart_get)
  [ -f "$BASE/autostart" ] || echo "${cur:-no}" > "$BASE/autostart"
  if [ "$cur" != no ]; then
    if grep -q '^startArray=' "$CFG/disk.cfg" 2>/dev/null; then sed -i 's/^startArray=.*/startArray="no"/' "$CFG/disk.cfg"
    else echo 'startArray="no"' >> "$CFG/disk.cfg"; fi
    sync
    log "boot: array autostart off ($1); '$(cat "$BASE/autostart")' is restored once the disks match a saved set"
  fi
  [ "$(autostart_get)" = no ]          # the hold counts only if "no" can be read back
}
autostart_restore() {
  [ -f "$BASE/autostart" ] || return 0; local v; v=$(cat "$BASE/autostart")
  [ "$v" = yes ] && [ "$(autostart_get)" != yes ] && sed -i 's/^startArray=.*/startArray="yes"/' "$CFG/disk.cfg"
  rm -f "$BASE/autostart"; log "boot: array autostart restored to '$v'"
}
cpv() { cp -p "$1" "$2" && cmp -s "$1" "$2"; }                 # copy + verify
# exact copy of the managed config files of <cfg-root> into <dir> (pools, shares, super.dat, SMB list); 0 = verified
snapshot() {
  local src=$1 dst=$2 f
  mkdir -p "$dst/pools" "$dst/shares" || return 1
  for f in "$src"/pools/*.cfg;  do [ -f "$f" ] || continue; cpv "$f" "$dst/pools/${f##*/}"  || return 1; done
  for f in "$src"/shares/*.cfg; do [ -f "$f" ] || continue; cpv "$f" "$dst/shares/${f##*/}" || return 1; done
  [ -f "$src/super.dat" ] && { cpv "$src/super.dat" "$dst/super.dat" || return 1; }
  [ -f "$src/plugins/custom.smb.shares/shares.json" ] && { cpv "$src/plugins/custom.smb.shares/shares.json" "$dst/custom_smb_shares.json" || return 1; }
  write_manifest "$dst"
}
# MANIFEST of a backup/staging dir: sha256 per file, "absent <name>" for super.dat / SMB list, last line "complete".
# Written last; a dir without a complete, matching MANIFEST is never installed.
write_manifest() {
  local d=$1 f
  ( cd "$d" || exit 1
    for f in pools/*.cfg shares/*.cfg super.dat custom_smb_shares.json; do [ -f "$f" ] && sha256sum -- "$f"; done
    [ -f super.dat ] || echo "absent super.dat"
    [ -f custom_smb_shares.json ] || echo "absent custom_smb_shares.json"
    echo complete ) > "$d/MANIFEST.tmp" || return 1
  sync; mv "$d/MANIFEST.tmp" "$d/MANIFEST" && sync
}
verify_dir() {
  local d=$1 m=$1/MANIFEST listed actual
  [ -s "$m" ] && [ "$(tail -n1 "$m")" = complete ] || return 1
  grep -q '^[0-9a-f]\{64\}  pools/' "$m" || return 1          # never install a configuration without pools
  ( cd "$d" && grep '^[0-9a-f]\{64\}  ' MANIFEST | sha256sum -c --quiet --strict - >/dev/null 2>&1 ) || return 1
  listed=$(grep -oP '^[0-9a-f]{64}  \K.*' "$m" | sort)
  actual=$(cd "$d" && for f in pools/* shares/* super.dat custom_smb_shares.json; do [ -e "$f" ] && echo "$f"; done | sort)
  [ "$listed" = "$actual" ]
}
absent() { grep -qxF "absent $2" "$1/MANIFEST" 2>/dev/null; }
# do <dir> and the live config hold exactly the same managed files?
same_cfgs() {   # <dirA> <dirB>: same set of *.cfg names with identical content
  local a=$1 b=$2 f
  [ "$(cd "$a" 2>/dev/null && ls -1 -- *.cfg 2>/dev/null | sort)" = "$(cd "$b" 2>/dev/null && ls -1 -- *.cfg 2>/dev/null | sort)" ] || return 1
  for f in "$a"/*.cfg; do [ -f "$f" ] || continue; cmp -s "$f" "$b/${f##*/}" || return 1; done
  return 0
}
same_as_live() {
  local d=$1 sub
  for sub in pools shares; do same_cfgs "$d/$sub" "$CFG/$sub" || return 1; done
  if [ -f "$d/super.dat" ]; then cmp -s "$d/super.dat" "$CFG/super.dat" || return 1; else [ ! -e "$CFG/super.dat" ] || return 1; fi
  if [ -f "$d/custom_smb_shares.json" ]; then cmp -s "$d/custom_smb_shares.json" "$SMBJSON" || return 1
  elif absent "$d" custom_smb_shares.json; then [ ! -e "$SMBJSON" ] || return 1; fi
  return 0
}
# replace the live managed files by the content of <dir>
install_from() {
  local d=$1 f
  verify_dir "$d" || { log "install: '$d' is incomplete or damaged (MANIFEST) - live configuration NOT touched"; return 2; }
  mkdir -p "$CFG/pools" "$CFG/shares" || return 1
  rm -f "$CFG"/pools/*.cfg "$CFG"/shares/*.cfg || return 1
  for f in "$d"/pools/*.cfg;  do [ -f "$f" ] || continue; cpv "$f" "$CFG/pools/${f##*/}"  || return 1; done
  for f in "$d"/shares/*.cfg; do [ -f "$f" ] || continue; cpv "$f" "$CFG/shares/${f##*/}" || return 1; done
  if [ -f "$d/super.dat" ]; then cpv "$d/super.dat" "$CFG/super.dat" || return 1; else rm -f "$CFG/super.dat" || return 1; fi
  if [ -f "$d/custom_smb_shares.json" ]; then mkdir -p "$SMBDIR" && cpv "$d/custom_smb_shares.json" "$SMBJSON" || return 1
  elif absent "$d" custom_smb_shares.json; then rm -f "$SMBJSON" || return 1; fi
  sync
  same_as_live "$d"
}
set_pools() { local f n; for f in "$CFG"/pools/*.cfg; do [ -f "$f" ] || continue; n=$(basename "$f" .cfg); is_global "$n" || echo "$n"; done; }
# shares of the set: everything except shares that live only on a global pool
set_shares() {
  local f p p2 u
  for f in "$CFG"/shares/*.cfg; do [ -f "$f" ] || continue
    p=$(grep -oP '^shareCachePool="\K[^"]*' "$f"); p2=$(grep -oP '^shareCachePool2="\K[^"]*' "$f"); u=$(grep -oP '^shareUseCache="\K[^"]*' "$f")
    if [ -n "$p" ] && is_global "$p" && [ -z "$p2" ] && [ "$u" = only ]; then continue; fi
    basename "$f"
  done
}
# target config in $STAGE: live global pools + global-only shares, plus the set's files (none for "new")
stage() {
  local n=$1 f s
  rm -rf "$STAGE"; mkdir -p "$STAGE/pools" "$STAGE/shares" || return 1
  for f in "$CFG"/pools/*.cfg; do [ -f "$f" ] || continue; is_global "$(basename "$f" .cfg)" && { cpv "$f" "$STAGE/pools/${f##*/}" || return 1; }; done
  local keep; keep=$(comm -23 <(cd "$CFG/shares" 2>/dev/null && ls -1 -- *.cfg 2>/dev/null | sort) <(set_shares | sort))
  for s in $keep; do cpv "$CFG/shares/$s" "$STAGE/shares/$s" || return 1; done
  if [ "$n" != new ]; then
    for f in "$PROF/$n"/pools/*.cfg; do [ -f "$f" ] || continue; cpv "$f" "$STAGE/pools/${f##*/}" || return 1; done
    for f in "$PROF/$n"/shares/*.cfg; do [ -f "$f" ] || continue
      [ -e "$STAGE/shares/${f##*/}" ] && { echo "share ${f##*/} exists globally and in set '$n'"; return 1; }
      cpv "$f" "$STAGE/shares/${f##*/}" || return 1
    done
    [ -f "$PROF/$n/super.dat" ] && { cpv "$PROF/$n/super.dat" "$STAGE/super.dat" || return 1; }
  fi
  # SMB list: the set's own list; a set without one (or a new set) gets an EMPTY list, never the previous set's exports
  if [ -d "$SMBDIR" ]; then
    if [ "$n" != new ] && [ -f "$PROF/$n/custom_smb_shares.json" ]; then cpv "$PROF/$n/custom_smb_shares.json" "$STAGE/custom_smb_shares.json" || return 1
    else echo "[]" > "$STAGE/custom_smb_shares.json" || return 1; fi
  fi
  write_manifest "$STAGE"
}
write_last_boot() { printf 'time=%s\nresult=%s\ntarget=%s\nauto=%s\nreason=%s\n' "$(date '+%F %T')" "$1" "$2" "$3" "$4" > "$LASTBOOT"; }

# ---------------------------------------------------------------- boot (phase 2)
# roll back an interrupted swap from the backup named in the journal
recover() {
  local b phase t; b=$(grep -oP '^backup=\K.*' "$JOURNAL"); phase=$(grep -oP '^phase=\K.*' "$JOURNAL"); t=$(grep -oP '^target=\K.*' "$JOURNAL")
  autostart_off "interrupted switch to '$t'" || log "boot: WARNING autostart hold not confirmed"
  if [ "$phase" = swap ]; then
    if [ -d "$b" ] && install_from "$b"; then log "boot: interrupted switch to '$t' rolled back from $b"
    else log "boot: ROLLBACK FAILED from '$b' - journal kept, check $CFG manually"; write_last_boot rollback_failed "$t" no "rollback from $b failed"; return 1; fi
  else
    log "boot: switch to '$t' was interrupted before the swap ($phase) - live config untouched"
  fi
  rm -f "$JOURNAL"; rm -rf "$STAGE"
  write_last_boot recovered "$t" no "an interrupted switch to '$t' was rolled back; it is tried again at the next boot"
}
apply_set() {
  local n=$1 b
  autostart_off "applying '$n'" || { write_last_boot hold "$n" "$AUTO" "autostart hold could not be confirmed"; log "boot: autostart hold not confirmed - '$n' NOT applied"; return 1; }
  b=$BAK/$(date +%Y%m%d_%H%M%S)_before_$n
  set_phase() { printf 'target=%s\nbackup=%s\nphase=%s\n' "$n" "$b" "$1" > "$JOURNAL.tmp" && sync && mv "$JOURNAL.tmp" "$JOURNAL" && sync \
                && [ "$(grep -oP '^phase=\K.*' "$JOURNAL")" = "$1" ]; }
  set_phase backup || { rm -f "$JOURNAL" "$JOURNAL.tmp"; write_last_boot hold "$n" "$AUTO" "journal could not be written"; log "boot: journal not writable - '$n' NOT applied"; return 1; }
  if ! snapshot "$CFG" "$b" || ! same_as_live "$b"; then
    rm -f "$JOURNAL"; write_last_boot hold "$n" "$AUTO" "backup of the current configuration failed"; log "boot: backup failed - '$n' NOT applied"; return 1
  fi
  set_phase stage || { rm -f "$JOURNAL"; write_last_boot hold "$n" "$AUTO" "journal could not be written"; log "boot: journal not writable - '$n' NOT applied"; return 1; }
  local msg; if ! msg=$(stage "$n"); then
    rm -f "$JOURNAL"; rm -rf "$STAGE"; write_last_boot hold "$n" "$AUTO" "staging failed: $msg"; log "boot: staging failed ($msg) - '$n' NOT applied"; return 1
  fi
  set_phase swap || { rm -f "$JOURNAL"; rm -rf "$STAGE"; write_last_boot hold "$n" "$AUTO" "journal could not be written"; log "boot: journal not writable - '$n' NOT applied"; return 1; }
  if ! install_from "$STAGE"; then
    log "boot: swap to '$n' failed - rolling back"
    if install_from "$b"; then rm -f "$JOURNAL"; write_last_boot hold "$n" "$AUTO" "swap failed, previous configuration restored"
    else write_last_boot rollback_failed "$n" "$AUTO" "swap failed and rollback from $b failed"; fi
    return 1
  fi
  # publish
  local nn=""
  if [ "$n" = new ]; then nn=$(cat "$BASE/newname" 2>/dev/null); rm -f "$BASE/newname"
    if [ -n "$nn" ]; then echo "$nn" > "$BASE/active"; else rm -f "$BASE/active"; fi
  else echo "$n" > "$BASE/active"; fi
  rm -f "$BASE/pending" "$JOURNAL"; rm -rf "$STAGE"; sync
  [ "$n" = new ] || autostart_restore
  write_last_boot applied "${nn:-$n}" "$AUTO" "$REASON"
  log "boot: applied set '$n'${nn:+ as '$nn'}$([ "$AUTO" = yes ] && echo ' (detected)') (backup: $b)"
}
cmd_boot() {
  if [ "${1:-}" = --dry-run ]; then cmd_plan; return 0; fi
  STABLE=yes; settle || STABLE=no
  decide
  log "boot: decision=$DECISION target=${TARGET:-<none>} auto=$AUTO - $REASON"
  case "$DECISION" in
    recover) recover; return ;;
    apply)   apply_set "$TARGET"; return ;;
    keep)    autostart_restore; write_last_boot keep "$TARGET" no "$REASON" ;;
    hold)    autostart_off "$REASON" || { log "boot: WARNING autostart hold not confirmed"; write_last_boot hold "$TARGET" "$AUTO" "$REASON (autostart hold NOT confirmed)"; return 1; }
             write_last_boot hold "$TARGET" "$AUTO" "$REASON" ;;
    none)    write_last_boot none "" no "$REASON" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- commands (array running / stopped, emhttp up)
# disk ids of the live configuration - only valid while emhttp is up (disks.ini)
current_ids() {
  [ -f "$DISKS" ] || return 1
  local f
  for f in "$CFG"/pools/*.cfg; do [ -f "$f" ] || continue
    is_global "$(basename "$f" .cfg)" && continue
    grep -oP '^diskId(\.\d+)?="\K[^"]+' "$f"
  done
  awk -F'"' '/^type=/{t=$2} /^id=/{ if ((t=="Data"||t=="Parity") && $2!="") print $2 }' "$DISKS"
}
cmd_save() {
  local n=${1:-$(active)}; [ -n "$n" ] || die "no set name given and no active set"; valid_name "$n"; [ "$n" = new ] && die "'new' is reserved"
  [ -f "$DISKS" ] || die "array inventory unavailable (emhttp not running) - nothing saved"
  local ids; ids=$(current_ids | sort -u); [ -n "$ids" ] || die "no disks in the current set - nothing saved"
  local d=$PROF/$n tmp; tmp=$(mktemp -d "$BASE/.save.XXXX") || die "mktemp"
  mkdir -p "$tmp/pools" "$tmp/shares"
  local p s ok=1
  for p in $(set_pools); do cpv "$CFG/pools/$p.cfg" "$tmp/pools/$p.cfg" || ok=0; done
  for s in $(set_shares); do cpv "$CFG/shares/$s" "$tmp/shares/$s" || ok=0; done
  [ -f "$CFG/super.dat" ] && { cpv "$CFG/super.dat" "$tmp/super.dat" || ok=0; }
  [ -f "$SMBJSON" ] && { cpv "$SMBJSON" "$tmp/custom_smb_shares.json" || ok=0; }
  echo "$ids" > "$tmp/disks.txt"; date '+%F %T' > "$tmp/saved"; sync
  [ "$ok" = 1 ] || { rm -rf "$tmp"; die "copy failed - set '$n' NOT saved (old profile kept)"; }
  if [ -d "$d" ]; then mv "$d" "$BAK/$(date +%Y%m%d_%H%M%S)_profile_$n" || { rm -rf "$tmp"; die "could not move the old profile"; }; fi
  mv "$tmp" "$d" || die "could not publish the profile"
  echo "$n" > "$BASE/active"; sync
  log "saved set '$n' ($(grep -c . "$d/disks.txt") disks, pools: $(ls "$d/pools" | sed 's/\.cfg$//' | tr '\n' ' '))"
}
cmd_switch() {
  local n=${1:-} nn=${2:-}; valid_name "$n"; [ -d "$PROF/$n" ] || [ "$n" = "new" ] || die "unknown set '$n' (see: list)"
  if [ "$n" = new ]; then
    [ -n "$nn" ] || die "usage: switch new <name of the new set>"; valid_name "$nn"
    [ "$nn" = new ] && die "'new' is reserved"; [ -e "$PROF/$nn" ] && die "set '$nn' already exists"
  else manifest "$n" >/dev/null || die "set '$n' has no valid manifest (disks.txt)"; fi
  [ "$(md_state)" = STOPPED ] || die "array must be stopped"
  [ "$n" = "$(active)" ] && die "'$n' is already active"
  if [ -n "$(active)" ]; then cmd_save "$(active)"; else die "current set has no name - run: save <name> first"; fi
  echo "$n" > "$BASE/pending"; if [ "$n" = new ]; then echo "$nn" > "$BASE/newname"; else rm -f "$BASE/newname"; fi
  log "pending set '$n'${nn:+ (new set '$nn')} - swap the disks now; it is applied at the next boot (array autostart is held off until the disks match)"
}
# After emhttp is up: do the installed disks match the configured set? exit 1 + message if not.
cmd_check() {
  [ -f "$DISKS" ] || { echo "OK: array inventory unavailable, nothing to check"; return 0; }
  local want miss det; want=$(current_ids | sort -u)
  [ -z "$want" ] && { echo "OK: no disk set configured"; return 0; }
  INV=$(inventory)
  miss=$(comm -23 <(echo "$want") <(awk '{print $1}' <<< "$INV" | sort -u) | grep -c .)
  [ "$miss" -eq 0 ] && { echo "OK: all $(echo "$want" | grep -c .) disks of set '$(active)' are installed"; return 0; }
  det=$(detect_exact) || det=""
  echo "MISMATCH: $miss disk(s) of the configured set '$(active)' are missing.${det:+ The installed disks are exactly saved set '$det' - use switch $det and reboot.} Do NOT format anything."
  return 1
}
cmd_status() {
  INV=$(inventory)
  echo "Array state : $(md_state || echo unknown)"
  echo "Autostart   : $(autostart_get)$([ -f "$BASE/autostart" ] && echo " (held off by AADAS, restores to '$(cat "$BASE/autostart")' when the disks match a saved set)")"
  echo "Global pools: ${GLOBAL_POOLS:-<none>}"
  echo "Detect boot : ${AUTO_DETECT:-no}"
  echo "Save on stop: ${SAVE_ON_STOP:-yes}"
  echo "Active set  : $(active || true)"; echo "Pending set : $(pending || true)$([ "$(pending)" = new ] && echo " (name: $(cat "$BASE/newname" 2>/dev/null))")"
  echo "Autosave    : ${AUTOSAVE:-off} (keeps ${KEEP_BACKUPS:-20} backups)"
  echo "Set pools   : $(set_pools | tr '\n' ' ')"
  echo "Set shares  : $(set_shares | sed 's/\.cfg$//' | tr '\n' ' ')"
  [ -f "$SMBJSON" ] && echo "SMB shares  : $(tr -d '\n' < "$SMBJSON" | grep -oP '"name":\s*"\K[^"]+(?="[^}]*"enabled":\s*true)' | tr '\n' ' ')(Custom SMB Shares, switched with the set)"
  echo "Detected    : $(detect_exact || echo '<no saved set is installed exactly>')"
  [ -f "$LASTBOOT" ] && echo "Last boot   : $(grep -oP '^result=\K.*' "$LASTBOOT") $(grep -oP '^target=\K.*' "$LASTBOOT") - $(grep -oP '^reason=\K.*' "$LASTBOOT") ($(grep -oP '^time=\K.*' "$LASTBOOT"))"
  [ -f "$JOURNAL" ] && echo "JOURNAL     : an interrupted switch is recorded - it is rolled back at the next boot"
  return 0
}
cmd_list() {
  INV=$(inventory); local n m tot miss man; man=$(managed_ids)
  for n in $(profiles); do
    if m=$(manifest "$n"); then
      tot=$(echo "$m" | grep -c .); miss=$(comm -23 <(echo "$m") <(awk '{print $1}' <<< "$INV" | sort -u) | grep -c .)
      printf '%-16s %2d disks, %2d missing  saved %s%s%s\n' "$n" "$tot" "$miss" "$(cat "$PROF/$n/saved" 2>/dev/null)" \
        "$([ "$m" = "$man" ] && echo '  [installed]')" "$([ "$n" = "$(active)" ] && echo '  [active]')"
    else printf '%-16s INVALID (disks.txt missing or empty)%s\n' "$n" "$([ "$n" = "$(active)" ] && echo '  [active]')"; fi
  done
}
cmd_rename() {
  local o=${1:-} n=${2:-}; valid_name "$o"; valid_name "$n"; [ "$n" = new ] && die "'new' is reserved"
  [ -d "$PROF/$o" ] || die "unknown set '$o'"; [ -e "$PROF/$n" ] && die "set '$n' already exists"
  mv "$PROF/$o" "$PROF/$n" || die "rename failed"
  [ "$(active)" = "$o" ] && echo "$n" > "$BASE/active"; [ "$(pending)" = "$o" ] && echo "$n" > "$BASE/pending"
  log "renamed set '$o' -> '$n'"
}
cmd_delete() {
  local n=${1:-}; valid_name "$n"; [ -d "$PROF/$n" ] || die "unknown set '$n'"
  [ "$n" = "$(active)" ] && die "'$n' is the active set - it cannot be deleted"
  [ "$n" = "$(pending)" ] && die "'$n' is pending - it cannot be deleted"
  mv "$PROF/$n" "$BAK/$(date +%Y%m%d_%H%M%S)_deleted_$n" || die "delete failed"; log "deleted set '$n' (moved to backups)"
}
# keep the newest KEEP_BACKUPS backups; "before_" snapshots of the last apply are never pruned
prune() {
  local k=${KEEP_BACKUPS:-20} last; last=$(ls -1d "$BAK"/*_before_* 2>/dev/null | sort | tail -1)
  find "$BAK" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r | tail -n +$((k+1)) \
    | while IFS= read -r b; do [ "$BAK/$b" = "$last" ] && continue; rm -rf "${BAK:?}/$b"; done
}
# save of the active set - only if the installed disks are exactly its manifest and the configuration still names
# the same disks (a changed set is saved by hand, never automatically)
cmd_autosave() {
  local a; a=$(active); [ -n "$a" ] || { log "autosave: no active set"; return 0; }
  local m ids; m=$(manifest "$a") || { log "autosave: '$a' has no valid manifest - skipped"; return 0; }
  [ -f "$DISKS" ] || { log "autosave: array inventory unavailable - skipped"; return 0; }
  ids=$(current_ids | sort -u)
  [ "$ids" = "$m" ] || { log "autosave: the configured disks differ from the manifest of '$a' - skipped (save by hand)"; return 0; }
  INV=$(inventory); [ "$(managed_ids)" = "$m" ] || { log "autosave: installed disks are not exactly '$a' - skipped"; return 0; }
  cmd_save "$a" >/dev/null && log "autosave${1:+ ($1)}: saved '$a'" && prune
}
cmd_schedule() {
  local w=${1:-}; local cron=$CFG/plugins/aadas/aadas.cron line
  case "$w" in
    off)    line="" ;;
    daily)  line="15 3 * * * bash /boot/config/aadas/aadas.sh autosave >> /boot/config/aadas/aadas.log 2>&1" ;;
    weekly) line="15 3 * * 0 bash /boot/config/aadas/aadas.sh autosave >> /boot/config/aadas/aadas.log 2>&1" ;;
    *) die "schedule must be off, daily or weekly" ;;
  esac
  mkdir -p "$(dirname "$cron")"
  if [ -n "$line" ]; then printf '# AADAS autosave (%s)\n%s\n' "$w" "$line" > "$cron"; else rm -f "$cron"; fi
  setting AUTOSAVE "$w"
  [ -x /usr/local/sbin/update_cron ] && /usr/local/sbin/update_cron
  log "autosave schedule: $w"
}
setting() {   # <KEY> <value> in global.cfg
  if grep -q "^$1=" "$GLOBALCFG" 2>/dev/null; then sed -i "s/^$1=.*/$1=\"$2\"/" "$GLOBALCFG"; else echo "$1=\"$2\"" >> "$GLOBALCFG"; fi
}
cmd_set() {
  local k=${1:-} v=${2:-}
  case "$k" in
    detect)        [[ "$v" =~ ^(yes|no)$ ]] || die "detect must be yes or no"; setting AUTO_DETECT "$v"; log "detect at boot: $v" ;;
    save_on_stop)  [[ "$v" =~ ^(yes|no)$ ]] || die "save_on_stop must be yes or no"; setting SAVE_ON_STOP "$v"; log "save on array stop: $v" ;;
    *) die "usage: set detect|save_on_stop yes|no" ;;
  esac
}
cmd_stopped() { [ "${SAVE_ON_STOP:-yes}" = yes ] && cmd_autosave "array stopped"; return 0; }

# ---------------------------------------------------------------- main
CMD=${1:-status}
case "$CMD" in
  status|list|detect|check|plan) RO=1 ;;
  boot) [ "${2:-}" = --dry-run ] && RO=1 || RO=0 ;;
  *) RO=0 ;;
esac
if [ "$RO" = 0 ]; then
  mkdir -p "$PROF" "$BAK" 2>/dev/null
  exec 9>"$BASE/.lock" && { flock -w 30 9 || die "another AADAS action is running"; }
fi
case "$CMD" in
  status) cmd_status ;; list) cmd_list ;; plan) cmd_plan ;;
  detect) INV=$(inventory); detect_exact ;; check) cmd_check ;;
  save) cmd_save "${2:-}" ;; switch) cmd_switch "${2:-}" "${3:-}" ;; boot) cmd_boot "${2:-}" ;;
  rename) cmd_rename "${2:-}" "${3:-}" ;; delete) cmd_delete "${2:-}" ;;
  autosave) cmd_autosave ;; stopped) cmd_stopped ;; schedule) cmd_schedule "${2:-}" ;; set) cmd_set "${2:-}" "${3:-}" ;;
  *) echo "usage: $0 status|list|plan|detect|check|save [name]|switch <name>|switch new <name>|boot [--dry-run]|rename <old> <new>|delete <name>|autosave|stopped|schedule off|daily|weekly|set detect|save_on_stop yes|no"; exit 2 ;;
esac
