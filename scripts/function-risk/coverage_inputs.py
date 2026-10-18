"""Validate native inputs, then let xccov merge raw line counters before scoring."""
from pathlib import Path
from datetime import datetime
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_evidence import (digest, discovery_tests, load_manifest, read, require_pinned,
                              source_snapshot, validate_receipt, validate_results, write)


def coverage_index(report, root, sources):
    """Reject ambiguous compiled identities and stale production source paths."""
    root = root.resolve()
    records = {}

    def add(key, row):
        if key in records:
            raise ValueError(f'Duplicate coverage identity: {key}')
        covered, executable = row['coveredLines'], row['executableLines']
        if type(covered) is not int or type(executable) is not int or not 0 <= covered <= executable:
            raise ValueError(f'Invalid coverage counters: {key}')
        records[key] = (covered, executable)

    if not report.get('targets'):
        raise ValueError('Empty coverage report')
    for target in report['targets']:
        name = target['name']
        add(('target', name), target)
        for file in target['files']:
            path = str(Path(file['path']).resolve())
            for source in sources:
                if path.endswith('/' + source) and Path(path) != root / source:
                    raise ValueError(f'Stale production source path: {path}')
            add(('file', name, path), file)
            for function in file['functions']:
                add(('function', name, path, function['lineNumber'], function['name']), function)
    return records


def validate_union(inputs, merged):
    """Check identities/denominators and retention; never combine covered totals."""
    expected = {}
    for index in inputs:
        for key, (covered, executable) in index.items():
            if key in expected and expected[key] != executable:
                raise ValueError(f'Incompatible executable-line denominators: {key}')
            expected[key] = executable
            if merged is not None:
                if key not in merged or merged[key][1] != executable:
                    raise ValueError(f'Merged coverage lost identity or denominator: {key}')
                if merged[key][0] < covered:
                    raise ValueError(f'Merged coverage lost covered lines: {key}')
    if merged is not None and set(expected) != set(merged):
        raise ValueError('Merged coverage introduced unexpected identities')


def require_counters(index, names, covered=False):
    for name in names:
        value = index.get(('target', name))
        if value is None or value[1] <= 0 or (covered and value[0] <= 0):
            raise ValueError(f'Missing or empty coverage target: {name}')


def export_pair(result, output, run):
    output.mkdir()
    exported = output / 'exported'
    exported.mkdir()
    run(['xcrun', 'xcresulttool', 'export', 'coverage', '--path', str(result), '--output-path', str(exported)])
    reports = [path for path in exported.rglob('*') if path.is_file() and
               (path.name.endswith('.xccovreport') or path.name.endswith('_CoverageReport'))]
    archives = [path for path in exported.rglob('*') if path.is_dir() and
                (path.name.endswith('.xccovarchive') or path.name.endswith('_CoverageArchive'))]
    def identity(path):
        return path.parent / path.name.removesuffix('.xccovreport').removesuffix('.xccovarchive').removesuffix('_CoverageReport').removesuffix('_CoverageArchive')
    if len(reports) != 1 or len(archives) != 1 or identity(reports[0]) != identity(archives[0]):
        raise ValueError(f'Expected one unambiguous report/archive pair: {output}')
    # xcresulttool exports extensionless *_CoverageReport/Archive; xccov
    # identifies file formats by extension. Preserve exports and their names.
    report, archive = output / 'coverage.xccovreport', output / 'coverage.xccovarchive'
    shutil.copyfile(reports[0], report)
    shutil.copytree(archives[0], archive)
    write(output / 'export-paths.json', dict(report=str(reports[0]), archive=str(archives[0])))
    return report, archive


