#!/usr/bin/env python3
"""Independently verify the retained summary/tree/receipt for one manual phase."""
import argparse
from pathlib import Path
import sys

from release_evidence import (digest, discovery_tests, load_manifest, read, source_snapshot,
                              toolchain, validate_receipt, validate_results)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('receipt', type=Path)
    args = parser.parse_args()
    receipt = read(args.receipt)
    phases = load_manifest()['phases']
    expected = phases[receipt['phase']]['tests'] if receipt['phase'] in phases else discovery_tests(read(receipt['discovery']))
    validate_receipt(receipt, source_snapshot(), toolchain(), expected, receipt['phase'], Path(receipt['result']))
    folder = args.receipt.parent
    validate_results(read(folder / 'summary.json'), read(folder / 'tests.json'), expected,
                     receipt['device'], receipt['started'], receipt['ended'])
    print(f'{receipt["phase"]}: {len(expected)} exact tests passed; receipt SHA-256 {digest(args.receipt)}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
