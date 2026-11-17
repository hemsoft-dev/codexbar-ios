#!/usr/bin/env python3
"""Supplementary #573 diagnostic, never ordinary/native/coverage/release qualification.

Provision a fresh destination with run-pro-release-validation.sh provision first.
On a local device host, bind it through the advertised device tools before testing.
Hosted workflow_dispatch uses the existing project-owned provision/test route.
The default is one attempt; --attempts 2/3 measures a bounded experiment, stopping
at the first failure. Never reuse its output directory or claimed destination.
"""
import argparse
from datetime import datetime
from pathlib import Path
import subprocess
import sys

import pro_release_runner as project
import release_evidence as evidence

SELECTOR = ('CodexBarIOSTests/SubscriptionBillingTests/'
            'testFailedCredentialHasFiniteAutomaticBudgetAndManualRetry')
SCHEMA = 'codexbar.billing-retry-diagnostic.v1'


def diagnostic_record(**fields):
    return dict(schema=SCHEMA, diagnosticOnly=True, qualifiesRelease=False,
                qualifiesOrdinary=False, qualifiesNative=False, qualifiesCoverage=False, **fields)


def failure(error):
    return (error if isinstance(error, project.PhaseFailure)
            else project.PhaseFailure(str(error), getattr(error, 'returncode', 1)))


def validate_result(summary, tree, device, started, ended):
    """Accept exactly the selected case, including a real red measurement."""
    cases = evidence.result_cases(tree)
    if len(cases) != 1 or cases[0][0] != SELECTOR:
        raise ValueError('Diagnostic must execute exactly the fixed billing retry selector')
    status = cases[0][1]
    if status == 'Passed':
        evidence.validate_results(summary, tree, [SELECTOR], device, started, ended)
    elif status == 'Failed':
        counts = dict(totalTestCount=1, passedTests=0, failedTests=1, skippedTests=0, expectedFailures=0)
        if summary.get('result') != 'Failed' or not summary.get('testFailures'):
            raise ValueError('Failed case lacks a matching failure summary')
        for key, value in counts.items():
            if type(summary.get(key)) is not int or summary[key] != value:
                raise ValueError(f'Invalid diagnostic failure count: {key}')
        configurations = summary['devicesAndConfigurations']
        if len(configurations) != 1 or len(tree['devices']) != 1:
            raise ValueError('Diagnostic requires one configuration and destination')
        evidence.validate_device(configurations[0]['device'], device)
        evidence.validate_device(tree['devices'][0], device)
        for key in ('passedTests', 'failedTests', 'skippedTests', 'expectedFailures'):
            if configurations[0].get(key) != counts[key]:
                raise ValueError(f'Inconsistent diagnostic device count: {key}')
        start, finish = summary['startTime'], summary['finishTime']
        if not start or finish < start or start < datetime.fromisoformat(started).timestamp() - 2:
            raise ValueError('Diagnostic result predates its invocation')
        if finish > datetime.fromisoformat(ended).timestamp() + 2:
            raise ValueError('Diagnostic result ends after its invocation')
    else:
        raise ValueError(f'Skipped/unknown diagnostic case result: {status}')
    return status


