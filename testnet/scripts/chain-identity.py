#!/usr/bin/env python3
"""Validate public cut identity and bootstrap declarations without evaluating files."""
import argparse
import json
import os
from pathlib import Path
import re
import sys


def value(path, key):
    rows = []
    for line in Path(path).read_text().splitlines():
        match = re.match(r'^\s*(?:export\s+)?' + re.escape(key) + r'\s*=(.*)$', line)
        if match:
            raw = match.group(1).strip()
            if raw.startswith(('"', "'")):
                quote = raw[0]
                end = raw.find(quote, 1)
                if end < 0 or raw[end + 1:].strip().split('#', 1)[0].strip():
                    raise ValueError('malformed chain selector')
                raw = raw[1:end]
            else:
                raw = re.split(r'\s+#', raw, maxsplit=1)[0].strip()
            rows.append(raw)
    if len(rows) > 1:
        raise ValueError('duplicate chain selector')
    return rows[0] if rows else ''


def chain_pin(path):
    pin = value(path, 'WRFCOIN_CUT_CHAIN_ID')
    if not re.fullmatch(r'[1-9][0-9]*', pin):
        raise ValueError('cut pins require a positive integer WRFCOIN_CUT_CHAIN_ID')
    return pin


def validate(pin, env_file):
    # Check the persisted file even when the invoking shell masks stale values.
    declared = value(env_file, 'WRFCOIN_CHAIN_ID') or '777'
    if declared != pin:
        raise ValueError('persisted WRFCOIN_CHAIN_ID differs from cut pins (absent/empty defaults to 777)')
    exported = os.environ.get('WRFCOIN_CHAIN_ID')
    if exported is not None and (exported or '777') != pin:
        raise ValueError('exported WRFCOIN_CHAIN_ID differs from cut pins')
    for governance in [value(env_file, 'WRFCOIN_GOVERNANCE_CHAIN_ID'),
                       os.environ.get('WRFCOIN_GOVERNANCE_CHAIN_ID', '')]:
        if governance and governance != pin:
            raise ValueError('WRFCOIN_GOVERNANCE_CHAIN_ID differs from cut pins; update it with WRFCOIN_CHAIN_ID')


def bootstrap_inputs(path, pin):
    if pin == '777':
        return {}
    if pin != '888':
        raise ValueError('bootstrap declarations support only chain 777 or 888')
    keys = {'WRFCOIN_GENESIS_HASH': 'WRFCOIN_CUT_GENESIS_HASH',
            'WRFCOIN_GENESIS_ACTIVATION_SCHEDULE': 'WRFCOIN_GENESIS_ACTIVATION_SCHEDULE',
            'WRFCOIN_GENESIS_PRODUCER_SET': 'WRFCOIN_GENESIS_PRODUCER_SET'}
    result = {'WRFCOIN_CHAIN_ID': pin}
    for runtime, source in keys.items():
        declared = value(path, source)
        if not declared.strip() or any(c in declared for c in '<>\r\n'):
            raise ValueError(source + ' is missing or still a placeholder for chain 888')
        result[runtime] = declared
    if not re.fullmatch(r'(?:0x)?[0-9a-f]{64}', result['WRFCOIN_GENESIS_HASH']):
        raise ValueError('WRFCOIN_CUT_GENESIS_HASH must be a reviewed 64-hex hash')
    if result['WRFCOIN_GENESIS_HASH'].removeprefix('0x') == '0' * 64:
        raise ValueError('WRFCOIN_CUT_GENESIS_HASH must be nonzero for join/operator startup')
    if not re.fullmatch(r'[0-9]+:[a-zA-Z_][a-zA-Z_0-9]*(?:,[0-9]+:[a-zA-Z_][a-zA-Z_0-9]*)*',
                        result['WRFCOIN_GENESIS_ACTIVATION_SCHEDULE']):
        raise ValueError('WRFCOIN_GENESIS_ACTIVATION_SCHEDULE must be an inline activation schedule')
    try:
        producers = json.loads(result['WRFCOIN_GENESIS_PRODUCER_SET'])
    except ValueError:
        raise ValueError('WRFCOIN_GENESIS_PRODUCER_SET must be inline public JSON') from None
    if not isinstance(producers, dict) or producers.get('version') != 1 or not producers.get('members'):
        raise ValueError('WRFCOIN_GENESIS_PRODUCER_SET needs version 1 and nonempty members')
    return result


def persist_bootstrap(path, declarations):
    if not declarations:
        return
    target = Path(path)
    rows = target.read_text().splitlines()
    # Only these public keys are replaced; preserve unrelated settings, and
    # keep producer JSON literal through Compose's .env interpolation.
    rows = [row for row in rows if not any(re.match(r'^\s*(?:export\s+)?' + key + r'\s*=', row)
                                         for key in declarations)]
    for key, declared in declarations.items():
        rows.append(key + "='" + declared.replace("'", "\\'") + "'")
    target.write_text('\n'.join(rows) + '\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pins', required=True)
    parser.add_argument('--env')
    parser.add_argument('--print-chain', action='store_true')
    parser.add_argument('--bootstrap-env', metavar='FILE',
                        help='persist reviewed 888 public inputs and print literal KEY=VALUE exports; no-op at 777')
    args = parser.parse_args()
    try:
        pin = chain_pin(args.pins)
        if args.bootstrap_env:
            declarations = bootstrap_inputs(args.pins, pin)
            persist_bootstrap(args.bootstrap_env, declarations)
            for key, declared in declarations.items():
                print(key + '=' + declared)
            return 0
        if args.env:
            validate(pin, args.env)
        elif 'WRFCOIN_CHAIN_ID' in os.environ and os.environ['WRFCOIN_CHAIN_ID'] != pin:
            raise ValueError('configured WRFCOIN_CHAIN_ID differs from cut pins')
        print(pin if args.print_chain else 'PASS: persisted and exported chain identities match cut pins')
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        # OSError messages may contain paths; identity values and file contents never leave here.
        print('ERROR chain identity: ' + (str(error) if isinstance(error, ValueError) else 'cannot read identity inputs'), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
