#!/usr/bin/env python3
"""Deterministic, dependency-free generator for the two native application targets.
Run after adding/removing Apple source files. The generated project is committed.
"""
import hashlib, json, plistlib, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; APP=ROOT/'apps/apple'; PROJECT=APP/'MangaReader.xcodeproj'
PROJECT.mkdir(exist_ok=True)
existing_settings={}
if (PROJECT/'project.pbxproj').exists():
 previous=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(PROJECT/'project.pbxproj')]))
 existing_settings={key:value.get('buildSettings',{}) for key,value in previous['objects'].items() if value['isa']=='XCBuildConfiguration'}
def uid(name):return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def q(v):return json.dumps(str(v))
objects={}
def obj(key,isa,**fields):
 id=uid(key);objects[id]={'isa':isa,**fields};return id
def raw(v):
 if isinstance(v,dict):return '{ '+''.join(f'{k} = {raw(val)}; ' for k,val in v.items())+'}'
 if isinstance(v,list):return '( '+', '.join(raw(x) for x in v)+' )'
 return q(v)
files=[]
for path in sorted(APP.glob('**/*.swift')):
 if '.build' in path.relative_to(APP).parts:continue
 relative=path.relative_to(APP).as_posix();ref=obj('file:'+relative,'PBXFileReference',lastKnownFileType='sourcecode.swift',path=relative,sourceTree='<group>');files.append((relative,ref))
