#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-jhewes@192.168.0.125}"

echo "Adding the Sunshine Sleep shortcut on ${HOST}"
echo "SSH may ask for the Bazzite account password."

ssh -T "${HOST}" 'python3 -' <<'REMOTE_PYTHON'
from __future__ import annotations

import copy
import datetime
import json
import os
import pathlib
import shutil
import subprocess
import sys


home = pathlib.Path.home()
candidates = [
    home / ".config" / "sunshine" / "apps.json",
    home / ".local" / "share" / "sunshine" / "apps.json",
]

config = home / ".config" / "sunshine" / "sunshine.conf"
if config.is_file():
    for raw_line in config.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if key == "file_apps" and value:
            path = pathlib.Path(os.path.expandvars(os.path.expanduser(value)))
            candidates.insert(0, path)


def command_text(app: dict) -> str:
    values: list[str] = []
    for key in ("cmd", "detached", "prep-cmd"):
        value = app.get(key)
        if isinstance(value, str):
            values.append(value)
        elif isinstance(value, list):
            values.extend(json.dumps(item) for item in value)
    return " ".join(values).casefold()


apps_path: pathlib.Path | None = None
document: dict | None = None
shutdown_index: int | None = None

for candidate in dict.fromkeys(candidates):
    if not candidate.is_file():
        continue
    try:
        parsed = json.loads(candidate.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        continue
    apps = parsed.get("apps")
    if not isinstance(apps, list):
        continue
    for index, app in enumerate(apps):
        if not isinstance(app, dict):
            continue
        name = str(app.get("name", "")).casefold()
        commands = command_text(app)
        if any(marker in name for marker in ("shutdown", "shut down", "power off", "poweroff")) or any(
            marker in commands
            for marker in ("systemctl poweroff", "poweroff", "shutdown -h", "shutdown now")
        ):
            apps_path = candidate
            document = parsed
            shutdown_index = index
            break
    if document is not None:
        break

if document is None or apps_path is None or shutdown_index is None:
    print("Could not find the existing Shutdown shortcut in Sunshine's apps.json.", file=sys.stderr)
    print("Checked:", file=sys.stderr)
    for candidate in dict.fromkeys(candidates):
        if not candidate.is_file():
            print(f"  {candidate} (missing)", file=sys.stderr)
            continue
        print(f"  {candidate}", file=sys.stderr)
        try:
            parsed = json.loads(candidate.read_text(encoding="utf-8"))
            names = [
                str(app.get("name", "<unnamed>"))
                for app in parsed.get("apps", [])
                if isinstance(app, dict)
            ]
            print(f"    Apps: {', '.join(names) if names else '<none>'}", file=sys.stderr)
        except (OSError, json.JSONDecodeError) as error:
            print(f"    Could not read JSON: {error}", file=sys.stderr)
    sys.exit(1)

apps = document["apps"]
for app in apps:
    if isinstance(app, dict) and str(app.get("name", "")).casefold() == "sleep":
        print(f"Sleep already exists in {apps_path}; nothing changed.")
        sys.exit(0)

shutdown_app = apps[shutdown_index]
sleep_app = copy.deepcopy(shutdown_app)
sleep_app["name"] = "Sleep"
sleep_app.pop("image-path", None)


def suspend_command(command: str) -> str:
    replacements = (
        ("systemctl --no-wall poweroff", "systemctl --no-wall suspend"),
        ("systemctl poweroff", "systemctl suspend"),
        ("loginctl poweroff", "loginctl suspend"),
        ("shutdown -h now", "systemctl suspend"),
        ("shutdown now", "systemctl suspend"),
        ("poweroff", "systemctl suspend"),
    )
    for old, new in replacements:
        if old in command:
            return command.replace(old, new)
    return command


changed_commands = 0
for key in ("cmd", "detached"):
    value = sleep_app.get(key)
    if isinstance(value, str):
        updated = suspend_command(value)
        changed_commands += updated != value
        sleep_app[key] = updated
    elif isinstance(value, list):
        updated_values = []
        for item in value:
            if isinstance(item, str):
                updated = suspend_command(item)
                changed_commands += updated != item
                updated_values.append(updated)
            else:
                updated_values.append(item)
        sleep_app[key] = updated_values

prep_commands = sleep_app.get("prep-cmd")
if isinstance(prep_commands, list):
    for prep in prep_commands:
        if not isinstance(prep, dict):
            continue
        for key in ("do", "undo"):
            value = prep.get(key)
            if isinstance(value, str):
                updated = suspend_command(value)
                changed_commands += updated != value
                prep[key] = updated

if changed_commands == 0:
    shutdown_helper_value = shutdown_app.get("cmd")
    shutdown_helper = (
        pathlib.Path(shutdown_helper_value)
        if isinstance(shutdown_helper_value, str) and shutdown_helper_value.startswith("/")
        else None
    )
    helper_name = shutdown_helper.name.casefold() if shutdown_helper is not None else ""
    if (
        shutdown_helper is None
        or not shutdown_helper.is_file()
        or not any(marker in helper_name for marker in ("shutdown", "poweroff", "power-off"))
    ):
        print("The Shutdown shortcut uses an unrecognised command, so no change was made.", file=sys.stderr)
        print(json.dumps(shutdown_app, indent=2), file=sys.stderr)
        sys.exit(1)

    helper_source = shutdown_helper.read_text(encoding="utf-8")
    helper_updated = suspend_command(helper_source)
    if helper_updated == helper_source:
        print("The Shutdown helper uses an unrecognised command, so no change was made.", file=sys.stderr)
        print(f"Helper: {shutdown_helper}", file=sys.stderr)
        print(helper_source, file=sys.stderr)
        sys.exit(1)

    sleep_helper_name = shutdown_helper.name
    for marker in ("shutdown", "poweroff", "power-off"):
        sleep_helper_name = sleep_helper_name.replace(marker, "sleep")
    sleep_helper = shutdown_helper.with_name(sleep_helper_name)
    if sleep_helper.exists():
        existing = sleep_helper.read_text(encoding="utf-8")
        if existing != helper_updated:
            print(f"Refusing to overwrite the existing, different helper: {sleep_helper}", file=sys.stderr)
            sys.exit(1)
    else:
        shutil.copy2(shutdown_helper, sleep_helper)
        sleep_helper.write_text(helper_updated, encoding="utf-8")

    sleep_app["cmd"] = str(sleep_helper)
    output = sleep_app.get("output")
    if isinstance(output, str):
        for marker in ("shutdown", "poweroff", "power-off"):
            output = output.replace(marker, "sleep")
        sleep_app["output"] = output
    changed_commands += 1
    print(f"Created Sleep helper: {sleep_helper}")

apps.insert(shutdown_index, sleep_app)

stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup = apps_path.with_name(f"{apps_path.name}.pre-sleep-{stamp}")
shutil.copy2(apps_path, backup)

temporary = apps_path.with_name(f".{apps_path.name}.sleep.tmp")
temporary.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
temporary.replace(apps_path)

print(f"Added Sleep to {apps_path}")
print(f"Backup: {backup}")
print("Sleep command:")
print(json.dumps(sleep_app, indent=2))

services = ("sunshine-pyrowave.service", "sunshine.service")
for service in services:
    active = subprocess.run(
        ["systemctl", "--user", "is-active", "--quiet", service],
        check=False,
    )
    if active.returncode == 0:
        subprocess.run(["systemctl", "--user", "restart", service], check=True)
        print(f"Restarted {service}")
        break
else:
    print("No active Sunshine user service was found; restart Sunshine before using Sleep.")
REMOTE_PYTHON
