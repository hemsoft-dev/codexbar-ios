#!/usr/bin/env python3
"""Record and assert the installed toolchain/runtime for existing manual jobs."""
import argparse
import json
from pathlib import Path
import sys

from release_evidence import capture, now, require_pinned, toolchain


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--watch-device')
    args = parser.parse_args()
    evidence = dict(observedAt=now(), tools=toolchain(), runtimes=json.loads(capture(['xcrun', 'simctl', 'list', 'runtimes', '--json'])))
    evidence['watchSDK'] = capture(['xcrun', '--sdk', 'watchsimulator', '--show-sdk-version'])
    error = None
    try:
        require_pinned(evidence['tools'])
        if evidence['watchSDK'] != '26.5':
            raise ValueError('Expected watchOS simulator SDK 26.5')
        for platform in ('iOS', 'watchOS'):
            if not any(runtime['isAvailable'] and runtime['version'] == '26.5' and
                       runtime['identifier'].startswith(f'com.apple.CoreSimulator.SimRuntime.{platform}-')
                       for runtime in evidence['runtimes']['runtimes']):
                raise ValueError(f'Missing installed {platform} 26.5 simulator runtime')
        if args.watch_device:
            devices = json.loads(capture(['xcrun', 'simctl', 'list', 'devices', '--json']))
            matches = [runtime for runtime in evidence['runtimes']['runtimes']
                       if any(device['udid'] == args.watch_device and device['isAvailable']
                              for device in devices['devices'].get(runtime['identifier'], []))]
            if len(matches) != 1 or matches[0]['version'] != '26.5' or 'watchOS-' not in matches[0]['identifier']:
                raise ValueError('Selected watch simulator is not on the qualified 26.5 runtime')
            evidence['selectedWatch'] = dict(deviceId=args.watch_device, runtime=matches[0])
    except ValueError as caught:
        error = caught
        evidence['error'] = str(caught)
    with args.output.open('x') as stream:
        json.dump(evidence, stream, indent=2)
        stream.write('\n')
    print(json.dumps(evidence, indent=2))
    if error:
        raise error


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
