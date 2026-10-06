#!/usr/bin/env python3
"""Stage runtime resources once, preserving SwiftPM bundles and train artwork."""
import argparse
from pathlib import Path
import shutil


def stage_resources(build_dir, app_dir, icon):
    bundles = sorted(build_dir.glob("*.bundle"))
    required = {"Pasta_PastaApp.bundle", "Pasta_PastaCore.bundle"}
    if not required.issubset({bundle.name for bundle in bundles}):
        raise ValueError(f"Missing required SwiftPM resource bundles in {build_dir}")
    if not icon.is_file():
        raise ValueError(f"Missing app icon: {icon}")
    resources = app_dir / "Contents" / "Resources"
    resources.mkdir(parents=True, exist_ok=True)
    for bundle in bundles:
        destination = resources / bundle.name
        if destination.exists():
            shutil.rmtree(destination)
        if bundle.name == "Pasta_PastaApp.bundle":
            shutil.copytree(bundle, destination, ignore=shutil.ignore_patterns("Assets.xcassets"))
            # The installed app uses AppIcon.icns; retain a matching PNG fallback.
            selected = "AppIconAlpha.png" if icon.stem == "AppIconAlpha" else "AppIcon.png"
            shutil.copyfile(bundle / selected, destination / "AppIcon.png")
            (destination / "AppIconAlpha.png").unlink(missing_ok=True)
        else:
            shutil.copytree(bundle, destination)
    shutil.copyfile(icon, resources / "AppIcon.icns")
    print(f"Staged {len(bundles)} resource bundles and {icon.name} in {resources}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_dir", type=Path)
    parser.add_argument("app_dir", type=Path)
    parser.add_argument("icon", type=Path)
    args = parser.parse_args()
    stage_resources(args.build_dir, args.app_dir, args.icon)
