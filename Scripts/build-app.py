#!/usr/bin/env python3
"""Build a self-contained, ad-hoc-signed macOS app using system frameworks."""
import argparse
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--debug", action="store_true", help="Build without release optimizations")
parser.add_argument("--build-system", choices=["native", "swiftbuild", "xcode"],
                    help="Override SwiftPM's build engine (use native if the beta engine stalls)")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
configuration = "debug" if args.debug else "release"
build_options = ["--build-system", args.build_system] if args.build_system else []
command = ["swift", "build", *build_options, "-c", configuration, "--product", "FinderDrawer"]
subprocess.run(command, cwd=root, check=True)
binary_dir = Path(subprocess.check_output(
    ["swift", "build", *build_options, "-c", configuration, "--show-bin-path"], cwd=root, text=True
).strip())
bundle = root / "dist" / "Finder Drawer.app"
macos = bundle / "Contents" / "MacOS"
macos.mkdir(parents=True, exist_ok=True)
shutil.copy2(binary_dir / "FinderDrawer", macos / "FinderDrawer")
resources = bundle / "Contents" / "Resources"
resources.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="finder-drawer-icon-") as temporary:
    iconset = Path(temporary) / "FinderDrawer.iconset"
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = str(size * scale)
            suffix = "@2x" if scale == 2 else ""
            subprocess.run([
                "sips", "-z", pixels, pixels,
                str(root / "Assets" / "AppIcon" / "FinderDrawer.png"),
                "--out", str(iconset / f"icon_{size}x{size}{suffix}.png"),
            ], check=True, stdout=subprocess.DEVNULL)
    subprocess.run([
        "iconutil", "-c", "icns", str(iconset),
        "-o", str(resources / "FinderDrawer.icns"),
    ], check=True)
for resource_bundle in binary_dir.glob("*.bundle"):
    destination = resources / resource_bundle.name
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(resource_bundle, destination)
license_file = root / ".build" / "checkouts" / "SwiftTerm" / "LICENSE"
if license_file.exists():
    license_destination = resources / "SwiftTerm-LICENSE.txt"
    license_destination.unlink(missing_ok=True)
    shutil.copy2(license_file, license_destination)
with (bundle / "Contents" / "Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "FinderDrawer",
        "CFBundleIdentifier": "com.stevemurr.finder-drawer",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Finder Drawer",
        "CFBundleDisplayName": "Finder Drawer",
        "CFBundleIconFile": "FinderDrawer.icns",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSApplicationCategoryType": "public.app-category.utilities",
        "LSMinimumSystemVersion": "15.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "NSDocumentsFolderUsageDescription": "Browse, search, and manage files in your Documents folder.",
        "NSDesktopFolderUsageDescription": "Browse, search, and manage files on your Desktop.",
        "NSDownloadsFolderUsageDescription": "Browse, search, and manage files in Downloads.",
        "NSNetworkVolumesUsageDescription": "Browse and manage files on connected network volumes.",
        "NSRemovableVolumesUsageDescription": "Browse and manage files on external drives.",
        "NSPrincipalClass": "NSApplication",
    }, output)
subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
# Let Finder notice metadata and icon changes when rebuilding an existing bundle.
bundle.touch()
print(bundle)
