#!/usr/bin/env python3
"""Manual real-xccov disjoint-line control. Generates its tiny project outside the repo."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pro_release_runner import command, json_command
from release_evidence import ROOT, digest, discovery_tests, now, read, source_snapshot, toolchain, write
from coverage_inputs import coverage_index, export_pair, validate_union

SOURCE = '''func sharedBranch(_ positive: Bool) -> Int {
    var total = 1
    if positive {
        total += 3
    } else {
        total += 7
    }
    return total
}
func ordinaryOnly() -> Int {
    return 11
}
func nativeOnly() -> Int {
    return 17
}
'''
TESTS = '''import XCTest
final class UnionTests: XCTestCase {
    func testOrdinary() {
        XCTAssertEqual(sharedBranch(true), 4)
        XCTAssertEqual(ordinaryOnly(), 11)
    }
    func testNative() {
        XCTAssertEqual(sharedBranch(false), 8)
        XCTAssertEqual(nativeOnly(), 17)
    }
}
'''


def project(folder):
    """A hostless macOS XCTest target exercises raw merge semantics without devices."""
    objects = {
        'P': dict(isa='PBXProject', attributes=dict(LastUpgradeCheck='1600'), buildConfigurationList='PC',
                  compatibilityVersion='Xcode 14.0', developmentRegion='en', knownRegions=['en'],
                  mainGroup='G', productRefGroup='PG', projectDirPath='', projectRoot='', targets=['T']),
        'G': dict(isa='PBXGroup', children=['F', 'TF', 'PG'], sourceTree='<group>'),
        'PG': dict(isa='PBXGroup', children=['PRODUCT'], name='Products', sourceTree='<group>'),
        'F': dict(isa='PBXFileReference', path='Fixture.swift', lastKnownFileType='sourcecode.swift', sourceTree='<group>'),
        'TF': dict(isa='PBXFileReference', path='UnionTests.swift', lastKnownFileType='sourcecode.swift', sourceTree='<group>'),
        'PRODUCT': dict(isa='PBXFileReference', path='UnionTests.xctest', explicitFileType='wrapper.cfbundle', sourceTree='BUILT_PRODUCTS_DIR'),
        'B': dict(isa='PBXBuildFile', fileRef='F'), 'TB': dict(isa='PBXBuildFile', fileRef='TF'),
        'S': dict(isa='PBXSourcesBuildPhase', buildActionMask=2147483647, files=['B', 'TB'], runOnlyForDeploymentPostprocessing=0),
        'T': dict(isa='PBXNativeTarget', buildConfigurationList='TC', buildPhases=['S'], buildRules=[], dependencies=[],
                  name='UnionTests', productName='UnionTests', productReference='PRODUCT', productType='com.apple.product-type.bundle.unit-test'),
        'PC': dict(isa='XCConfigurationList', buildConfigurations=['PD'], defaultConfigurationIsVisible=0, defaultConfigurationName='Debug'),
        'TC': dict(isa='XCConfigurationList', buildConfigurations=['TD'], defaultConfigurationIsVisible=0, defaultConfigurationName='Debug'),
        'PD': dict(isa='XCBuildConfiguration', name='Debug', buildSettings=dict(SDKROOT='macosx', MACOSX_DEPLOYMENT_TARGET='14.0',
                   SWIFT_VERSION='6.0', SWIFT_OPTIMIZATION_LEVEL='-Onone', CLANG_ENABLE_MODULES='YES')),
        'TD': dict(isa='XCBuildConfiguration', name='Debug', buildSettings=dict(PRODUCT_NAME='UnionTests',
                   PRODUCT_BUNDLE_IDENTIFIER='com.hemsoft.CoverageUnionTests', GENERATE_INFOPLIST_FILE='YES',
                   CODE_SIGNING_ALLOWED='NO', ENABLE_HARDENED_RUNTIME='NO')),
    }
    ids = {key: f'{index:024X}' for index, key in enumerate(objects, 1)}
    def identifiers(value):
        if isinstance(value, str):
            return ids.get(value, value)
        if isinstance(value, list):
            return [identifiers(item) for item in value]
        if isinstance(value, dict):
            return {key: identifiers(item) for key, item in value.items()}
        return value
    objects = {ids[key]: identifiers(value) for key, value in objects.items()}
    # Xcode accepts the XML property-list representation of the PBX graph.
    xcode = folder / 'CoverageUnion.xcodeproj'
    xcode.mkdir()
    (xcode / 'project.pbxproj').write_bytes(plistlib.dumps(dict(archiveVersion='1', classes={}, objectVersion='56', objects=objects, rootObject=ids['P'])))
    schemes = xcode / 'xcshareddata/xcschemes'
    schemes.mkdir(parents=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids["T"]}" BuildableName="UnionTests.xctest" BlueprintName="UnionTests" ReferencedContainer="container:CoverageUnion.xcodeproj"/>'
    (schemes / 'CoverageUnion.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
 <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{reference}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" codeCoverageEnabled="YES">
  <Testables><TestableReference skipped="NO" parallelizable="NO">{reference}</TestableReference></Testables>
 </TestAction>
</Scheme>
''')
    (folder / 'Fixture.swift').write_text(SOURCE)
    (folder / 'UnionTests.swift').write_text(TESTS)
    return xcode


def prove(output, supplementary=False):
    output.mkdir(parents=True, exist_ok=False)
    tools = toolchain()
    pin = read(ROOT / 'scripts/function-risk/policy.json')['tools']['xcode']
    if not supplementary and tools['xcode'] != pin:
        raise ValueError(f'This proof requires {pin!r}; use --supplementary for local development evidence')
    source = source_snapshot()
    receipt = dict(started=now(), tools=tools, source=source, supplementary=supplementary, qualified=False)
    try:
        fixture = output / 'fixture'
        fixture.mkdir()
        xcode = project(fixture)
        fixture_sources = {str(path.relative_to(fixture)): digest(path) for path in fixture.rglob('*') if path.is_file()}
        indexes, reports, pairs = [], [], []
        for label, method in [('ordinary', 'testOrdinary'), ('native', 'testNative')]:
            folder = output / label
            folder.mkdir()
            result = folder / 'result.xcresult'
            argv = ['xcodebuild', '-project', str(xcode), '-scheme', 'CoverageUnion', '-configuration', 'Debug',
                    '-destination', 'platform=macOS,arch=' + tools['architecture'],
                    '-derivedDataPath', str(folder / 'DerivedData'), '-parallel-testing-enabled', 'NO',
                    '-enableCodeCoverage', 'YES', '-only-testing:UnionTests/UnionTests/' + method,
                    'CODE_SIGNING_ALLOWED=NO']
            command(folder, 'build', argv + ['build-for-testing'])
            discovery = folder / 'discovery.json'
            command(folder, 'discovery', argv + ['test-without-building', '-enumerate-tests',
                    '-test-enumeration-style', 'flat', '-test-enumeration-format', 'json',
                    '-test-enumeration-output-path', str(discovery)])
            if discovery_tests(read(discovery)) != ['UnionTests/UnionTests/' + method]:
                raise ValueError('Real built-test enumeration differs from the selected fixture method')
            command(folder, 'test', argv + ['-resultBundlePath', str(result), 'test-without-building'])
            summary = json_command(folder, 'summary', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)])
            if any(summary.get(key) != value for key, value in dict(result='Passed', totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0, expectedFailures=0).items()):
                raise ValueError('Coverage-union control did not execute exactly one passing test')
            report_path, archive_path = export_pair(result, folder / 'raw', lambda argv: command(folder, 'export', argv))
            report = json_command(folder, 'coverage', ['xcrun', 'xccov', 'view', '--json', str(report_path)])
            reports.append(report)
            indexes.append(coverage_index(report, fixture, {'Fixture.swift', 'UnionTests.swift'}))
            pairs.extend([str(report_path), str(archive_path)])
            write(folder / 'artifacts.json', dict(result_sha256=digest(result), report_sha256=digest(report_path), archive_sha256=digest(archive_path)))
        validate_union(indexes, None)
        merged_report, merged_archive = output / 'merged.xccovreport', output / 'merged.xccovarchive'
        command(output, 'merge', ['xcrun', 'xccov', 'merge', '--outReport', str(merged_report), '--outArchive', str(merged_archive), *pairs])
        merged = json_command(output, 'coverage', ['xcrun', 'xccov', 'view', '--json', str(merged_report)])
        merged_index = coverage_index(merged, fixture, {'Fixture.swift', 'UnionTests.swift'})
        validate_union(indexes, merged_index)
        source_path = str((fixture / 'Fixture.swift').resolve())
        keys = [key for key in merged_index if key[0] == 'function' and key[2] == source_path]
        shared = [key for key in keys if 'sharedBranch' in key[-1]]
        if len(shared) != 1:
            raise ValueError('Shared branch function is missing or ambiguous')
        key = shared[0]
        first, second, union = indexes[0][key], indexes[1][key], merged_index[key]
        if not (union[0] > first[0] and union[0] > second[0] and union[0] < first[0] + second[0]
                and union[0] == union[1] == first[1] == second[1]):
            raise ValueError(f'Disjoint-line union proof failed: ordinary={first}, native={second}, merged={union}')
        for name, covered_input in [('ordinaryOnly', 0), ('nativeOnly', 1)]:
            matches = [key for key in keys if name in key[-1]]
            if len(matches) != 1:
                raise ValueError(f'Missing/ambiguous retained function: {name}')
            match = matches[0]
            if not (indexes[covered_input][match][0] > 0 and indexes[1-covered_input][match][0] == 0
                    and merged_index[match] == indexes[covered_input][match]):
                raise ValueError(f'Lost {name} coverage')
        if any(digest(fixture / path) != checksum for path, checksum in fixture_sources.items()) or source_snapshot() != source:
            raise ValueError('Source changed during coverage-union proof')
        receipt.update(exit=0, qualified=not supplementary, shared=dict(ordinary=first, native=second, union=union),
                       fixture_sources=fixture_sources, merged_report_sha256=digest(merged_report), merged_archive_sha256=digest(merged_archive))
    except Exception as error:
        receipt.update(exit=getattr(error, 'code', 1), error=str(error))
        raise
    finally:
        receipt['ended'] = now()
        write(output / 'proof.json', receipt)
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--supplementary', action='store_true')
    args = parser.parse_args()
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    try:
        print(json.dumps(prove(args.output.resolve(), args.supplementary), indent=2))
    except Exception as error:
        print(f'Coverage union not qualified: {error}', file=sys.stderr)
        sys.exit(1)
