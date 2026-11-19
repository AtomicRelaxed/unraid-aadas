#!/usr/bin/env python3
"""Exercise a frozen script in private synthetic Disk Sets fixtures."""
import argparse
import hashlib
from pathlib import Path
import tempfile

from boot_plan_fixtures import make_fixture, run_isolated, run_probe


def require(condition, message):
    if not condition:
        raise ValueError(message)


def capture_config(cfg):
    result = {}
    for path in [*(cfg / "pools").glob("*.cfg"), *(cfg / "shares").glob("*.cfg"),
                 cfg / "super.dat", cfg / "plugins/custom.smb.shares/shares.json"]:
        if path.is_file():
            result[str(path.relative_to(cfg))] = path.read_bytes()
    return result


def check_case(script, scenario, root):
    cfg = make_fixture(root, ("FIXTURE_B",))
    base = cfg / "aadas"
    target = base / "profiles/TARGET"
    (base / "pending").write_text("TARGET\n")
    smb = cfg / "plugins/custom.smb.shares/shares.json"
    smb.parent.mkdir(parents=True)
    smb.write_text('["old export"]\n')
    (cfg / "super.dat").write_bytes(b"old slot assignment")
    (target / "super.dat").write_bytes(b"new slot assignment")
    (cfg / "shares/old.cfg").write_text('shareUseCache="no"\n')
    (target / "shares/new.cfg").write_text('shareUseCache="no"\n')
    if scenario == "missing-autostart-setting":
        (cfg / "disk.cfg").write_text('# no startArray value\n')
    recovery = scenario.startswith("recovery-")
    original = capture_config(cfg)
    early = scenario in {"recovery-backup", "recovery-stage"}
    phase = scenario.removeprefix("recovery-") if early else "swap"
    if recovery:
        (base / "journal").write_text(
            f"target=TARGET\nbackup=/fixture/boot/config/aadas/backups/interrupted\nphase={phase}\n")
        backup = base / "backups/interrupted"
        if scenario != "recovery-missing":
            backup.mkdir(parents=True)
        if scenario in {"recovery-complete", "recovery-smb-previously-absent"}:
            if scenario == "recovery-smb-previously-absent":
                del original["plugins/custom.smb.shares/shares.json"]
            for key, data in original.items():
                dest = backup / ("custom_smb_shares.json" if key.endswith("/shares.json") else key)
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(data)
            rows = [f"{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.relative_to(backup)}"
                    for f in sorted(backup.rglob("*")) if f.is_file()]
            if not (backup / "custom_smb_shares.json").exists():
                rows.append("absent custom_smb_shares.json")
            (backup / "MANIFEST").write_text("\n".join([*rows, "complete", ""]))
            (cfg / "super.dat").write_bytes(b"partially switched")
            smb.write_bytes(b'["new export"]\n')
    expected = dict(original)
    expected["super.dat"] = b"new slot assignment"
    expected["pools/fixturepool.cfg"] = (target / "pools/fixturepool.cfg").read_bytes()
    del expected["shares/old.cfg"]
    expected["shares/new.cfg"] = (target / "shares/new.cfg").read_bytes()
    expected["plugins/custom.smb.shares/shares.json"] = b"[]\n"

    preview = run_probe(root, ["plan"], script)
    require(preview.returncode == 0, "preview failed")
    decision = preview.stdout.splitlines()[0]
    allowed = {"decision=recover"} if recovery else {"decision=apply"}
    if scenario == "missing-autostart-setting":
        allowed.add("decision=hold")
    require(decision in allowed, f"unexpected preview {decision}")
    result = run_isolated(root, ["/candidate.sh", "boot"], script)
    live = capture_config(cfg)
    active = (base / "active").read_text().strip()
    if scenario == "complete-switch":
        require(live == expected, "unexpected live configuration")
        require(active == "TARGET" and not (base / "pending").exists(), "wrong published state")
        require(not (base / "journal").exists(), "journal left behind")
        require((cfg / "disk.cfg").read_text().strip() == 'startArray="yes"', "autostart not restored")
        require(result.returncode == 0, "successful boot returned an error")
    elif scenario == "missing-autostart-setting":
        require(live == expected and active == "TARGET", "switch after autostart repair failed")
        require('startArray="no"' in (cfg / "disk.cfg").read_text().splitlines(), "explicit hold missing")
    elif early or scenario in {"recovery-complete", "recovery-smb-previously-absent"}:
        require(live == original, f"rollback content differs: {sorted(k for k in live.keys() | original.keys() if live.get(k) != original.get(k))}")
        require(not (base / "journal").exists() and active == "OLD", "rollback left incorrect state")
        require((base / "pending").read_text().strip() == "TARGET", "pending retry lost")
        require((cfg / "disk.cfg").read_text().strip() == 'startArray="no"', "autostart not held")
        require(result.returncode == 0, "successful recovery returned an error")
    else:
        require(live == original and active == "OLD",
                f"invalid backup changed managed state; removed={sorted(original.keys() - live.keys())}, journal_exists={(base / 'journal').exists()}, rc={result.returncode}")
        require((base / "journal").is_file(), "missing recovery journal")
        require((cfg / "disk.cfg").read_text().strip() == 'startArray="no"', "autostart not held")
        require(result.returncode != 0, "failed rollback returned success to its caller")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--sha256", required=True)
    args = parser.parse_args()
    source = args.candidate.read_bytes()
    require(hashlib.sha256(source).hexdigest() == args.sha256, "candidate digest changed")
    failures = []
    with tempfile.TemporaryDirectory(prefix="aadas-copy-") as directory:
        script = Path(directory) / "candidate.sh"
        script.write_bytes(source)
        for scenario in ("complete-switch", "missing-autostart-setting", "recovery-complete",
                         "recovery-missing", "recovery-empty", "recovery-smb-previously-absent",
                         "recovery-backup", "recovery-stage"):
            with tempfile.TemporaryDirectory(prefix="aadas-apply-") as tmp:
                try:
                    check_case(script, scenario, Path(tmp))
                    print(f"PASS {scenario}")
                except ValueError as exc:
                    failures.append(f"{scenario}: {exc}")
    if failures:
        raise SystemExit("\n".join(failures))


if __name__ == "__main__":
    main()
