#!/usr/bin/env python3
"""Local Disk Sets fixtures. Run with --self-test or a reviewed script path."""

import argparse
from collections import defaultdict
import os
import shlex
from pathlib import Path
import subprocess
import tempfile


def run_isolated(root, command, script=None):
    args = [
        "bwrap", "--unshare-all", "--die-with-parent", "--clearenv",
        "--setenv", "PATH", "/usr/bin:/bin", "--setenv", "LC_ALL", "C",
        "--ro-bind", "/usr", "/usr", "--symlink", "usr/bin", "/bin",
        "--dir", "/etc/alternatives", "--symlink", str(Path("/usr/bin/awk").resolve()),
        "/etc/alternatives/awk",
        "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
        "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
        "--bind", str(root), "/fixture", "--chdir", "/fixture",
        "--setenv", "AADAS_ROOT", "/fixture",
        "--setenv", "AADAS_BYID", "/fixture/by-id",
        "--setenv", "AADAS_EMHTTP", "/fixture/emhttp",
        "--setenv", "AADAS_FLASHDEV", "sda",
        "--setenv", "AADAS_SETTLE", "0",
    ]
    if script is not None:
        args += ["--ro-bind", str(script), "/candidate.sh"]
    return subprocess.run(args + ["--", "/bin/bash", *command],
                          capture_output=True, text=True, timeout=30)


def add_profile(cfg, name, ids):
    profile = cfg / "aadas" / "profiles" / name
    (profile / "pools").mkdir(parents=True)
    (profile / "shares").mkdir()
    (profile / "disks.txt").write_text("".join(f"{disk}\n" for disk in ids))
    if ids:
        (profile / "pools" / "fixturepool.cfg").write_text(f'diskId="{ids[0]}"\n')


def make_fixture(root, installed):
    cfg = root / "boot" / "config"
    add_profile(cfg, "OLD", ("FIXTURE_A",))
    add_profile(cfg, "TARGET", ("FIXTURE_B",))
    base = cfg / "aadas"
    (base / "global.cfg").write_text(
        'AUTO_DETECT="yes"\nGLOBAL_POOLS="ssd"\nIGNORE_IDS="FIXTURE_AUX"\n')
    (base / "active").write_text("OLD\n")
    (cfg / "pools").mkdir()
    (cfg / "shares").mkdir()
    (cfg / "pools" / "ssd.cfg").write_text('diskId="FIXTURE_GLOBAL"\n')
    (cfg / "pools" / "fixturepool.cfg").write_text('diskId="FIXTURE_A"\n')
    (cfg / "disk.cfg").write_text('startArray="yes"\n')
    (root / "emhttp").mkdir()
    (root / "devices").mkdir()
    (root / "by-id").mkdir()
    for index, disk in enumerate(("FIXTURE_FLASH-0:0", "FIXTURE_GLOBAL", "FIXTURE_AUX", *installed)):
        device = root / "devices" / ("sd" + chr(ord("a") + index))
        device.touch()
        prefix = "usb" if index == 0 else "ata"
        link_target = f"../devices/{device.name}"
        (root / "by-id" / f"{prefix}-{disk}").symlink_to(link_target)
        (root / "by-id" / f"wwn-0x{index:016x}").symlink_to(link_target)
        if index:
            (root / "by-id" / f"scsi-alias{index}").symlink_to(link_target)
    (root / "devices" / "sda1").touch()
    (root / "by-id" / "usb-FIXTURE_FLASH-0:0-part1").symlink_to("../devices/sda1")
    return cfg


def snapshot(root):
    result = {}
    for path in [root, *root.rglob("*")]:
        if path.is_symlink():
            value = ("link", os.readlink(path))
        elif path.is_dir():
            value = ("dir", path.stat().st_mode)
        else:
            value = ("file", path.stat().st_mode, path.read_bytes())
        st = path.lstat()
        result[path.relative_to(root)] = (value, st.st_mtime_ns, st.st_ctime_ns)
    return result