def collect_coverage(args, output, policy, source_paths, root, run):
    """Single-result CLI remains supported; multi-result input requires receipts."""
    import json

    inputs_output = output / 'inputs'
    inputs_output.mkdir()
    phases = load_manifest()
    manifest = read(args.inputs) if args.inputs else None
    if args.inputs:
        if manifest.get('schema') != 1 or manifest.get('platform') != 'ios' or args.platform != 'ios':
            raise ValueError('Aggregate input manifests are supported only for native iOS')
        if manifest.get('complete') is not True:
            raise ValueError('Incomplete coverage input manifest')
        source = source_snapshot()
        if manifest.get('source') != source:
            raise ValueError('Coverage manifest source snapshot does not match this clean checkout')
        tools = manifest['tools']
        require_pinned(tools)
        if run(['xcodebuild', '-version']) != tools['xcode']:
            raise ValueError('Collector and producer Xcode differ')
        entries = manifest['inputs']
        if [entry['phase'] for entry in entries] != phases['coverage_phases']:
            raise ValueError('Missing, duplicate, reordered or unexpected coverage phases')
        write(output / 'input-manifest.json', manifest)
    else:
        entries = [dict(phase='single', result=str(args.result.resolve()))]
    seen_paths, seen_digests = set(), set()
    indexes, pairs, evidence = [], [], []
    runtime = None
    native_identity, previous_end = None, None
    for entry in entries:
        phase = entry['phase']
        result = Path(entry['result']).resolve(strict=True)
        result_digest = digest(result)
        if result in seen_paths or result_digest in seen_digests:
            raise ValueError(f'Duplicate coverage input: {result}')
        seen_paths.add(result)
        seen_digests.add(result_digest)
        per_input = inputs_output / phase
        per_input.mkdir()
        if manifest:
            receipt = read(entry['receipt'])
            write(per_input / 'receipt.json', receipt)
            if phase == 'ios':
                expected = discovery_tests(read(receipt['discovery']))
                if not set(phases['shared_pro_tests']).issubset(expected) or any(
                        not test.startswith('CodexBarIOSTests/') or '/StoreKitPro' in test
                        and test.split('/')[1] in ('StoreKitProPreparationTests', 'StoreKitProStoreSourceTests',
                                                  'StoreKitProFailureTests', 'StoreKitProSubscriptionTests',
                                                  'StoreKitProStorefrontTests') for test in expected):
                    raise ValueError('Ordinary iOS discovery omits shared Pro cases or includes specialized cases')
            else:
                expected = phases['phases'][phase]['tests']
            validate_receipt(receipt, source, tools, expected, phase, result)
            require_pinned(tools, receipt['device'])
            if phase != 'ios':
                identity = (receipt['device']['deviceId'], receipt['build_sha256'])
                if native_identity is not None and native_identity != identity:
                    raise ValueError('Native preparations and consumers must share one device and build')
                if previous_end and datetime.fromisoformat(receipt['started']) < previous_end:
                    raise ValueError('Native phases did not execute in preparation/consumption order')
                native_identity = identity
                previous_end = datetime.fromisoformat(receipt['ended'])
            device_runtime = {key: receipt['device'][key] for key in ('osVersion', 'osBuildNumber', 'architecture', 'platform')}
            if runtime is not None and runtime != device_runtime:
                raise ValueError('Mixed runtime/platform/architecture coverage inputs')
            runtime = device_runtime
        # xcresulttool may write lazy indexes even for read/export commands.
        # Authenticate the producer's bundle first, then inspect an exact copy.
        inspection = per_input / 'inspection.xcresult'
        shutil.copytree(result, inspection, symlinks=True)
        if digest(inspection) != result_digest:
            raise ValueError(f'Inspection copy differs from coverage input: {result}')
        summary = json.loads(run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(inspection)]))
        tests = json.loads(run(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(inspection)]))
        write(per_input / 'test-summary.json', summary)
        write(per_input / 'tests.json', tests)
        if manifest:
            validate_results(summary, tests, expected, receipt['device'], receipt['started'], receipt['ended'])
        else:
            identities = validate_results(summary, tests)
            expected_platform, bundle = ('watchOS Simulator', 'CodexBarWatchTests/') if args.platform == 'watch' else ('iOS Simulator', 'CodexBarIOSTests/')
            if summary['devicesAndConfigurations'][0]['device']['platform'] != expected_platform or not all(
                    identity.startswith(bundle) for identity in identities):
                raise ValueError('Single-result test execution does not match the requested platform/bundle')
        report_path, archive_path = export_pair(inspection, per_input / 'raw', run)
        coverage = json.loads(run(['xcrun', 'xccov', 'view', '--json', str(report_path)]))
        write(per_input / 'coverage.json', coverage)
        index = coverage_index(coverage, root, source_paths)
        require_counters(index, [policy['platforms'][args.platform]['coverage_targets'][0]], covered=True)
        indexes.append(index)
        pairs.extend([str(report_path), str(archive_path)])
        evidence.append(dict(phase=phase, result=str(result), result_sha256=result_digest,
                             report=str(report_path), report_sha256=digest(report_path),
                             archive=str(archive_path), archive_sha256=digest(archive_path),
                             tests=summary['totalTestCount'], producer_attested=bool(manifest)))
        if digest(result) != result_digest:
            raise ValueError(f'Attested result changed during coverage collection: {result}')
        write(per_input / 'inspection.json', dict(original=str(result), original_sha256=result_digest,
              inspection=str(inspection), initial_sha256=result_digest, final_sha256=digest(inspection)))
        # Keep a failed inspection copy for diagnosis; successful inputs already
        # retain their source bundle, summaries and raw coverage pair.
        shutil.rmtree(inspection)
        write(output / 'coverage-inputs.json', evidence)
    validate_union(indexes, None)
    if manifest:
        merged_report, merged_archive = output / 'merged.xccovreport', output / 'merged.xccovarchive'
        command = ['xcrun', 'xccov', 'merge', '--outReport', str(merged_report),
                   '--outArchive', str(merged_archive), *pairs]
        write(output / 'merge-command.json', command)
        run(command)
        coverage = json.loads(run(['xcrun', 'xccov', 'view', '--json', str(merged_report)]))
        write(output / 'merge-artifacts.json', dict(report_sha256=digest(merged_report), archive_sha256=digest(merged_archive)))
    merged_index = coverage_index(coverage, root, source_paths)
    validate_union(indexes, merged_index)
    require_counters(merged_index, policy['platforms'][args.platform]['coverage_targets'])
    write(output / 'coverage.json', coverage)
    # Keep the legacy summary artifact for the single-result watch/iOS caller.
    if not manifest:
        write(output / 'test-summary.json', summary)
    return coverage, evidence