config=obj('base','PBXFileReference',lastKnownFileType='text.xcconfig',path='Config/Base.xcconfig',sourceTree='<group>')
serviceConfig=obj('service-config','PBXFileReference',lastKnownFileType='text.xcconfig',path='Config/Service.xcconfig',sourceTree='<group>')
local=obj('core-package','XCLocalSwiftPackageReference',relativePath='../../packages/MangaCore')
smb=obj('smb-package','XCRemoteSwiftPackageReference',repositoryURL='https://github.com/amosavian/AMSMB2',requirement={'kind':'exactVersion','version':'4.0.3'})
targets=[];products=[]
for name,folder,sdk,bundle in [('MangaReaderMac','Mac','macosx','com.thristram.mangareader.mac'),('MangaReaderiPhone','iPhone','iphoneos','com.thristram.mangareader.iphone')]:
 product=obj('product:'+name,'PBXFileReference',explicitFileType='wrapper.application',path=name+'.app',sourceTree='BUILT_PRODUCTS_DIR');products.append(product)
 sources=[obj('build:'+name+':'+relative,'PBXBuildFile',fileRef=ref) for relative,ref in files if relative.startswith('Shared/') or relative.startswith(folder+'/')]
 sourcePhase=obj('sources:'+name,'PBXSourcesBuildPhase',buildActionMask='2147483647',files=sources,runOnlyForDeploymentPostprocessing='0')
 deps=[obj('core-dep:'+name,'XCSwiftPackageProductDependency',package=local,productName='MangaCore'),obj('smb-dep:'+name,'XCSwiftPackageProductDependency',package=smb,productName='AMSMB2')]
 frameworkFiles=[obj('framework:'+name+':'+d,'PBXBuildFile',productRef=d) for d in deps]
 frameworks=obj('frameworks:'+name,'PBXFrameworksBuildPhase',buildActionMask='2147483647',files=frameworkFiles,runOnlyForDeploymentPostprocessing='0')
 # AMSMB2 declares a dynamic product. Linking alone leaves it outside the app;
 # Xcode must copy it to the platform's Frameworks directory and sign that copy.
 embeddedSMB=obj('embed-framework:'+name,'PBXBuildFile',productRef=deps[1],settings={'ATTRIBUTES':['CodeSignOnCopy','RemoveHeadersOnCopy']})
 embedFrameworks=obj('embed-frameworks:'+name,'PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='',dstSubfolderSpec='10',files=[embeddedSMB],name='Embed Frameworks',runOnlyForDeploymentPostprocessing='0')
 resources=obj('resources:'+name,'PBXResourcesBuildPhase',buildActionMask='2147483647',files=[],runOnlyForDeploymentPostprocessing='0')
 configs=[]
 for mode in ['Debug','Release']:
  settings={'PRODUCT_NAME':name,'PRODUCT_BUNDLE_IDENTIFIER':bundle,'SDKROOT':sdk,'SWIFT_VERSION':'5.0','GENERATE_INFOPLIST_FILE':'NO','INFOPLIST_FILE':'Config/Info-'+folder+'.plist','CODE_SIGN_STYLE':'Automatic','MARKETING_VERSION':'0.1.0','CURRENT_PROJECT_VERSION':'1','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','ENABLE_USER_SCRIPT_SANDBOXING':'YES','SWIFT_STRICT_CONCURRENCY':'targeted','ONLY_ACTIVE_ARCH':'YES' if mode=='Debug' else 'NO'}
  if folder=='Mac':settings.update({'MACOSX_DEPLOYMENT_TARGET':'26.0','CODE_SIGN_ENTITLEMENTS':'Config/MangaReaderMac.entitlements','ENABLE_APP_SANDBOX':'YES','COMBINE_HIDPI_IMAGES':'YES','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks'})
  else:settings.update({'IPHONEOS_DEPLOYMENT_TARGET':'26.0','TARGETED_DEVICE_FAMILY':'1,2','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks'})
  # Preserve Xcode-managed settings such as the user's signing team/profile.
  settings={**settings,**existing_settings.get(uid('config:'+name+mode),{})}
  configs.append(obj('config:'+name+mode,'XCBuildConfiguration',baseConfigurationReference=config,buildSettings=settings,name=mode))
 configList=obj('config-list:'+name,'XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible='0',defaultConfigurationName='Debug')
 target=obj('target:'+name,'PBXNativeTarget',buildConfigurationList=configList,buildPhases=[sourcePhase,frameworks,resources,embedFrameworks],buildRules=[],dependencies=[],name=name,packageProductDependencies=deps,productName=name,productReference=product,productType='com.apple.product-type.application');targets.append(target)
 info={'CFBundleDevelopmentRegion':'en','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleName':'MangaReader','CFBundlePackageType':'APPL','CFBundleShortVersionString':'$(MARKETING_VERSION)','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)','MangaAPIURL':'$(MANGA_API_URL)','AuthIssuer':'$(AUTH_ISSUER)','MangaAPIAudience':'$(MANGA_API_AUDIENCE)','OAuthClientID':'$(MAC_OAUTH_CLIENT_ID)' if folder=='Mac' else '$(IPHONE_OAUTH_CLIENT_ID)','CFBundleURLTypes':[{'CFBundleURLName':bundle,'CFBundleURLSchemes':[bundle]}],'NSLocalNetworkUsageDescription':'MangaReader connects directly to your NAS to read and download your manga.','NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}}
 if folder=='Mac':info.update({'NSPrincipalClass':'NSApplication','LSMinimumSystemVersion':'$(MACOSX_DEPLOYMENT_TARGET)'})
 else:info.update({'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Default','UISceneDelegateClassName':'$(PRODUCT_MODULE_NAME).PhoneSceneDelegate'}]}},'UILaunchScreen':{},'UIRequiredDeviceCapabilities':['arm64'],'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight']})
 with (APP/'Config'/('Info-'+folder+'.plist')).open('wb') as f:plistlib.dump(info,f)
 schemes=PROJECT/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
 if not (schemes/(name+'.xcscheme')).exists():
  (schemes/(name+'.xcscheme')).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:MangaReader.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:MangaReader.xcodeproj"/></BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
productsGroup=obj('products-group','PBXGroup',children=products,name='Products',sourceTree='<group>')
main=obj('main-group','PBXGroup',children=[ref for _,ref in files]+[config,serviceConfig,productsGroup],sourceTree='<group>')
projectConfigs=[obj('project-config:'+mode,'XCBuildConfiguration',buildSettings={'CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','SWIFT_VERSION':'5.0',**existing_settings.get(uid('project-config:'+mode),{})},name=mode) for mode in ['Debug','Release']]
projectList=obj('project-config-list','XCConfigurationList',buildConfigurations=projectConfigs,defaultConfigurationIsVisible='0',defaultConfigurationName='Debug')
project=obj('project','PBXProject',attributes={'LastUpgradeCheck':'2700'},buildConfigurationList=projectList,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings='0',knownRegions=['en','Base'],mainGroup=main,packageReferences=[local,smb],productRefGroup=productsGroup,projectDirPath='',projectRoot='',targets=targets)
(PROJECT/'project.pbxproj').write_text('// !$*UTF8*$!\n'+raw({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project})+'\n')
with (APP/'Config/MangaReaderMac.entitlements').open('wb') as f:plistlib.dump({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True,'com.apple.security.files.user-selected.read-write':True,'com.apple.security.files.bookmarks.app-scope':True},f)
print(PROJECT)
