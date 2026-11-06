import pathlib,subprocess,os,plistlib,tempfile,shlex,json,hashlib,shutil
root=pathlib.Path(__file__).resolve().parents[2];os.chdir(root)
obj=root/'build/app-store/DerivedData/Build/Intermediates.noindex/ArchiveIntermediates/Shotloom/IntermediateBuildFilesPath/Shotloom.build/Release/Shotloom.build/Objects-normal/arm64'
files=[str(p) for p in sorted(obj.glob('*.o')) if p.name not in ('main.o','WorkflowAppIntents.o')]
bundle=root/'build/ShotloomRecordingMaterials.app';binary=bundle/'Contents/MacOS';binary.mkdir(parents=True,exist_ok=True)
(bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='app.monoware.shotloom.recording-materials',CFBundleName='Shotloom Recording Materials',CFBundleDisplayName='Shotloom',CFBundleExecutable='StoreMaterials',CFBundlePackageType='APPL',LSUIElement=True)))
sources=[str(p) for p in sorted((root/'Sources/DeskCapture').glob('*.swift')) if p.name not in ('main.swift','WorkflowAppIntents.swift')]
sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
cache=root/'build/app-store/materials-objects';cache.mkdir(exist_ok=True)
view_copy=cache/'Views.swift'
view_text=(root/'Sources/DeskCapture/Views.swift').read_text()+'\n'+(root/'scripts/store-materials/EditorScreenshotState.swift.txt').read_text()
if not view_copy.exists() or view_copy.read_text()!=view_text: view_copy.write_text(view_text)
sources=[str(view_copy) if p.endswith('/Views.swift') else p for p in sources]
all_sources=['scripts/store-materials/RecordingScreenshots.swift',*sources]
mapping={x:{'object':str(cache/(hashlib.sha256(x.encode()).hexdigest()+'.o')),'swift-dependencies':str(cache/(hashlib.sha256(x.encode()).hexdigest()+'.swiftdeps'))} for x in all_sources}
mapping['']={'swift-dependencies':str(cache/'master.swiftdeps')}
mapfile=cache/'output-map.json';mapfile.write_text(json.dumps(mapping))
subprocess.run(['swiftc','-Xfrontend','-disable-access-control','-incremental','-enable-batch-mode','-output-file-map',str(mapfile),'-parse-as-library' ,'-swift-version','5','-DAPP_STORE','-module-name','ShotloomStoreMaterials','-sdk',sdk,'-target','arm64-apple-macos15.0','scripts/store-materials/RecordingScreenshots.swift',*sources,'-o',str(binary/'RenderEngine')],check=True)

home=tempfile.mkdtemp(prefix='deskcapture-ui-store-',dir='/tmp')
launcher=binary/'StoreMaterials';launcher.write_text('#!/bin/zsh\nexport CFFIXED_USER_HOME='+shlex.quote(home)+'\nexport DESKCAPTURE_DIAGNOSTIC_DIR='+shlex.quote(home)+'\nexec '+shlex.quote(str(binary/'RenderEngine'))+' "$@"\n');launcher.chmod(0o755)
resources=bundle/'Contents/Resources';resources.mkdir(exist_ok=True)
for language in ('en','zh-Hans'):
    shutil.copytree(root/'Sources/DeskCapture/Resources'/f'{language}.lproj',resources/f'{language}.lproj',dirs_exist_ok=True)
print(bundle)