def run_probe(root, command, script):
    before = snapshot(root)
    completed = run_isolated(root, ["/candidate.sh", *command], script)
    after = snapshot(root)
    if before != after:
        changed = sorted(key for key in before.keys() | after.keys()
                         if before.get(key) != after.get(key))
        raise RuntimeError(f"{command} changed the fixture: {changed}")
    if completed.stderr.startswith("bwrap:"):
        raise RuntimeError(completed.stderr.strip())
    return completed


def check_sandbox(root):
    check = run_isolated(root, ["-ec", f"""
        test ! -e /boot/config
        test ! -e {shlex.quote(str(Path.home()))}
        test ! -e /mnt
        test ! -e /dev/disk/by-id
        test -r "$AADAS_ROOT/boot/config/disk.cfg"
        test -L "$AADAS_BYID/ata-FIXTURE_B"
        test -d "$AADAS_EMHTTP"
        ! touch /usr/.aadas-probe 2>/dev/null
        touch /fixture/isolation-confirmed
    """])
    if check.returncode or not (root / "isolation-confirmed").is_file():
        raise RuntimeError(f"Isolation check failed: {check.stderr.strip()}")


def validate_plan(result, installed, decision, target, automatic):
    if result.returncode:
        raise ValueError(f"exit {result.returncode}: {result.stderr.strip()}")
    if "command not found" in result.stderr:
        raise RuntimeError(result.stderr.strip())
    lines = result.stdout.splitlines()
    fields = defaultdict(list)
    ordered = ["decision", "target", "auto", "autostart", "reason"]
    if [line.partition("=")[0] for line in lines[:5]] != ordered:
        raise ValueError("missing or unordered plan header")
    for line in lines:
        key, sep, value = line.partition("=")
        if not sep or key not in (*ordered, "disk", "extra", "missing"):
            raise ValueError(f"unexpected plan line: {line!r}")
        fields[key].append(value)
    if any(len(fields[key]) != 1 for key in ordered):
        raise ValueError("duplicate header field")
    if fields["decision"] != [decision] or (target is not None and fields["target"] != [target]):
        raise ValueError(f"unexpected decision/target: {lines[:2]!r}")
    if fields["auto"][0] not in ("yes", "no") or (automatic and fields["auto"] != [automatic]):
        raise ValueError(f"unexpected auto field: {fields['auto']}")
    if not fields["reason"][0].strip():
        raise ValueError("missing reason")
    actions = {"hold": ["hold"], "keep": ["restore"], "apply": ["restore", "hold"]}
    if fields["autostart"][0] not in actions[decision]:
        raise ValueError(f"unexpected autostart: {fields['autostart']}")
    disks = {}
    for row in fields["disk"]:
        disk, sep, kind = row.partition(" ")
        if disk in disks or not sep or not kind:
            raise ValueError(f"invalid disk row: {row!r}")
        disks[disk] = kind
    excluded = {"FIXTURE_FLASH-0:0": "flash", "FIXTURE_GLOBAL": "global", "FIXTURE_AUX": "ignored"}
    if set(disks) != set(excluded).union(installed) or any(disks[k] != v for k, v in excluded.items()):
        raise ValueError(f"unexpected device inventory: {disks}")
    for key in installed:
        if key == "FIXTURE_UNKNOWN" and disks[key] != "unknown":
            raise ValueError("unrecognized disk must be reported as unknown")
    if decision != "hold" and (fields["missing"] or fields["extra"]):
        raise ValueError("exact match has unexpected missing or extra devices")
    return fields


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    options = parser.parse_args()
    if options.self_test == (options.candidate is not None):
        parser.error("specify either --self-test or a candidate script")
    if options.self_test:
        with tempfile.TemporaryDirectory(prefix="aadas-plan-") as directory:
            root = Path(directory)
            make_fixture(root, ("FIXTURE_B",))
            check_sandbox(root)
            # Exercise the snapshot guard with both kinds of planner.
            script = root / "probe.sh"
            script.write_text("""cat <<'PLAN'
decision=apply
target=TARGET
auto=yes
autostart=restore
reason=One exact match
disk=FIXTURE_B set:TARGET
disk=FIXTURE_FLASH-0:0 flash
disk=FIXTURE_GLOBAL global
disk=FIXTURE_AUX ignored
PLAN
""")
            result = run_probe(root, ["plan"], script)
            validate_plan(result, ("FIXTURE_B",), "apply", "TARGET", "yes")
            try:
                validate_plan(result, ("FIXTURE_B",), "hold", None, None)
            except ValueError as error:
                if "unexpected decision" not in str(error):
                    raise
            else:
                raise RuntimeError("Wrong plan decision was accepted")
            script.write_text('touch "$AADAS_ROOT/unexpected-write"\n')
            try:
                run_probe(root, ["plan"], script)
            except RuntimeError as error:
                if "unexpected-write" not in str(error):
                    raise
            else:
                raise RuntimeError("Snapshot guard missed a write")
        print("Isolation, contract parser, wrong decision and write detection passed.")
        return
    script = options.candidate.resolve(strict=True)
    cases = [
        ("unique target", ("FIXTURE_B",), "apply", "TARGET", "yes"),
        ("active set", ("FIXTURE_A",), "keep", "OLD", None),
        ("pending exact", ("FIXTURE_B",), "apply", "TARGET", "no"),
        ("pending incomplete", ("FIXTURE_A",), "hold", None, "no"),
        ("target plus unknown disk", ("FIXTURE_B", "FIXTURE_UNKNOWN"), "hold", None, None),
        ("no complete set", (), "hold", None, None),
        ("ambiguous profiles", ("FIXTURE_B",), "hold", None, None),
        ("active among duplicate matches", ("FIXTURE_A",), "hold", None, None),
        ("removed disk with lingering alias", (), "hold", None, None),
        ("target pool collides with global pool", ("FIXTURE_B",), "hold", None, None),
        ("pending profile without manifest", (), "hold", None, "no"),
        ("pending profile empty manifest", (), "hold", None, "no"),
    ]
    failures = []
    for name, installed, decision, target, automatic in cases:
        with tempfile.TemporaryDirectory(prefix="aadas-plan-") as directory:
            root = Path(directory)
            cfg = make_fixture(root, installed)
            if name.startswith("pending"):
                (cfg / "aadas" / "pending").write_text("TARGET\n")
            if name == "ambiguous profiles":
                add_profile(cfg, "DUPLICATE", ("FIXTURE_B",))
            elif name == "active among duplicate matches":
                add_profile(cfg, "DUPLICATE", ("FIXTURE_A",))
            elif name == "removed disk with lingering alias":
                (root / "by-id" / "ata-FIXTURE_B").symlink_to("../devices/disappeared")
            elif name == "target pool collides with global pool":
                (cfg / "aadas/profiles/TARGET/pools/ssd.cfg").write_text('diskId="FIXTURE_B"\n')
            elif name == "pending profile without manifest":
                (cfg / "aadas" / "profiles" / "TARGET" / "disks.txt").unlink()
            elif name == "pending profile empty manifest":
                (cfg / "aadas" / "profiles" / "TARGET" / "disks.txt").write_text("")
            outputs = []
            for cmd in (["plan"], ["boot", "--dry-run"]):
                try:
                    result = run_probe(root, cmd, script)
                    fields = validate_plan(result, installed, decision, target, automatic)
                    if name == "pending incomplete" and "FIXTURE_B" not in fields["missing"]:
                        raise ValueError("missing target device was not reported")
                    outputs.append(result.stdout)
                except (ValueError, RuntimeError) as error:
                    failures.append(f"{name} / {' '.join(cmd)}: {error}")
            if len(outputs) == 2:
                if outputs[0] != outputs[1]:
                    failures.append(f"{name}: plan and dry-run outputs differ")
                else:
                    print(f"PASS {name}")
    if failures:
        raise SystemExit("\n".join(failures))
    print(f"Passed both planner entry points for {len(cases)} inventories.")


if __name__ == "__main__":
    main()
