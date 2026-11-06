#!/usr/bin/env python3
"""Build an interactive production video-editor window with isolated generated media.
Does not launch the window or run assertions/diagnostics.
"""
import glob
import os
import plistlib
import shlex
import subprocess
import tempfile

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
products = subprocess.check_output(['swift', 'build', '--show-bin-path'], text=True).strip()
arch = os.uname().machine
obj = os.path.abspath('.build/out/Intermediates.noindex/DeskCapture.build/Debug/DeskCapture-p.build/Objects-normal/' + arch)
objects = [p for p in glob.glob(obj + '/*.o') if os.path.basename(p) not in ('main.o', 'WorkflowAppIntents.o')]
bundle = os.path.abspath('build/DeskCaptureEditingReview.app')
os.makedirs(bundle + '/Contents/MacOS', exist_ok=True)
with open(bundle + '/Contents/Info.plist', 'wb') as f:
    plistlib.dump({'CFBundleIdentifier': 'com.deskcapture.editing-review', 'CFBundleName': 'DeskCaptureEditingReview', 'CFBundleExecutable': 'DeskCaptureEditingReview', 'CFBundlePackageType': 'APPL'}, f)
subprocess.run(['swiftc', '-Onone', '-swift-version', '5', '-parse-as-library', '-I', obj, '-I', products, '-F', products, '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', products, 'scripts/VideoEditingReview.swift'] + objects + ['-o', bundle + '/Contents/MacOS/ReviewEngine'], check=True)
home = tempfile.mkdtemp(prefix='deskcapture-edit-review-', dir='/tmp')
fixture = os.path.abspath('build/video-editor-design-media/编辑演示.mp4')
if not os.path.isfile(fixture):
    raise SystemExit('Missing generated design fixture; never substitute a user recording.')
launcher = bundle + '/Contents/MacOS/DeskCaptureEditingReview'
with open(launcher, 'w') as f:
    f.write('#!/bin/zsh\nexport CFFIXED_USER_HOME=' + shlex.quote(home) + '\nexport DESKCAPTURE_REVIEW_VIDEO=' + shlex.quote(fixture) + '\nexec ' + shlex.quote(bundle + '/Contents/MacOS/ReviewEngine') + '\n')
os.chmod(launcher, 0o755)
print('Interactive review bundle:', bundle)
print('Isolated home:', home)
