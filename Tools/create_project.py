from pathlib import Path
import hashlib
import os
import json
root=Path(os.environ.get('STEAMTV_PROJECT_ROOT', Path(__file__).resolve().parents[1])).resolve()
game=json.loads((root/'Game.json').read_text()) if (root/'Game.json').exists() else None
bundle_id=game['bundleID'] if game else 'com.josephhewes.HaloCampaignEvolvedAppTV'
app_icon='GameIcon' if game else 'App Icon & Top Shelf Image' 
def ident(text): return hashlib.sha1(text.encode()).hexdigest()[:24].upper()
objects={}
def obj(name,body):
    uid=ident(name); objects[uid]=body; return uid
source_paths=sorted([*root.glob('Sources/SteamProtocolCore/*.swift'),*root.glob('SteamTV/*.swift'),*root.glob('SteamTV/*.m'),*root.glob('Sources/SteamCrypto/*.c'),*root.glob('Sources/PyroWave/*.mm'),*root.glob('Sources/PyroWave/*.m'),*root.glob('Sources/PyroWave/metal/*.mm'),*root.glob('Sources/PyroWave/metal/*.cpp'),*root.glob('Sources/PyroWave/CloudNow/*.m')])
refs=[]; builds=[]
for path in source_paths:
    rel=path.relative_to(root).as_posix() if path.is_relative_to(root) else str(path)
    filetype = 'sourcecode.c.c' if path.suffix == '.c' else ('sourcecode.cpp.objcpp' if path.suffix == '.mm' else ('sourcecode.cpp.cpp' if path.suffix == '.cpp' else ('sourcecode.c.objc' if path.suffix == '.m' else 'sourcecode.swift')))
    source_tree='"<group>"' if path.is_relative_to(root) else '"<absolute>"'
    ref=obj(rel, f'isa = PBXFileReference; lastKnownFileType = {filetype}; path = "{rel}"; sourceTree = {source_tree};')
    refs.append(ref)
    builds.append(obj('build:'+rel,f'isa = PBXBuildFile; fileRef = {ref};'))
