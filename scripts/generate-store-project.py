#!/usr/bin/env python3
"""Generate the independent MAS project from current sources, without fetching dependencies."""
import hashlib
import json
import os
import pathlib
import plistlib
import re

root = pathlib.Path(__file__).resolve().parents[1]
store_info_path = root / 'Resources/Info-AppStore.plist'
previous_info = plistlib.loads(store_info_path.read_bytes()) if store_info_path.exists() else {}
store_build = os.environ.get('DESKCAPTURE_STORE_BUILD', str(previous_info.get('CFBundleVersion', '54')))
store_version = str(previous_info.get('CFBundleShortVersionString', '1.0'))
if not re.fullmatch(r'[0-9]+', store_build):
    raise SystemExit('DESKCAPTURE_STORE_BUILD must be numeric')
project = root / 'Shotloom.xcodeproj'
project.mkdir(exist_ok=True)
objects = {}

def ident(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()

def add(key, isa, **fields):
    ref = ident(key)
    objects[ref] = dict(isa=isa, **fields)
    return ref

source_files = []
source_builds = []
for path in sorted((root / 'Sources/DeskCapture').glob('*.swift')):
    rel = str(path.relative_to(root))
    ref = add(rel, 'PBXFileReference', lastKnownFileType='sourcecode.swift', name=path.name, path=rel, sourceTree='SOURCE_ROOT')
    source_files.append(ref)
    source_builds.append(add('build:' + rel, 'PBXBuildFile', fileRef=ref))

resource_files = []
resource_builds = []
for rel, file_type in [('Resources/AppIcon.icns', 'image.icns'),
                       ('Resources/PrivacyInfo.xcprivacy', 'text.xml'),
                       ('Sources/DeskCapture/Resources/WorkflowSample.png', 'image.png')]:
    ref = add(rel, 'PBXFileReference', lastKnownFileType=file_type, name=pathlib.Path(rel).name, path=rel, sourceTree='SOURCE_ROOT')
    resource_files.append(ref)
    resource_builds.append(add('build:' + rel, 'PBXBuildFile', fileRef=ref))

# Native localization groups keep both translations editable in Xcode and copy
# each strings file into its language's .lproj directory in the application.
for filename in ['Localizable.strings', 'InfoPlist.strings']:
    translations = []
    for language in ['en', 'zh-Hans']:
        rel = f'Sources/DeskCapture/Resources/{language}.lproj/{filename}'
        translations.append(add(rel, 'PBXFileReference', lastKnownFileType='text.plist.strings',
                                name=language, path=rel, sourceTree='SOURCE_ROOT'))
    ref = add('localized:' + filename, 'PBXVariantGroup', name=filename,
              children=translations, sourceTree='<group>')
    resource_files.append(ref)
    resource_builds.append(add('build:localized:' + filename, 'PBXBuildFile', fileRef=ref))

configuration_files = []
for rel, file_type in [('Resources/Info-AppStore.plist', 'text.plist.xml'),
                       ('Resources/AppStore.entitlements', 'text.plist.entitlements'),
                       ('Resources/AppStoreHelper.entitlements', 'text.plist.entitlements'),
                       ('Resources/ExportOptions-AppStore.plist', 'text.plist.xml'),
                       ('scripts/embed-store-helpers.sh', 'text.script.sh'),
                       ('scripts/build-relaunch-helper.sh', 'text.script.sh'),
                       ('scripts/helpers/PermissionRelaunch.swift', 'sourcecode.swift'),
                       ('scripts/generate-store-project.py', 'text.script.python'),
                       ('scripts/build-appstore.sh', 'text.script.sh')]:
    configuration_files.append(add(rel, 'PBXFileReference', lastKnownFileType=file_type,
                                   name=pathlib.Path(rel).name, path=rel, sourceTree='SOURCE_ROOT'))
source_group = add('source-group', 'PBXGroup', name='DeskCapture', children=source_files, sourceTree='<group>')
resource_group = add('resource-group', 'PBXGroup', name='Resources', children=resource_files, sourceTree='<group>')
configuration_group = add('configuration-group', 'PBXGroup', name='Configuration', children=configuration_files, sourceTree='<group>')
product = add('product', 'PBXFileReference', explicitFileType='wrapper.application', path='Shotloom.app', sourceTree='BUILT_PRODUCTS_DIR')
products = add('products', 'PBXGroup', name='Products', children=[product], sourceTree='<group>')
main_group = add('main', 'PBXGroup', children=[source_group, resource_group, configuration_group, products], sourceTree='<group>')
sources = add('sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=source_builds, runOnlyForDeploymentPostprocessing=0)
resources = add('resources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=resource_builds, runOnlyForDeploymentPostprocessing=0)
frameworks = add('frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
helpers = add('helpers', 'PBXShellScriptBuildPhase', buildActionMask=2147483647, files=[],
              name='Embed sandboxed local audio helpers', inputPaths=[], outputPaths=[],
              runOnlyForDeploymentPostprocessing=0, shellPath='/bin/zsh',
              shellScript='zsh "$SRCROOT/scripts/embed-store-helpers.sh"\n', alwaysOutOfDate=1)

project_configs = []
target_configs = []
for name in ['Debug', 'Release']:
    project_configs.append(add('project:' + name, 'XCBuildConfiguration', name=name, buildSettings={
        'SDKROOT': 'macosx', 'MACOSX_DEPLOYMENT_TARGET': '15.0', 'CLANG_ENABLE_MODULES': 'YES',
        'SWIFT_VERSION': '5.0', 'SWIFT_STRICT_CONCURRENCY': 'minimal',
        'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if name == 'Debug' else '-O',
        'SWIFT_COMPILATION_MODE': 'singlefile' if name == 'Debug' else 'wholemodule',
        'DEBUG_INFORMATION_FORMAT': 'dwarf' if name == 'Debug' else 'dwarf-with-dsym',
        'ONLY_ACTIVE_ARCH': 'YES', 'ARCHS': 'arm64',
    }))
    target_configs.append(add('target:' + name, 'XCBuildConfiguration', name=name, buildSettings={
        'PRODUCT_NAME': 'Shotloom', 'PRODUCT_MODULE_NAME': 'DeskCapture',
        'PRODUCT_BUNDLE_IDENTIFIER': 'app.monoware.shotloom', 'DEVELOPMENT_TEAM': 'BDVY6CSEUU',
        'CODE_SIGN_STYLE': 'Automatic', 'CODE_SIGN_ENTITLEMENTS': 'Resources/AppStore.entitlements',
        'ENABLE_APP_SANDBOX': 'YES', 'ENABLE_HARDENED_RUNTIME': 'YES',
        'ENABLE_USER_SCRIPT_SANDBOXING': 'NO', 'GENERATE_INFOPLIST_FILE': 'NO',
        'INFOPLIST_FILE': 'Resources/Info-AppStore.plist',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS': '$(inherited) APP_STORE' + (' DEBUG' if name == 'Debug' else ''),
        'COMBINE_HIDPI_IMAGES': 'YES', 'SKIP_INSTALL': 'NO',
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/../Frameworks'],
    }))

project_list = add('project-configs', 'XCConfigurationList', buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
target_list = add('target-configs', 'XCConfigurationList', buildConfigurations=target_configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
target = add('target', 'PBXNativeTarget', buildConfigurationList=target_list,
             buildPhases=[sources, frameworks, resources, helpers], buildRules=[], dependencies=[],
             name='Shotloom', productName='Shotloom', productReference=product, productType='com.apple.product-type.application')
proj = add('project', 'PBXProject', attributes={'LastUpgradeCheck': '2710', 'TargetAttributes': {target: {'DevelopmentTeam': 'BDVY6CSEUU', 'ProvisioningStyle': 'Automatic'}}},
           buildConfigurationList=project_list, compatibilityVersion='Xcode 14.0', developmentRegion='en',
           knownRegions=['zh-Hans', 'en', 'Base'], mainGroup=main_group, productRefGroup=products,
           projectDirPath='', projectRoot='', targets=[target])

def openstep(value, depth=0):
    if isinstance(value, dict):
        return '{\n' + ''.join('\t' * (depth + 1) + json.dumps(k) + ' = ' + openstep(v, depth + 1) + ';\n' for k, v in value.items()) + '\t' * depth + '}'
    if isinstance(value, list):
        return '(' + ', '.join(openstep(v, depth) for v in value) + ')'
    return str(value) if isinstance(value, int) else json.dumps(value)

data = {'archiveVersion': 1, 'classes': {}, 'objectVersion': 56, 'objects': objects, 'rootObject': proj}
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + openstep(data) + '\n')
schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
(schemes / 'Shotloom.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2710" version="1.3">
 <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="NO">
   <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Shotloom.app" BlueprintName="Shotloom" ReferencedContainer="container:Shotloom.xcodeproj"/>
  </BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO">
  <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Shotloom.app" BlueprintName="Shotloom" ReferencedContainer="container:Shotloom.xcodeproj"/></BuildableProductRunnable>
 </LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
  <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Shotloom.app" BlueprintName="Shotloom" ReferencedContainer="container:Shotloom.xcodeproj"/></BuildableProductRunnable>
 </ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')

info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
info.update(CFBundleName='Shotloom', CFBundleDisplayName='Shotloom', CFBundleExecutable='$(EXECUTABLE_NAME)',
            CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)', CFBundleShortVersionString=store_version, CFBundleVersion=store_build,
            LSApplicationCategoryType='public.app-category.utilities', NSHumanReadableCopyright='2026 MonoWare',
            CFBundleDevelopmentRegion='en', CFBundleLocalizations=['en', 'zh-Hans'], CFBundleSupportedPlatforms=['MacOSX'])
# Networking uses Apple's HTTPS implementation; local CryptoKit use is hashing.
# No proprietary or non-exempt encryption is implemented by this app.
info['ITSAppUsesNonExemptEncryption'] = False
info['NSScreenCaptureUsageDescription'] = 'Shotloom captures your selected screen regions, windows and text. Captures and recognized text stay on your Mac.'
for item in info.get('CFBundleDocumentTypes', []):
    item['CFBundleTypeName'] = item['CFBundleTypeName'].replace('DeskCapture', 'Shotloom')
    item['LSHandlerRank'] = 'Owner'
for item in info.get('UTExportedTypeDeclarations', []):
    item['UTTypeDescription'] = item['UTTypeDescription'].replace('DeskCapture', 'Shotloom')
(root / 'Resources/Info-AppStore.plist').write_bytes(plistlib.dumps(info, sort_keys=False))

# Required-reason APIs: local preferences, media file metadata, recording/export
# capacity checks and elapsed-time calculations. Optional support requests send
# the user's email/message and, if included, app/system versions. No tracking.
reasons = [('UserDefaults', ['CA92.1']), ('FileTimestamp', ['C617.1', '3B52.1', 'DDA9.1']),
           ('DiskSpace', ['E174.1']), ('SystemBootTime', ['35F9.1'])]
support_data = [{'NSPrivacyCollectedDataType': 'NSPrivacyCollectedDataType' + category,
                 'NSPrivacyCollectedDataTypeLinked': True,
                 'NSPrivacyCollectedDataTypeTracking': False,
                 'NSPrivacyCollectedDataTypePurposes': ['NSPrivacyCollectedDataTypePurposeAppFunctionality']}
                for category in ['EmailAddress', 'CustomerSupport', 'OtherDiagnosticData']]
privacy = {'NSPrivacyTracking': False, 'NSPrivacyTrackingDomains': [], 'NSPrivacyCollectedDataTypes': support_data,
           'NSPrivacyAccessedAPITypes': [{'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategory' + category,
                                        'NSPrivacyAccessedAPITypeReasons': values} for category, values in reasons]}
(root / 'Resources/PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps(privacy, sort_keys=False))
print(project)
