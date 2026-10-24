#!/usr/bin/env python3
"""Manual-only UI shard execution and fail-closed cross-worker proof aggregation."""
import argparse
import copy
from datetime import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from pro_release_runner import Runner, PhaseFailure, claim_native_device, command, persist, provision, sequence, shutdown
from release_evidence import ROOT, digest, load_manifest, now, read, require_pinned, source_snapshot, toolchain, write

PLAN = ROOT / 'scripts/ui-release-shards.json'
SHARDS = ('original-1', 'original-2', 'original-3', 'supplemental', 'synthetic', 'native')
FAMILIES = ('iphone', 'ipad')


def load_plan():
    manifest, plan = load_manifest(), read(PLAN)
    if plan.get('schema') != 1 or tuple(plan.get('shards', {})) != SHARDS:
        raise ValueError('UI shard inventory differs from the manual matrix')
    result = {}
    for name, config in plan['shards'].items():
        if name.startswith('original-'):
            if config.get('phase') != 'ui-original':
                raise ValueError('Original shards must select original journeys')
            tests = config.get('tests', [])
            if not tests or len(tests) != len(set(tests)):
                raise ValueError('Empty or duplicate original shard selectors')
            result[name] = [('ui-original', sorted(tests))]
        else:
            expected = (['ui-supplemental'] if name == 'supplemental' else ['ui-synthetic'] if name == 'synthetic'
                        else ['ui-preparation', 'ui-native', 'ui-error-preparation', 'ui-native-purchase-error', 'ui-reset'])
            selected = ([config.get('phase')] if 'phase' in config else config.get('phases', []) + [config.get('cleanup')])
            if selected != expected:
                raise ValueError('Missing, reordered or unexpected shard phases')
            result[name] = [(phase, sorted(manifest['phases'][phase]['tests'])) for phase in expected]
    original = [test for name in SHARDS[:3] for _, tests in result[name] for test in tests]
    if sorted(original) != sorted(manifest['phases']['ui-original']['tests']):
        raise ValueError('Original shard partition omitted, duplicated or substituted a journey')
    return result


def fingerprint(source):
    return hashlib.sha256(json.dumps(source['files'], sort_keys=True).encode()).hexdigest()


def execute(runner, name, phases):
    native = name == 'native'
    scheme = runner.manifest['phases'][phases[0][0]]['scheme']
    selectors = sorted({test for _, tests in phases for test in tests})
    runner.manifest = copy.deepcopy(runner.manifest)
    for phase, tests in phases:
        runner.manifest['phases'][phase].update(tests=tests, count=len(tests))
    build = runner.build(name, scheme, selectors, native=native)
    if native:
        state = sequence([phase for phase, _ in phases[:-1]], lambda phase: runner.phase(phase, build),
                         lambda: runner.phase('ui-reset', build))
        if state['exit']:
            raise PhaseFailure(state['primaryFailure'] or state['cleanupFailure'], state['exit'])
    else:
        runner.phase(phases[0][0], build)


def validate_proof(proof, source, family, name, phases):
    if (proof.get('schema') != 1 or proof.get('complete') is not True or proof.get('shutdown') is not True
            or proof.get('revision') != source['revision'] or source['status']
            or proof.get('sourceFingerprint') != fingerprint(source)
            or proof.get('family') != family or proof.get('shard') != name):
        raise ValueError('Incomplete, stale or substituted shard proof')
    device = proof['device']
    require_pinned(proof['tools'], device)
    if device['family'] != family or device['architecture'] != 'arm64' or device['platform'] != 'iOS Simulator':
        raise ValueError('Shard device family/platform differs')
    rows = proof['phases']
    if [(row['phase'], row['tests']) for row in rows] != phases:
        raise ValueError('Shard execution identities or schedule differ')
    start, end = datetime.fromisoformat(proof['started']), datetime.fromisoformat(proof['ended'])
    if end < start:
        raise ValueError('Shard time interval is reversed')
    previous = start
    for row in rows:
        a, b = datetime.fromisoformat(row['started']), datetime.fromisoformat(row['ended'])
        if not previous <= a <= b <= end or len(row['receiptSha256']) != 64:
            raise ValueError('Shard phase time/provenance differs')
        previous = b