product=obj('product','isa = PBXFileReference; explicitFileType = wrapper.application; path = SteamTV.app; sourceTree = BUILT_PRODUCTS_DIR;')
plist=obj('plist','isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = SteamTV/Info.plist; sourceTree = "<group>";')
products=obj('products',f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
group=obj('group',f'isa = PBXGroup; children = ({",".join(refs+[plist,products])},); sourceTree = "<group>";')
sources=obj('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
frameworks=obj('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
resource_builds=[]
for rel,typ in [('SteamTV/Assets.xcassets','folder.assetcatalog'),*([('SteamTV/Settings.bundle','wrapper.plug-in')] if not game else [])]:
    ref=obj(rel,f'isa = PBXFileReference; lastKnownFileType = {typ}; path = "{rel}"; sourceTree = "<group>";')
    resource_builds.append(obj('build:'+rel,f'isa = PBXBuildFile; fileRef = {ref};'))
resources=obj('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resource_builds)},); runOnlyForDeploymentPostprocessing = 0;')
runtime_dylib=root/'Runtime/PyroWave/libpyrowave-shared.0.4.0.dylib'
runtime_framework=root/'Runtime/PyroWave/MoltenVK.framework'
dylib_ref=obj(str(runtime_dylib), 'isa = PBXFileReference; explicitFileType = "compiled.mach-o.dylib"; path = "%s"; sourceTree = "<group>";'%runtime_dylib.relative_to(root))
framework_ref=obj(str(runtime_framework), 'isa = PBXFileReference; explicitFileType = wrapper.framework; path = "%s"; sourceTree = "<group>";'%runtime_framework.relative_to(root))
dylib_build=obj('runtime:'+str(runtime_dylib),f'isa = PBXBuildFile; fileRef = {dylib_ref};')
framework_build=obj('runtime:'+str(runtime_framework),f'isa = PBXBuildFile; fileRef = {framework_ref};')
copyfiles=obj('copyfiles',f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = ({dylib_build},{framework_build}); name = Frameworks; runOnlyForDeploymentPostprocessing = 0;')
projectconfigs=[]; targetconfigs=[]
for config in ['Debug','Release']:
    debug=config=='Debug'
    projectconfigs.append(obj('project:'+config,f'''isa = XCBuildConfiguration; name = {config}; buildSettings = {{
        CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; SDKROOT = appletvos;
        TVOS_DEPLOYMENT_TARGET = 17.0; DEBUG_INFORMATION_FORMAT = {"dwarf" if debug else '"dwarf-with-dsym"'};
        SWIFT_OPTIMIZATION_LEVEL = "-O"; GCC_OPTIMIZATION_LEVEL = 3;
        SWIFT_ACTIVE_COMPILATION_CONDITIONS = { '"DEBUG $(inherited)"' if debug else '"$(inherited)"'};
        }};'''))
    targetconfigs.append(obj('target:'+config,f'''isa = XCBuildConfiguration; name = {config}; buildSettings = {{
        PRODUCT_NAME = SteamTV; PRODUCT_BUNDLE_IDENTIFIER = {bundle_id};
        INFOPLIST_FILE = SteamTV/Info.plist; GENERATE_INFOPLIST_FILE = NO;
        TARGETED_DEVICE_FAMILY = 3; SUPPORTED_PLATFORMS = "appletvos appletvsimulator";
        DEVELOPMENT_TEAM = 286K3K83X3; CODE_SIGN_STYLE = Automatic; CODE_SIGN_ENTITLEMENTS = SteamTV/SteamTV.entitlements; ASSETCATALOG_COMPILER_APPICON_NAME = "{app_icon}"; SWIFT_EMIT_LOC_STRINGS = YES;
        SWIFT_OBJC_BRIDGING_HEADER = SteamTV/SteamTV-Bridging-Header.h;
        HEADER_SEARCH_PATHS = ("$(inherited)", "$(SRCROOT)/Sources/SteamCrypto/include", "$(SRCROOT)/Sources/PyroWave", "$(SRCROOT)/Sources/PyroWave/metal", "$(SRCROOT)/Sources/PyroWave/CloudNow");
        CLANG_CXX_LANGUAGE_STANDARD = "c++17"; CLANG_ENABLE_OBJC_ARC = YES;
        LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
        }};'''))
projectlist=obj('projectlist',f'isa = XCConfigurationList; buildConfigurations = ({",".join(projectconfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
targetlist=obj('targetlist',f'isa = XCConfigurationList; buildConfigurations = ({",".join(targetconfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target=obj('target',f'isa = PBXNativeTarget; buildConfigurationList = {targetlist}; buildPhases = ({sources},{frameworks},{resources},{copyfiles},); buildRules = (); dependencies = (); name = SteamTV; productName = SteamTV; productReference = {product}; productType = "com.apple.product-type.application";')
# Keep the Top Shelf extension in the parent app only.
# STEAMTV_TOP_SHELF=0 can still omit it when provisioning the parent.
enable_top_shelf = game is None and os.environ.get('STEAMTV_TOP_SHELF', '1') != '0'
project_targets = target
if enable_top_shelf:
    ext_product=obj('ext-product','isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = SteamTVTopShelf.appex; sourceTree = BUILT_PRODUCTS_DIR;')
    ext_builds=[]
    for path in sorted((root/'SteamTVTopShelf').glob('*.swift')):
        rel=path.relative_to(root).as_posix()
        ref=obj('ext-source:'+rel,f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{rel}"; sourceTree = "<group>";')
        ext_builds.append(obj('ext-build:'+rel,f'isa = PBXBuildFile; fileRef = {ref};'))
    ext_sources=obj('ext-sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(ext_builds)},); runOnlyForDeploymentPostprocessing = 0;')
    ext_resources=[]
    for rel in (['SteamTVTopShelf/hero.jpg'] if game else ['SteamTVTopShelf/SteamHero.png','SteamTVTopShelf/MrDrillerHero.jpg']):
        ref=obj(rel,f'isa = PBXFileReference; lastKnownFileType = {"image.jpeg" if rel.endswith(".jpg") else "image.png"}; path = "{rel}"; sourceTree = "<group>";')
        ext_resources.append(obj('build:'+rel,f'isa = PBXBuildFile; fileRef = {ref};'))
    ext_resource_phase=obj('ext-resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(ext_resources)},); runOnlyForDeploymentPostprocessing = 0;')
    ext_configs=[]
    for config in ['Debug','Release']:
        ext_configs.append(obj('ext-config:'+config,f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{ PRODUCT_NAME = SteamTVTopShelf; PRODUCT_BUNDLE_IDENTIFIER = {bundle_id}.TopShelf; INFOPLIST_FILE = SteamTVTopShelf/Info.plist; GENERATE_INFOPLIST_FILE = NO; TARGETED_DEVICE_FAMILY = 3; SUPPORTED_PLATFORMS = "appletvos appletvsimulator"; DEVELOPMENT_TEAM = 286K3K83X3; CODE_SIGN_STYLE = Automatic; APPLICATION_EXTENSION_API_ONLY = YES; CODE_SIGN_ENTITLEMENTS = SteamTVTopShelf/TopShelf.entitlements; SKIP_INSTALL = YES; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks"; }};'))
    ext_list=obj('ext-list',f'isa = XCConfigurationList; buildConfigurations = ({",".join(ext_configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    ext_target=obj('ext-target',f'isa = PBXNativeTarget; buildConfigurationList = {ext_list}; buildPhases = ({ext_sources},{frameworks},{ext_resource_phase},); buildRules = (); dependencies = (); name = SteamTVTopShelf; productName = SteamTVTopShelf; productReference = {ext_product}; productType = "com.apple.product-type.app-extension";')
    embed_build=obj('ext-embed',f'isa = PBXBuildFile; fileRef = {ext_product}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy,); }};')
    embed=obj('ext-embed-phase',f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({embed_build},); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;')
    proxy=obj('ext-proxy',f'isa = PBXContainerItemProxy; containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {ext_target}; remoteInfo = SteamTVTopShelf;')
    dependency=obj('ext-dependency',f'isa = PBXTargetDependency; target = {ext_target}; targetProxy = {proxy};')
    objects[target]=objects[target].replace(f'{copyfiles},)',f'{copyfiles},{embed},)').replace('dependencies = ();',f'dependencies = ({dependency},);')
    objects[products]=objects[products].replace(f'{product},)',f'{product},{ext_product},)')
    project_targets = f'{target},{ext_target}'
project=obj('project',f'''isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; TargetAttributes = {{ {target} = {{ SystemCapabilities = {{ com.apple.ApplicationGroups.iOS = {{ enabled = 1; }}; com.apple.HomeKit = {{ enabled = 1; }}; }}; }}; }}; }};
    buildConfigurationList = {projectlist}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en;
    hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {group}; productRefGroup = {products};
    projectDirPath = ""; projectRoot = ""; targets = ({project_targets},);''')
(root/'SteamTV.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(f'{uid} = {{{body}}};' for uid,body in objects.items())+f'\n}}; rootObject = {project}; }}\n')
(root/'SteamTV.xcodeproj/xcshareddata/xcschemes/SteamTV.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="SteamTV.app" BlueprintName="SteamTV" ReferencedContainer="container:SteamTV.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="SteamTV.app" BlueprintName="SteamTV" ReferencedContainer="container:SteamTV.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
