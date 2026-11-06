#!/usr/bin/env python3
"""Link the current product views into a manually operated, isolated design canvas.
Does not build the product, launch an app, capture screenshots or run diagnostics.
"""
import glob
import os
import pathlib
import plistlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
os.chdir(root)
products = subprocess.check_output(["swift", "build", "--show-bin-path", "--disable-automatic-resolution"], text=True).strip()
objects_dir = root / ".build/out/Intermediates.noindex/DeskCapture.build/Debug/DeskCapture-p.build/Objects-normal" / os.uname().machine
objects = [p for p in glob.glob(str(objects_dir / "*.o")) if pathlib.Path(p).name not in ("main.o", "WorkflowAppIntents.o")]
if not objects:
    raise SystemExit("Build the current app first; missing product objects")
bundle = root / "build/ShotloomArtReview.app"
binary_dir = bundle / "Contents/MacOS"
binary_dir.mkdir(parents=True, exist_ok=True)
output = root / "docs/design/2026-10-30/art-direction-20" / os.environ.get("SHOTLOOM_ART_STAGE", "before")
with (bundle / "Contents/Info.plist").open("wb") as stream:
    plistlib.dump({"CFBundleIdentifier": "com.deskcapture.art-review", "CFBundleName": "ShotloomArtReview",
                  "CFBundleDisplayName": "Shotloom", "CFBundleExecutable": "ShotloomArtReview", "CFBundlePackageType": "APPL",
                  "NSHighResolutionCapable": True, "ShotloomArtOutput": str(output)}, stream)
subprocess.run(["swiftc", "-Onone", "-swift-version", "5", "-parse-as-library", "-I", str(objects_dir),
                "-I", products, "-F", products, "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", products,
                "scripts/ArtDirectionReview.swift", *objects, "-o", str(binary_dir / "ShotloomArtReview")], check=True)
resources = bundle / "Contents/Resources"
resources.mkdir(exist_ok=True)
shutil.copytree(pathlib.Path(products) / "DeskCapture_DeskCapture.bundle", resources / "DeskCapture_DeskCapture.bundle", dirs_exist_ok=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
print(bundle)
print("Manual snapshot destination:", output)
