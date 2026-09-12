#!/usr/bin/env python3
"""Build a self-contained, ad-hoc-signed macOS app using system frameworks."""
import argparse
import plistlib
import shutil
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--debug", action="store_true", help="Build without release optimizations")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
configuration = "debug" if args.debug else "release"
command = ["swift", "build", "-c", configuration, "--product", "FinderDrawer"]
subprocess.run(command, cwd=root, check=True)
binary_dir = Path(subprocess.check_output(
    ["swift", "build", "-c", configuration, "--show-bin-path"], cwd=root, text=True
).strip())
bundle = root / "dist" / "Finder Drawer.app"
macos = bundle / "Contents" / "MacOS"
macos.mkdir(parents=True, exist_ok=True)
shutil.copy2(binary_dir / "FinderDrawer", macos / "FinderDrawer")
with (bundle / "Contents" / "Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "FinderDrawer",
        "CFBundleIdentifier": "com.stevemurr.finder-drawer",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Finder Drawer",
        "CFBundleDisplayName": "Finder Drawer",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSApplicationCategoryType": "public.app-category.utilities",
        "LSMinimumSystemVersion": "15.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }, output)
subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
print(bundle)
