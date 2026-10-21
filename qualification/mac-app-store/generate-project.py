#!/usr/bin/env python3
"""Generate only this qualification's standalone Xcode project; no dependencies."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parent
objects = {}


def key(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(name, content):
    objects[key(name)] = content
    return key(name)


def quoted(value):
    return json.dumps(str(value))


app_sources = ['App.swift', 'Authorization.swift', 'Credentials.swift', 'Restore.swift', 'Checks.swift']
file_ids = []
for name in app_sources + ['StoreKitTests.swift', 'Qualification.storekit']:
    file_ids.append(add(name, '{isa = PBXFileReference; path = ' + quoted(name)
                        + '; sourceTree = "<group>"; lastKnownFileType = '
                        + ('sourcecode.swift' if name.endswith('.swift') else 'text') + ';}'))
app = add('appProduct', '{isa = PBXFileReference; path = "CodexBar Qualification.app"; sourceTree = BUILT_PRODUCTS_DIR; explicitFileType = wrapper.application;}')
tests = add('testProduct', '{isa = PBXFileReference; path = StoreKitQualificationTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; explicitFileType = wrapper.cfbundle;}')
products = add('products', '{isa = PBXGroup; name = Products; sourceTree = "<group>"; children = (' + app + ',' + tests + ',);}')
group = add('group', '{isa = PBXGroup; sourceTree = "<group>"; children = (' + ','.join(file_ids + [products]) + ',);}')


def phase(name, isa, files):
    build_files = [add(name + f, '{isa = PBXBuildFile; fileRef = ' + key(f) + ';}') for f in files]
    return add(name, '{isa = ' + isa + '; buildActionMask = 2147483647; files = ('
               + ','.join(build_files) + (',' if build_files else '') + '); runOnlyForDeploymentPostprocessing = 0;}')


shared = {
    'MACOSX_DEPLOYMENT_TARGET': '14.0', 'SDKROOT': 'macosx', 'SWIFT_VERSION': '6.0',
    'SWIFT_TREAT_WARNINGS_AS_ERRORS': 'YES', 'OTHER_SWIFT_FLAGS': '-Xcc -Wno-deprecated-declarations',
    'ONLY_ACTIVE_ARCH': 'YES', 'ALWAYS_SEARCH_USER_PATHS': 'NO', 'CODE_SIGN_IDENTITY': '-',
    'CODE_SIGN_STYLE': 'Manual', 'CODE_SIGNING_ALLOWED': 'YES',
    'FRAMEWORK_SEARCH_PATHS': '$(inherited) $(PLATFORM_DIR)/Developer/Library/Frameworks',
    'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks $(PLATFORM_DIR)/Developer/Library/Frameworks',
}


def configs(name, settings):
    identifiers = []
    for mode in ['Debug', 'Release']:
        values = shared | settings | {'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if mode == 'Debug' else '-O'}
        fields = ' '.join(quoted(k) + ' = ' + quoted(v) + ';' for k, v in values.items())
        identifiers.append(add(name + mode, '{isa = XCBuildConfiguration; name = ' + mode + '; buildSettings = {' + fields + '};}'))
    return add(name + 'configs', '{isa = XCConfigurationList; buildConfigurations = (' + ','.join(identifiers) + ',); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;}')


app_config = configs('app', {
    'PRODUCT_NAME': 'CodexBar Qualification', 'EXECUTABLE_NAME': 'CodexBarQualification', 'PRODUCT_MODULE_NAME': 'MacQualification',
    'PRODUCT_BUNDLE_IDENTIFIER': 'com.hemsoft.qualification.mac476', 'INFOPLIST_FILE': 'Info.plist',
    'CODE_SIGN_ENTITLEMENTS': 'Qualification.entitlements', 'ENABLE_TESTABILITY': 'YES',
})
test_config = configs('tests', {
    'PRODUCT_NAME': 'StoreKitQualificationTests', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.hemsoft.qualification.mac476.tests',
    'GENERATE_INFOPLIST_FILE': 'YES',
})
app_target = add('appTarget', '{isa = PBXNativeTarget; name = MacQualification; productName = "CodexBar Qualification"; productReference = ' + app
                 + '; productType = "com.apple.product-type.application"; buildConfigurationList = ' + app_config
                 + '; buildPhases = (' + ','.join([phase('appSources', 'PBXSourcesBuildPhase', app_sources), phase('appResources', 'PBXResourcesBuildPhase', ['Qualification.storekit'])])
                 + ',); buildRules = (); dependencies = ();}')
proxy = add('proxy', '{isa = PBXContainerItemProxy; containerPortal = ' + key('project') + '; proxyType = 1; remoteGlobalIDString = ' + app_target + '; remoteInfo = MacQualification;}')
dependency = add('dependency', '{isa = PBXTargetDependency; target = ' + app_target + '; targetProxy = ' + proxy + ';}')
test_target = add('testTarget', '{isa = PBXNativeTarget; name = StoreKitQualificationTests; productName = StoreKitQualificationTests; productReference = ' + tests
                  + '; productType = "com.apple.product-type.bundle.unit-test"; buildConfigurationList = ' + test_config
                  + '; buildPhases = (' + phase('testSources', 'PBXSourcesBuildPhase', ['StoreKitTests.swift', 'Restore.swift']) + ',' + phase('testResources', 'PBXResourcesBuildPhase', ['Qualification.storekit'])
                  + ',); buildRules = (); dependencies = ();}')
add('project', '{isa = PBXProject; attributes = {LastUpgradeCheck = 2700;}; buildConfigurationList = ' + configs('project', {})
    + '; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base,); mainGroup = ' + group
    + '; productRefGroup = ' + products + '; projectDirPath = ""; projectRoot = ""; targets = (' + app_target + ',' + test_target + ',);}')
project = root / 'MacQualification.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
                                       + '\n'.join(k + ' = ' + v + ';' for k, v in sorted(objects.items()))
                                       + '\n}; rootObject = ' + key('project') + ';}\n')
schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
(schemes / 'MacQualification.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildArchitectures="Automatic" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">
<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="CodexBar Qualification.app" BlueprintName="MacQualification" ReferencedContainer="container:MacQualification.xcodeproj"/>
</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>
<TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="StoreKitQualificationTests.xctest" BlueprintName="StoreKitQualificationTests" ReferencedContainer="container:MacQualification.xcodeproj"/></TestableReference>
</Testables></TestAction></Scheme>
''')