def attempt(runner, build_path, number):
    folder = runner.output / f'attempt-{number}'
    folder.mkdir()
    result = folder / 'result.xcresult'
    build = evidence.read(build_path)
    receipt = diagnostic_record(attempt=number, selector=SELECTOR, source=runner.source,
                                tools=runner.tools, device=runner.device, started=evidence.now(),
                                result=str(result), buildReceipt=str(build_path),
                                build_sha256=evidence.digest(build_path), verdict='execution-failure')
    primary = None
    try:
        runner.unchanged()
        if build['source'] != runner.source or build['tools'] != runner.tools or build['exit'] != 0:
            raise ValueError('Diagnostic build identity/result changed')
        if not build['binaries'] or any(evidence.digest(b['path']) != b['sha256'] for b in build['binaries']):
            raise ValueError('Diagnostic build binaries changed')
        argv = runner.arguments('CodexBarIOS', Path(build['derivedData']), [SELECTOR])
        argv += ['-resultBundlePath', str(result), 'test-without-building']
        receipt['command'] = argv
        try:
            receipt.update(project.command(folder, 'xcodebuild', argv))
        except (project.PhaseFailure, OSError) as error:
            primary = failure(error)
            receipt['executionError'] = str(error)
        receipt['ended'] = evidence.now()
        exported = {}
        for name in ('summary', 'tests'):
            try:
                exported[name] = project.json_command(folder, name, [
                    'xcrun', 'xcresulttool', 'get', 'test-results', name, '--path', str(result)])
            except (project.PhaseFailure, ValueError, OSError) as error:
                receipt[name + 'Error'] = str(error)
                primary = primary or failure(error)
        if len(exported) == 2:
            try:
                status = validate_result(exported['summary'], exported['tests'], runner.device,
                                         receipt['started'], receipt['ended'])
                receipt['testResult'] = status
                receipt['executedTests'] = [SELECTOR]
                receipt['durationSeconds'] = exported['summary']['finishTime'] - exported['summary']['startTime']
                receipt['failures'] = exported['summary'].get('testFailures', [])
                if status == 'Failed':
                    receipt['verdict'] = 'test-failure'
                    primary = primary or project.PhaseFailure('Focused billing retry assertion failed')
                elif primary is None:
                    receipt['verdict'] = 'passed'
            except (ValueError, KeyError, TypeError) as error:
                receipt['validationError'] = str(error)
                primary = primary or failure(error)
        log = folder / 'xcodebuild.log'
        if log.exists():
            # Existing Swift failure-only operands; no new business logic or telemetry.
            with log.open(errors='replace') as stream:
                trace = [line for line in stream if '[DEBUG-ios573]' in line]
            (folder / 'operand-trace.log').write_text(''.join(trace))
            receipt['operandTraceLines'] = len(trace)
        runner.unchanged()
    except (project.PhaseFailure, ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        receipt['error'] = str(error)
        primary = primary or failure(error)
    receipt.setdefault('ended', evidence.now())
    if primary and receipt['verdict'] == 'passed':
        receipt['verdict'] = 'execution-failure'
    receipt['exit'] = primary.code if primary else 0
    primary = project.persist(folder / 'diagnostic.json', receipt, primary)
    if primary:
        raise primary
    return receipt


def experiment(runner, maximum):
    if type(maximum) is not int or not 1 <= maximum <= 3:
        raise ValueError('A diagnostic experiment permits one to three attempts')
    build = runner.build('billing-retry', 'CodexBarIOS', [SELECTOR])
    record = evidence.read(build)
    discovery = runner.arguments('CodexBarIOS', Path(record['derivedData']), [SELECTOR]) + [
        'test-without-building', '-enumerate-tests', '-test-enumeration-style', 'flat',
        '-test-enumeration-format', 'json', '-test-enumeration-output-path',
        str(runner.output / 'discovery.json')]
    project.command(runner.output, 'discovery', discovery)
    if evidence.discovery_tests(evidence.read(runner.output / 'discovery.json')) != [SELECTOR]:
        raise ValueError('Focused diagnostic discovery differs from the fixed selector')
    for number in range(1, maximum + 1):
        attempt(runner, build, number)  # first red/error propagates; no later attempt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ownership', type=Path, required=True,
                        help='Fresh project provision ownership.json; never a foreign/reused destination')
    parser.add_argument('--attempts', type=int, choices=(1, 2, 3), default=1)
    args = parser.parse_args(argv)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    outcome = diagnostic_record(selector=SELECTOR, requestedAttempts=args.attempts, exit=1,
                                experimentComplete=False, deviceReusable=False, started=evidence.now())
    primary, claimed, device = None, False, None
    try:
        evidence.write(output / 'outcome.json', outcome)
        source, tools = evidence.source_snapshot(), evidence.toolchain()
        evidence.write(output / 'source.json', source)
        evidence.write(output / 'toolchain.json', tools)
        device = project.owned_device(args.ownership.resolve(), tools)
        evidence.require_pinned(tools, device)
        if device['family'] != 'iphone':
            raise ValueError('Billing diagnostic requires an owned qualified iPhone destination')
        project.claim_native_device(args.ownership.resolve(), output, device)
        claimed = True
        evidence.write(output / 'device.json', device)
        runner = project.Runner(output, device, source, tools, args.ownership)
        experiment(runner, args.attempts)
        outcome.update(exit=0, experimentComplete=True)
    except (project.PhaseFailure, ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        primary = failure(error)
        outcome.update(exit=primary.code, error=str(error))
    finally:
        if claimed:
            try:
                project.shutdown(output, device)
            except (project.PhaseFailure, ValueError, KeyError, TypeError, OSError,
                    subprocess.CalledProcessError) as error:
                outcome['shutdownFailure'] = str(error)
                primary = primary or failure(error)
                outcome.update(exit=primary.code, experimentComplete=False)
        outcome.update(ended=evidence.now(), attemptsRecorded=len(list(output.glob('attempt-*/diagnostic.json'))))
        if primary and claimed:
            primary = project.persist(output / 'quarantine.json', diagnostic_record(
                reason=str(primary), ownership=str(args.ownership), deviceReusable=False), primary)
        primary = project.persist(output / 'outcome.json', outcome, primary)
    return primary.code if primary else outcome['exit']


if __name__ == '__main__':
    sys.exit(main())
