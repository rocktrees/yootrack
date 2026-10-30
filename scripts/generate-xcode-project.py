#!/usr/bin/env python3
"""Generate a dependency-free Xcode project; shared sources compile into both native targets."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
project = root / "PowerWatch.xcodeproj"
project.mkdir(exist_ok=True)
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(str(value))
def add(name, value):
    key = uid(name)
    objects[key] = value
    return key
def array(values): return "(" + ",".join(values) + ")"

core = sorted((root / "Sources/PowerWatchCore").glob("*.swift"))
app = sorted((root / "Sources/PowerWatch").glob("*.swift"))
helper = sorted((root / "Sources/PowerWatchHelper").glob("*.swift"))
ui_tests = sorted((root / "Tests/PowerWatchUITests").glob("*.swift"))
scripts = [root / "scripts/install-helper.sh", root / "scripts/uninstall-helper.sh", root / "Resources/PowerWatch.icns"]
refs = {}
for path in core + app + helper + ui_tests + scripts + [root / "Resources/Info.plist", root / "Package.swift"]:
    relative = str(path.relative_to(root))
    refs[path] = add(relative, "{isa=PBXFileReference; path=" + q(relative) + "; sourceTree=SOURCE_ROOT; lastKnownFileType=" + ("sourcecode.swift" if path.suffix == ".swift" else "text.plist.xml" if path.suffix == ".plist" else "image.icns" if path.suffix == ".icns" else "text.script.sh") + ";}")
app_product = add("app-product", '{isa=PBXFileReference;explicitFileType=wrapper.application;path="Power Watch.app";sourceTree=BUILT_PRODUCTS_DIR;}')
helper_product = add("helper-product", '{isa=PBXFileReference;explicitFileType="compiled.mach-o.executable";path=PowerWatchHelper;sourceTree=BUILT_PRODUCTS_DIR;}')
ui_product = add("ui-product", '{isa=PBXFileReference;explicitFileType=wrapper.cfbundle;path=PowerWatchUITests.xctest;sourceTree=BUILT_PRODUCTS_DIR;}')
products = add("products", "{isa=PBXGroup;name=Products;children=" + array([app_product, helper_product, ui_product]) + ";sourceTree=\"<group>\";}")
groups = []
for name, files in [("Shared measurement", core), ("App", app), ("Collector", helper), ("UI tests", ui_tests), ("Installation", scripts)]:
    groups.append(add(name, "{isa=PBXGroup;name=" + q(name) + ";children=" + array([refs[p] for p in files]) + ";sourceTree=\"<group>\";}"))
main_group = add("main-group", "{isa=PBXGroup;children=" + array(groups + [refs[root / "Package.swift"], refs[root / "Resources/Info.plist"], products]) + ";sourceTree=\"<group>\";}")

def configs(name, settings):
    ids = []
    for config in ["Debug", "Release"]:
        specific = {**settings, "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O", "DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug" else "dwarf-with-dsym"}
        body = "".join(q(k) + "=" + q(v) + ";" for k, v in specific.items())
        ids.append(add(name + config, "{isa=XCBuildConfiguration;name=" + config + ";buildSettings={" + body + "};}"))
    return add(name + "-configs", "{isa=XCConfigurationList;buildConfigurations=" + array(ids) + ";defaultConfigurationIsVisible=0;defaultConfigurationName=Release;}")

common = {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "15.0", "ARCHS": "arm64", "SWIFT_VERSION": "5.0", "CODE_SIGN_IDENTITY": "-", "CODE_SIGN_STYLE": "Manual", "ENABLE_APP_SANDBOX": "NO", "OTHER_LDFLAGS": "$(inherited) -lsqlite3", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited)", "ALWAYS_SEARCH_USER_PATHS": "NO"}
project_configs = configs("project", common)
helper_configs = configs("helper", {**common, "PRODUCT_NAME": "PowerWatchHelper", "PRODUCT_BUNDLE_IDENTIFIER": "ai.powerwatch.collector", "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES", "GENERATE_INFOPLIST_FILE": "YES", "SKIP_INSTALL": "YES"})
app_configs = configs("app", {**common, "PRODUCT_NAME": "Power Watch", "EXECUTABLE_NAME": "PowerWatch", "PRODUCT_BUNDLE_IDENTIFIER": "ai.powerwatch.app", "INFOPLIST_FILE": "Resources/Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "COMBINE_HIDPI_IMAGES": "YES", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks"})
def sources(name, files):
    builds = [add(name + str(p), "{isa=PBXBuildFile;fileRef=" + refs[p] + ";}") for p in files]
    return add(name + "-sources", "{isa=PBXSourcesBuildPhase;buildActionMask=2147483647;files=" + array(builds) + ";runOnlyForDeploymentPostprocessing=0;}")
helper_sources = sources("helper", core + helper)
app_sources = sources("app", core + app)
resource_builds = [add("resource" + str(p), "{isa=PBXBuildFile;fileRef=" + refs[p] + ";}") for p in scripts]
resources = add("resources", "{isa=PBXResourcesBuildPhase;buildActionMask=2147483647;files=" + array(resource_builds) + ";runOnlyForDeploymentPostprocessing=0;}")
helper_copy = add("helper-copy-build", "{isa=PBXBuildFile;fileRef=" + helper_product + ';settings={ATTRIBUTES=(CodeSignOnCopy,);};}')
copy = add("helper-copy", "{isa=PBXCopyFilesBuildPhase;buildActionMask=2147483647;dstPath=Contents/Library/Helpers;dstSubfolderSpec=1;files=" + array([helper_copy]) + ";runOnlyForDeploymentPostprocessing=0;}")
helper_target = add("helper-target", "{isa=PBXNativeTarget;name=PowerWatchHelper;productName=PowerWatchHelper;productReference=" + helper_product + ";productType=\"com.apple.product-type.tool\";buildConfigurationList=" + helper_configs + ";buildPhases=" + array([helper_sources]) + ";buildRules=();dependencies=();}")
proxy = add("proxy", "{isa=PBXContainerItemProxy;containerPortal=" + uid("project") + ";proxyType=1;remoteGlobalIDString=" + helper_target + ";remoteInfo=PowerWatchHelper;}")
dependency = add("dependency", "{isa=PBXTargetDependency;target=" + helper_target + ";targetProxy=" + proxy + ";}")
clean_metadata = add("clean-build-metadata", '{isa=PBXShellScriptBuildPhase;buildActionMask=2147483647;files=();inputPaths=();outputPaths=();runOnlyForDeploymentPostprocessing=0;shellPath=/bin/sh;shellScript=' + q('/usr/bin/xattr -cr "$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"') + ';alwaysOutOfDate=1;}')
app_target = add("app-target", "{isa=PBXNativeTarget;name=PowerWatch;productName=\"Power Watch\";productReference=" + app_product + ";productType=\"com.apple.product-type.application\";buildConfigurationList=" + app_configs + ";buildPhases=" + array([app_sources, resources, copy, clean_metadata]) + ";buildRules=();dependencies=" + array([dependency]) + ";}")
ui_configs = configs("ui", {**common, "PRODUCT_NAME": "PowerWatchUITests", "PRODUCT_BUNDLE_IDENTIFIER": "ai.powerwatch.uitests", "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": "PowerWatch", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @loader_path/../Frameworks @executable_path/../Frameworks"})
ui_dependency = add("ui-dependency", "{isa=PBXTargetDependency;target=" + app_target + ";}")
ui_target = add("ui-target", "{isa=PBXNativeTarget;name=PowerWatchUITests;productName=PowerWatchUITests;productReference=" + ui_product + ";productType=\"com.apple.product-type.bundle.ui-testing\";buildConfigurationList=" + ui_configs + ";buildPhases=" + array([sources("ui", ui_tests)]) + ";buildRules=();dependencies=" + array([ui_dependency]) + ";}")
project_id = add("project", "{isa=PBXProject;attributes={LastUpgradeCheck=2600;};buildConfigurationList=" + project_configs + ";compatibilityVersion=\"Xcode 14.0\";developmentRegion=en;hasScannedForEncodings=0;knownRegions=(en,Base);mainGroup=" + main_group + ";productRefGroup=" + products + ";projectDirPath=\"\";projectRoot=\"\";targets=" + array([app_target, helper_target, ui_target]) + ";}")
(project / "project.pbxproj").write_text("// !$*UTF8*$!\n{archiveVersion=1;classes={};objectVersion=56;objects={\n" + "\n".join(k + "=" + v + ";" for k, v in objects.items()) + "\n};rootObject=" + project_id + ";}\n")
scheme_dir = project / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="Power Watch.app" BlueprintName="PowerWatch" ReferencedContainer="container:PowerWatch.xcodeproj"/>'
(scheme_dir / "PowerWatch.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
ui_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_target}" BuildableName="PowerWatchUITests.xctest" BlueprintName="PowerWatchUITests" ReferencedContainer="container:PowerWatch.xcodeproj"/>'
(scheme_dir / "PowerWatchUI.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO" parallelizable="NO">{ui_ref}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
</Scheme>''')
