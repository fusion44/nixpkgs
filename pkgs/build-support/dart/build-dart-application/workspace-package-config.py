import json
import re
import sys
from pathlib import Path

import yaml


def main() -> None:
    with Path("pubspec.yaml").open("r", encoding="utf-8") as f:
        pubspec = yaml.load(f, Loader=yaml.CSafeLoader)
    if not pubspec.get("workspace"):
        return
    with Path(".dart_tool/package_config.json").open("r", encoding="utf-8") as f:
        package_config = json.load(f)

    # sys.argv[1] is a path to a JSON file containing the list of workspace
    # member *package names* to inject (e.g. ["common", "pwa"]).  It is the
    # sole authority on member injection: when the path is /dev/null (the
    # caller did not set workspaceMembers), every member declared in
    # pubspec.yaml is injected, preserving the existing behaviour; an
    # explicit empty list injects none.  Workspace member names never
    # appear in the lock-derived package config, so lock presence cannot
    # be used as a filter signal here.
    members_file = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    allowed_names: set[str] | None = None
    if members_file is not None and members_file.stat().st_size > 0:
        with members_file.open("r", encoding="utf-8") as f:
            raw = json.load(f)
        if raw is not None:
            allowed_names = set(raw)

    existing_package_names = {pkg["name"] for pkg in package_config["packages"]}

    for package_path in pubspec.get("workspace", []):
        with (Path(package_path) / "pubspec.yaml").open("r", encoding="utf-8") as f:
            package_pubspec = yaml.load(f, Loader=yaml.CSafeLoader)
        package_name = package_pubspec["name"]
        if allowed_names is not None and package_name not in allowed_names:
            continue
        m = re.match(
            r"^[ \t]*(\^|>=|>)?[ \t]*([0-9]+\.[0-9]+)\.[0-9]+.*$",
            package_pubspec.get("environment", {}).get("sdk", ""),
        )
        if m:
            languageVersion = m.group(2)
        elif package_pubspec.get("environment", {}).get("sdk") == "any":
            languageVersion = "null"
        else:
            languageVersion = "2.7"
        if package_name not in existing_package_names:
            existing_package_names.add(package_name)
            package_config["packages"].append({
                "name": package_name,
                "rootUri": Path(package_path).resolve().as_uri(),
                "packageUri": "lib/",
                "languageVersion": languageVersion,
            })
    with Path(".dart_tool/package_config.json").open("w", encoding="utf-8") as f:
        json.dump(package_config, f, sort_keys=True, indent=4)


if __name__ == "__main__":
    main()