def run_shard(output, family, name):
    output.mkdir(parents=True, exist_ok=False)
    failure, runner, device, source, tools = None, None, None, None, None
    started = now()
    phases = load_plan()[name]
    try:
        source, tools = source_snapshot(), toolchain()
        require_pinned(tools)
        write(output / 'source.json', source)
        write(output / 'toolchain.json', tools)
        device = provision(output, family, tools)
        require_pinned(tools, device)
        write(output / 'device.json', device)
        command(output, 'boot-device', ['xcrun', 'simctl', 'boot', device['deviceId']])
        command(output, 'boot-ready', ['xcrun', 'simctl', 'bootstatus', device['deviceId'], '-b'])
        if name == 'native':
            claim_native_device(output / 'ownership.json', output, device)
        runner = Runner(output, device, source, tools)
        execute(runner, name, phases)
        if [row['phase'] for row in runner.receipts] != [phase for phase, _ in phases]:
            raise ValueError('Shard completed without all required phases')
        runner.unchanged()
    except (PhaseFailure, ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        failure = error if isinstance(error, PhaseFailure) else PhaseFailure(str(error))
    finally:
        if device:
            try:
                shutdown(output, device)
            except (PhaseFailure, ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
                failure = failure or PhaseFailure(str(error))
    if failure is None:
        try:
            rows = [read(item['receipt']) for item in runner.receipts]
            proof = dict(schema=1, complete=True, shutdown=True, started=started, ended=now(),
                         revision=source['revision'], sourceFingerprint=fingerprint(source), tools=tools,
                         device=device, family=family, shard=name,
                         phases=[dict(phase=row['phase'], tests=row['executedTests'], started=row['started'], ended=row['ended'],
                                      receiptSha256=digest(item['receipt'])) for row, item in zip(rows, runner.receipts)])
            validate_proof(proof, source, family, name, phases)
            write(output / 'proof.json', proof)
        except (ValueError, KeyError, TypeError, OSError) as error:
            failure = PhaseFailure(str(error))
    failure = persist(output / 'outcome.json', dict(complete=failure is None, exit=failure.code if failure else 0,
                      error=str(failure) if failure else None, started=started, ended=now()), failure)
    if failure:
        print(str(failure), file=sys.stderr)
    return failure.code if failure else 0


def aggregate(directory, source):
    plan = load_plan()
    expected = {(family, name) for family in FAMILIES for name in SHARDS}
    proofs = [read(path) for path in directory.rglob('proof.json')]
    keys = [(proof.get('family'), proof.get('shard')) for proof in proofs]
    if len(keys) != len(expected) or set(keys) != expected:
        raise ValueError('Missing, duplicate or unexpected UI shard proofs')
    devices = [proof['device']['deviceId'] for proof in proofs]
    if len(devices) != len(set(devices)):
        raise ValueError('Each UI shard requires a newly owned simulator')
    for proof in proofs:
        family, name = proof['family'], proof['shard']
        validate_proof(proof, source, family, name, plan[name])
    return dict(complete=True, revision=source['revision'], families=list(FAMILIES), shards=len(proofs),
                journeysPerFamily=sum(load_manifest()['phases'][phase]['count'] for phase in load_manifest()['ui_journeys']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['run', 'aggregate'])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--family', choices=FAMILIES)
    parser.add_argument('--shard', choices=SHARDS)
    parser.add_argument('--proofs', type=Path)
    args = parser.parse_args()
    try:
        if args.mode == 'run':
            if not args.family or not args.shard:
                raise ValueError('A shard and family are required')
            return run_shard(args.output.resolve(), args.family, args.shard)
        if args.proofs is None:
            raise ValueError('Proof directory is required')
        result = aggregate(args.proofs, source_snapshot())
        with args.output.open('x') as stream:
            json.dump(result, stream, indent=2)
        print(json.dumps(result))
        return 0
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
