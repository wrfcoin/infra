#!/usr/bin/env python3
"""Owner-only mobile station activation. Stdlib; all tool output stays private."""
import argparse
import email.utils
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import shlex
import stat
import subprocess
import tempfile
from urllib.parse import urlsplit

# core4#3388: CALIBRATED_MOBILE_STATION_BATCH_ROWS; actual CLI bytes remain authoritative.
CHAIN_ID = os.environ.get('WRFCOIN_CHAIN_ID', '777')
SAFE_ROWS = 21
MAX_BYTES = 65536
WINDOW = 150
BUILD_AGE = 100
SUBMIT_AGE = 120
CLI_SHA = '604af0308e57d9ae82b75da9b8845fb7f440e2ed55a7f15671dd92d4b0d0a3d7'
# core4 release every producer must run before anything is signed or submitted.
RELEASE_REVISION = '620902bf7b01cf09b11b2bb0ff5a22571e7cb694'
REVISION_LABEL = 'org.opencontainers.image.revision'
PRODUCER_COUNT = 3
PUBLIC_PATHS = ('/readyz', '/network/info')  # tokenless on core4 620902bf7
GOV = 'e7bec166ad446314d26fb7526bfa8cec1b363b438440262fb001f7b04b20bf00'
ROW_KEYS = {'station_id', 'owner_address', 'owner_pubkey', 'owner_signature',
            'latitude', 'longitude', 'hardware_model', 'provenance_class',
            'data_quality_tier', 'submitted_at'}


class Stop(Exception):
    """Only fixed stage descriptions may be surfaced to the terminal."""


class Unverified(Stop):
    """Rows are on the node but nothing proves THIS run's registration applied."""


class PrivateParser(argparse.ArgumentParser):
    def error(self, _message):
        self.exit(2, 'ACTIVATION STOP: invalid arguments; use --help\n')


def require(condition, stage):
    if not condition:
        raise Stop(stage)


def command(args, stage, input_text=None, timeout=30, env=None):
    try:
        result = subprocess.run(args, input=input_text, text=True, capture_output=True,
                                timeout=timeout, env=env, check=False)
    except (OSError, subprocess.SubprocessError):
        raise Stop(stage) from None
    require(result.returncode == 0, stage)
    return result.stdout


def now():
    raw = command(['date', '+%s'], 'clock read failed', timeout=5).strip()
    require(re.fullmatch(r'[0-9]{1,15}', raw), 'clock read invalid')
    return int(raw)


def age(stamp):
    elapsed = now() - stamp
    require(0 <= elapsed <= WINDOW, 'stale window or clock moved backwards; no submission')
    return elapsed


def write_json(path, value):
    with path.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, separators=(',', ':'))
    require(stat.S_IMODE(path.stat().st_mode) == 0o600, 'private file mode invalid')


def container_env(container):
    raw = command(['docker', 'inspect', '--format', '{{json .Config.Env}}', container],
                  'container preflight failed')
    values = json.loads(raw)
    require(isinstance(values, list) and all(isinstance(v, str) for v in values),
            'container environment invalid')
    return dict(v.split('=', 1) for v in values if '=' in v)


def loopback_host(host):
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return host == 'localhost'


def http(args, directory, token, method, path, body=None, stamp=None):
    # Bearer secret in config stdin only, never argv, file or an exported variable.
    # Public routes (/readyz, /network/info) carry NO Authorization at all.
    public = path in PUBLIC_PATHS
    config = None if public else 'header = ' + json.dumps('Authorization: Bearer ' + token) + '\n'
    response = directory / 'http.json'
    headers = directory / 'http.headers'
    timeout = 10
    if stamp is not None:
        elapsed = age(stamp)
        require(elapsed <= SUBMIT_AGE, 'submit budget exceeded; no submission')
        timeout = min(timeout, WINDOW - elapsed)
    argv = ['curl', '--silent', '--show-error', '--noproxy', '*', '--proto', '=http,https',
            '--connect-timeout', '3', '--max-time', str(timeout)]
    if config is not None:
        argv += ['--config', '-']
    argv += ['--request', method, '--output', str(response),
            '--dump-header', str(headers), '--write-out', '%{http_code}']
    if loopback_host(urlsplit(args.node_url).hostname):
        argv += ['--header', 'Host: 127.0.0.1']
    if body is not None:
        argv += ['--header', 'Content-Type: application/json', '--data-binary', '@' + str(body)]
    argv += [args.node_url.rstrip('/') + path]
    status = command(argv, 'HTTP transport indeterminate; read back before any new run',
                     input_text=config, timeout=timeout + 2).strip()
    require(re.fullmatch(r'[0-9]{3}', status), 'HTTP status invalid')
    data = json.loads(response.read_text())
    return int(status), data, headers.read_text()


def data_object(value):
    require(isinstance(value, dict), 'response shape invalid')
    require(value.get('success', True) is not False and value.get('ok', True) is not False,
            'response refused')
    return value.get('data', value)


def node_json(args, directory, token, path):
    """GET `path`; (status, parsed JSON or None). Any transport problem stops the run."""
    status, response, _ = http(args, directory, token, 'GET', path)
    return status, response


def registration_format(args, directory, token):
    """v1 or v2: which governance registration format the node accepts right now.

    `auto` reads the node's active features (the height the next block mines at),
    so it stays v1 until the feature has actually activated. From `station_registration_nonce` the v1 format is refused entirely and v2
    (a signed `expected_nonce`) is required; before it, v2 is refused. An
    explicit `--registration-format` overrides, for a deliberate rehearsal.
    """
    if args.registration_format in ('v1', 'v2'):
        return args.registration_format
    status, response = node_json(args, directory, token, '/transactions/oracle/status')
    require(status == 200, 'feature read refused; cannot choose the registration format')
    features = data_object(response).get('active_features')
    require(isinstance(features, list) and all(isinstance(f, str) for f in features),
            'feature read shape invalid; cannot choose the registration format')
    return 'v2' if 'station_registration_nonce' in features else 'v1'


NOT_REGISTERED = 'station is not registered'


def ledger_read(args, directory, token, station_id):
    """(fresh, owner_ledger) for a station, read from the node right now.

    `fresh` is True when the node says the station is not registered (no ledger
    entry; the first registration uses nonce 0). Anything else (transport error,
    other status, unknown route, wrong shape, a negative or non-integer nonce,
    another station's answer) is a refusal: a guessed nonce would be mined as a
    silent no-op.
    """
    status, response = node_json(
        args, directory, token,
        '/transactions/station/registrations/' + station_id + '/owner-ledger')
    if status == 404:
        error = response.get('error') if isinstance(response, dict) else None
        require(isinstance(error, dict) and error.get('code') == 'NOT_FOUND' and
                isinstance(error.get('message'), str) and NOT_REGISTERED in error['message'],
                'owner-ledger read failed (unknown route or node?); no nonce, nothing signed')
        return True, None
    require(status == 200, 'owner-ledger read refused; no nonce, nothing signed')
    value = data_object(response)
    ledger = value.get('owner_ledger')
    nonce = ledger.get('owner_nonce') if isinstance(ledger, dict) else None
    require(value.get('station_id') == station_id and type(nonce) is int and 0 <= nonce < 2**64,
            'owner-ledger shape invalid; no nonce, nothing signed')
    return False, ledger


def expected_nonce(args, directory, token, station_id):
    """The station's CURRENT owner-ledger nonce (0 for a not-yet-registered one)."""
    fresh, ledger = ledger_read(args, directory, token, station_id)
    return 0 if fresh else ledger['owner_nonce']


def add_nonces(args, directory, token, rows):
    """Stamp every given row with its freshly read `expected_nonce` (v2 only)."""
    for row in rows:
        fresh, ledger = ledger_read(args, directory, token, row['station_id'])
        row['expected_nonce'] = 0 if fresh else ledger['owner_nonce']
    print(f'NONCES: read {len(rows)} fresh owner-ledger nonces')


def cli_artifact(args, directory, rows, expected_count):
    """Run the CLI once over `rows`; return its validated artifact transactions."""
    batch = directory / 'cli.json'
    artifact = directory / 'artifact.json'
    batch.unlink(missing_ok=True)
    artifact.unlink(missing_ok=True)
    write_json(batch, rows)
    env = dict(os.environ, WRFCOIN_ORACLE_GOVERNANCE_PUBKEYS=args.governance_pubkey)
    raw = command([args.cli, 'station', 'build-registration', '--batch', str(batch),
                   '--governance-key', args.governance_key, '--chain-id', CHAIN_ID,
                   '--network-id', 'testnet', '--out', str(artifact)],
                  'CLI build failed; nothing submitted', timeout=60, env=env)
    require(data_object(json.loads(raw)).get('self_verified') is True,
            'CLI self-verification failed')
    require(artifact.is_file() and stat.S_IMODE(artifact.stat().st_mode) == 0o600,
            'artifact missing or mode invalid')
    require(artifact.stat().st_size <= MAX_BYTES, 'signed artifact exceeds byte cap')
    value = json.loads(artifact.read_text())
    require(value.get('version') == 'station_registration_artifact_v1' and
            value.get('chain_id') == CHAIN_ID and value.get('network_id') == 'testnet',
            'artifact identity invalid')
    transactions = value.get('transactions')
    require(isinstance(transactions, list) and len(transactions) == expected_count,
            'artifact transaction count invalid')
    return transactions


def build(args, directory, token, rows, stamp, fmt='v1'):
    age(stamp)
    for row in rows:
        row['submitted_at'] = stamp
    if fmt == 'v2':
        # One row at a time: read THIS row's owner nonce, then sign THIS row,
        # before the next read. A batched read would leave early rows waiting
        # through every later HTTP call while an owner action can move a nonce.
        transactions = []
        for row in rows:
            age(stamp)
            add_nonces(args, directory, token, [row])
            transactions += cli_artifact(args, directory, [row], 1)
    else:
        for row in rows:
            row.pop('expected_nonce', None)
        transactions = cli_artifact(args, directory, rows, len(rows))
    artifact = directory / 'artifact.json'
    artifact.unlink(missing_ok=True)
    write_json(artifact, {'version': 'station_registration_artifact_v1', 'chain_id': CHAIN_ID,
                          'network_id': 'testnet', 'transactions': transactions})
    submit = directory / 'submit.json'
    submit.unlink(missing_ok=True)
    write_json(submit, {'chain_id': CHAIN_ID, 'network_id': 'testnet', 'transactions': transactions})
    require(submit.stat().st_size <= MAX_BYTES, 'signed artifact exceeds byte cap')
    print(f'BUILT: {len(rows)} transactions; {artifact.stat().st_size} bytes')
    return submit


def submit_batch(args, directory, token, submit, stamp, rows):
    require(age(stamp) <= SUBMIT_AGE, 'submit budget exceeded; no submission')
    status, response, _ = http(args, directory, token, 'POST',
                              '/transactions/station/registrations', submit, stamp)
    require(status == 201, 'submission refused; read back before any new run')
    value = data_object(response)
    require(type(value.get('accepted')) is int and value['accepted'] == len(rows),
            'submission accepted count mismatch; read back before any new run')
    print(f'SUBMITTED: {value["accepted"]} accepted; HTTP 201')
    return value


def row_states(args, directory, token, rows):
    """Per-row read-back state: 'pending', 'observed' or 'unverified'.

    FAIL CLOSED. core4 620902bf7 has no route that says a specific registration
    applied: the station record keeps no registration tx id or inclusion height,
    the owner ledger has no last-applied-registration identity, and
    `/transactions/{id}/status` says only that a tx is in a block, while an
    included v2 registration can still be an inert no-op. Nonce, ledger and
    registry state are all reachable by other transactions (an owner Reactivate
    consumes the nonce on a clean ledger; a competing same-owner registration
    consumes nonce 0), so none of them proves OUR row applied.

    - 'pending':    the station is not in the registry yet.
    - 'unverified': the station is in the registry (or its record is not
                    active); a v2 row can never be called applied from these reads.
    - 'observed':   a v1 row (no signed nonce) whose record is active and registered to
                    the owner. This is an OBSERVATION of station state only: a
                    competing same-owner v1 registration can create the same
                    record, and no route binds it to the submitted tx, so it is
                    never called applied.
    """
    states = []
    for index, row in enumerate(rows, 1):
        status, response, _ = http(args, directory, token, 'GET',
                                  '/transactions/station/registrations/' + row['station_id'])
        if status == 404:
            print(f'ROW {index}/{len(rows)}: pending inclusion')
            states.append('pending')
            continue
        require(status == 200, 'inclusion read refused')
        value = data_object(response)
        require(value.get('station_id') == row['station_id'] and
                value.get('owner_address', '').lower() == row['owner_address'].lower() and
                value.get('provenance_class') == 'real', 'inclusion binding mismatch')
        if 'expected_nonce' not in row and value.get('is_active') is True:
            print(f'ROW {index}/{len(rows)}: station active, registered to owner '
                  '(observed state; not proof this run applied)')
            states.append('observed')
        else:
            print(f'ROW {index}/{len(rows)}: UNVERIFIED (a station record exists; nothing proves '
                  'this registration is the one that applied; manager readback needed)')
            states.append('unverified')
    return states


def inclusion_state(args, directory, token, rows):
    """How many rows show an active, owner-registered station (see row_states)."""
    return row_states(args, directory, token, rows).count('observed')


def short_owner(address):
    return address[:8] + '...' if isinstance(address, str) else '?'


def handoff_list(batch_id, rows, states):
    """Identifiable, privacy-safe manager list: ids and owner prefixes, never coordinates."""
    print(f'HANDOFF: batch {batch_id}; {len(rows)} rows')
    for index, (row, state) in enumerate(zip(rows, states), 1):
        print(f'HANDOFF ROW {index}/{len(rows)}: {row["station_id"]} owner {short_owner(row["owner_address"])} {state}')


def poll(args, directory, token, rows, receipt=None):
    batch_id = directory.name
    for attempt in range(1, 7):
        states = row_states(args, directory, token, rows)
        print(f'INCLUSION: {states.count("observed")}/{len(rows)} active, '
              f'{states.count("unverified")} unverified, {states.count("pending")} pending; '
              f'attempt {attempt}')
        if 'pending' not in states:
            break
        if attempt < 6:
            command(['sleep', '60'], 'poll wait interrupted', timeout=65)
    else:
        if receipt:
            receipt('pending', states)
        raise Stop('inclusion pending; do not resubmit; ask manager for readback')
    if 'unverified' in states:
        if receipt:
            receipt('unverified', states)
        handoff_list(batch_id, rows, states)
        raise Unverified(f'{states.count("unverified")}/{len(rows)} rows UNVERIFIED: stations are on '
                         'the node but no route shows this registration applied; this is NOT a pass; '
                         'give the HANDOFF list and the receipt to the manager for readback, then '
                         'record it with --mark-reconciled; do not resubmit')
    # Station IDs were validated before they became SQL literals. No DB mutation.
    for attempt in range(1, 13):
        count = 0
        for index, row in enumerate(rows, 1):
            sql = ("SELECT count(*) FROM mobile_station_registrations WHERE station_id="
                   f"'{row['station_id']}' AND owner_address='{row['owner_address']}' AND status='on_chain'")
            raw = command(['docker', 'exec', args.postgres_container, 'psql', '-U', 'wrfcoin',
                           '-d', 'wrfcoin', '-At', '-c', sql], 'backend status read failed').strip()
            require(raw in ('0', '1'), 'backend row status invalid')
            count += int(raw)
            print(f'ROW {index}/{len(rows)}: ' + ('on_chain' if raw == '1' else 'pending sync'))
        print(f'SYNC: {count}/{len(rows)} on_chain; attempt {attempt}')
        if count == len(rows):
            if receipt:
                receipt('observed', states)
            print(f'ACTIVATION OBSERVED: {count}/{len(rows)} stations active in the node registry '
                  'and on_chain in the backend (observed station state; NOT proof that this '
                  "run's transaction applied)")
            return
        if attempt < 12:
            command(['sleep', '60'], 'poll wait interrupted', timeout=65)
    if receipt:
        receipt('sync-pending', states)
    raise Stop('backend sync pending; ask manager; never update DB or resubmit blindly')


def parse_producers(values):
    """`--producer NAME=CONTAINER` or `NAME=DOCKER_HOST::CONTAINER`, exactly three, distinct names.

    Endpoints are operator inputs, never defaults: the tool has no producer
    address of its own.
    """
    require(len(values) == PRODUCER_COUNT, 'exactly three --producer inputs are required')
    producers = {}
    for value in values:
        name, separator, target = value.partition('=')
        host, _, container = target.rpartition('::')
        require(separator and re.fullmatch(r'[A-Za-z0-9._-]{1,64}', name) and name not in producers and
                re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', container) and
                (not host or re.fullmatch(r'[A-Za-z0-9+.:/@_-]{1,256}', host)),
                '--producer must be NAME=CONTAINER or NAME=DOCKER_HOST::CONTAINER; names distinct')
        require((host, container) not in producers.values(),
                'duplicate producer target; three distinct producers are required')
        producers[name] = (host, container)
    return producers


def producer_fence(producers):
    """Refuse unless ALL producers report the exact release image revision.

    core4 620902bf7 exposes no tokenless build revision (`/network/info` has only
    the crate version; `/network/upgrade` carries the signed notice's commit, not
    the running binary's), so the revision is read from each producer's container
    image label. Any missing label, failed read or different revision stops the
    run before a signature or submission.
    """
    for name, (host, container) in producers.items():
        argv = ['docker'] + (['--host', host] if host else []) + [
            'inspect', '--format', '{{index .Config.Labels "' + REVISION_LABEL + '"}}', container]
        revision = command(argv, 'producer revision read failed; nothing signed').strip()
        require(revision == RELEASE_REVISION,
                f'producer {name} is not on release {RELEASE_REVISION[:9]}; nothing signed')
    print(f'FENCE: {len(producers)}/{PRODUCER_COUNT} producers on {RELEASE_REVISION[:9]}')


def receipt_writer(args, batch_id, stamp, fmt, rows):
    """Durable batch receipt outside the (deleted) private directory; ids only."""
    directory = Path(args.receipt_dir or (Path.cwd() / 'msr-receipts')).absolute()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(stat.S_IMODE(directory.stat().st_mode) == 0o700, 'receipt directory mode invalid')
    path = directory / (batch_id + '.receipt.json')
    marker = args.complete_marker
    current = {'stamp': stamp}

    def write(status, states=None, stamp=None):
        if stamp is not None:
            current['stamp'] = stamp  # a restamped rebuild signs and POSTs this one
        body = {'version': 'msr_batch_receipt_v1', 'batch_id': batch_id, 'status': status,
                'submitted_at': current['stamp'], 'registration_format': fmt,
                'complete_marker': marker,
                'rows': [{'station_id': r['station_id'], 'owner_prefix': short_owner(r['owner_address']),
                          'expected_nonce': r.get('expected_nonce'),
                          'state': (states[i] if states else 'unknown')}
                         for i, r in enumerate(rows)]}
        tmp = path.with_suffix('.tmp')
        tmp.unlink(missing_ok=True)
        with tmp.open('x', encoding='utf-8') as stream:
            json.dump(body, stream, separators=(',', ':'))
        os.replace(tmp, path)
        require(stat.S_IMODE(path.stat().st_mode) == 0o600, 'receipt mode invalid')
    return write, path


def mark_reconciled(args):
    """Record a MANAGER-CONFIRMED readback of an UNVERIFIED batch. No network, no key, no POST.

    Writes the staged `.complete` marker (so staged work may advance) only when the
    operator supplies the receipt's exact row count as confirmation; never resubmits.
    """
    os.umask(0o077)
    require(re.fullmatch(r'msr-activation-[A-Za-z0-9_]{1,32}', args.mark_reconciled),
            'batch id invalid')
    directory = Path(args.receipt_dir or (Path.cwd() / 'msr-receipts')).absolute()
    path = directory / (args.mark_reconciled + '.receipt.json')
    require(path.is_file() and not path.is_symlink(), 'no receipt for that batch id')
    body = json.loads(path.read_text())
    require(body.get('version') == 'msr_batch_receipt_v1' and body.get('batch_id') == args.mark_reconciled,
            'receipt invalid')
    require(body.get('status') in ('unverified', 'sync-pending', 'pending'),
            'batch is not awaiting manager readback (already observed or reconciled)')
    require(isinstance(body.get('rows'), list) and len(body['rows']) >= 1 and
            type(args.confirmed_rows) is int and args.confirmed_rows >= 1,
            'receipt has no rows or confirmation is not a positive count')
    require(args.confirmed_rows == len(body['rows']),
            'confirmation must equal the receipt row count after the manager has verified every row')
    marker = body.get('complete_marker')
    if marker:
        marker_path = Path(marker)
        require(marker_path.is_absolute() and marker_path.parent == directory and
                re.fullmatch(r'batch-[1-9][0-9]{0,3}\.complete', marker_path.name),
                'receipt marker path invalid')
        with marker_path.open('x', encoding='utf-8'):
            pass  # an existing marker means this batch was already advanced: refuse
    body['status'] = 'reconciled'
    tmp = path.with_suffix('.tmp')
    tmp.unlink(missing_ok=True)
    with tmp.open('x', encoding='utf-8') as stream:
        json.dump(body, stream, separators=(',', ':'))
    os.replace(tmp, path)
    print(f'RECONCILED: batch {args.mark_reconciled}; {len(body["rows"])} rows; '
          + ('staged marker written; nothing was submitted' if marker else 'no staged marker; nothing was submitted'))


def activate(args):
    os.umask(0o077)
    require(1 <= args.limit <= SAFE_ROWS, 'limit must be 1..21; split larger groups')
    producers = parse_producers(args.producer)
    url = urlsplit(args.node_url)
    require(url.scheme in ('http', 'https') and url.hostname and not url.username and
            not url.password and not url.query and not url.fragment and url.path in ('', '/'),
            'node URL invalid')
    loopback = loopback_host(url.hostname)
    require(url.scheme == 'https' or loopback, 'remote node URL requires HTTPS')
    digest = hashlib.sha256()
    with Path(args.cli).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    require(re.fullmatch(r'[0-9a-f]{64}', args.cli_sha) and digest.hexdigest() == args.cli_sha,
            'CLI digest mismatch')
    key = Path(args.governance_key)
    require(key.is_file() and stat.S_IMODE(key.stat().st_mode) == 0o600,
            'governance key must exist with mode 0600')
    require(re.fullmatch(r'[0-9a-f]{64}', args.governance_pubkey), 'governance public key invalid')
    require(command(['timedatectl', 'show', '--property=NTPSynchronized', '--value'],
                    'clock sync preflight failed').strip() == 'yes', 'clock is not synchronized')
    if args.submitted_at is not None:
        age(args.submitted_at)  # Refuse an already-expired stamp before export or signing.
    producer_fence(producers)  # before any token read, signature or submission
    require(container_env(args.backend_container).get('STATION_CHAIN_SYNC_ENABLED') == 'true',
            'backend chain sync is not enabled')
    token = container_env(args.node_container).get('WRFCOIN_OPERATOR_TOKEN', '')
    require(re.fullmatch(r'[A-Za-z0-9._~+/=-]{1,4096}', token), 'operator credential missing or invalid')
    private_root = os.environ.get('TMPDIR') or ('/dev/shm' if Path('/dev/shm').is_dir() else None)
    with tempfile.TemporaryDirectory(prefix='msr-activation-', dir=private_root) as temp:
        directory = Path(temp)
        require(stat.S_IMODE(directory.stat().st_mode) == 0o700, 'private directory mode invalid')
        status, _, _ = http(args, directory, token, 'GET', '/readyz')
        require(status == 200, 'node is not ready')
        status, response, headers = http(args, directory, token, 'GET', '/network/info')
        value = data_object(response)
        require(status == 200 and str(value.get('chain_id')) == CHAIN_ID and
                value.get('network_id') == 'testnet' and
                type(value.get('chain_height')) is int and value['chain_height'] > 0,
                'node identity or height invalid')
        dates = re.findall(r'^Date:\s*(.+)$', headers, re.I | re.M)
        require(len(dates) == 1, 'node clock evidence unavailable')
        remote_time = email.utils.parsedate_to_datetime(dates[0].strip()).timestamp()
        require(abs(remote_time - now()) <= 5, 'node and key-host clocks differ')
        fmt = registration_format(args, directory, token)
        print(f'FORMAT: {fmt} registrations')
        # v2 preflight: already-registered db_only rows need sync/readback, not another POST.
        raw = command(['docker', 'exec', args.postgres_container, 'psql', '-U', 'wrfcoin',
                       '-d', 'wrfcoin', '-At', '-c',
                       "SELECT station_id FROM mobile_station_registrations WHERE status='db_only' "
                       f'ORDER BY created_at, station_id LIMIT {args.limit}'],
                      'pending station preflight failed')
        preview = raw.splitlines()
        require(1 <= len(preview) <= args.limit and len(set(preview)) == len(preview) and
                all(re.fullmatch(r'mob-[0-9a-f]{32}', station) for station in preview),
                'no pending stations or pending station IDs invalid')
        for station in preview:
            status, _, _ = http(args, directory, token, 'GET',
                                '/transactions/station/registrations/' + station)
            require(status == 404, 'pending station already registered or read refused; ask manager')
        print('PREFLIGHT PASS: clock, node, sync, CLI and key modes')
        stamp = args.submitted_at if args.submitted_at is not None else now()
        batch_id = directory.name
        exported = '/tmp/' + batch_id + '.json'
        projected = '/tmp/' + batch_id + '-cli.json'
        container_outputs_pending = False
        try:
            age(stamp)
            container_outputs_pending = True
            command(['docker', 'exec', '-w', '/app/backend', args.backend_container,
                     'node_modules/.bin/tsx', 'scripts/export-mobile-station-registrations.ts',
                     '--out', exported, '--batch-id', batch_id, '--limit', str(args.limit),
                     '--cli-batch-out', projected, '--submitted-at', str(stamp)],
                    'export failed or no exportable rows; nothing submitted', timeout=45)
            age(stamp)
            full = json.loads(command(['docker', 'exec', args.backend_container, 'cat', exported],
                                      'export read failed'))
            rows = json.loads(command(['docker', 'exec', args.backend_container, 'cat', projected],
                                      'batch read failed'))
            command(['docker', 'exec', args.backend_container, 'rm', '-f', exported, projected],
                    'private container cleanup failed; owner must clean this batch', timeout=10)
            container_outputs_pending = False
            require(full.get('version') == 'mobile_station_registration_export_v1' and
                    full.get('chainId') == CHAIN_ID and full.get('networkId') == 'testnet',
                    'export identity invalid')
            require(isinstance(rows, list) and 1 <= len(rows) <= args.limit and
                    [x['station_id'] for x in full['stations']] == [x['station_id'] for x in rows],
                    'export row count or order invalid')
            require(len({x['station_id'] for x in rows}) == len(rows), 'duplicate station rows')
            require(all(x['station_id'] in preview for x in rows), 'export selection changed; nothing submitted')
            for row in rows:
                require(set(row) == ROW_KEYS and row['submitted_at'] == stamp and
                        row['hardware_model'] == 'phone-barometer' and
                        row['data_quality_tier'] == 'unverified' and row['provenance_class'] == 'real' and
                        re.fullmatch(r'mob-[0-9a-f]{32}', row['station_id']) and
                        re.fullmatch(r'0x[0-9a-fA-F]{40}', row['owner_address']), 'batch row invalid')
            print(f'EXPORTED: {len(rows)} rows')
            require(not args.require_count or len(rows) == args.limit,
                    'requested batch count unavailable; nothing signed or submitted')
            if args.dry_run:
                for index in range(1, len(rows)+1):
                    print(f'ROW {index}/{len(rows)}: eligible; ownership checked by exporter')
                print(f'DRY RUN PASS: {len(rows)} eligible rows; no signature or submission')
                return
            receipt, receipt_path = receipt_writer(args, directory.name, stamp, fmt, rows)
            receipt('built')
            print(f'RECEIPT: {receipt_path}')
            submit = build(args, directory, token, rows, stamp, fmt)
            elapsed = age(stamp)
            if elapsed > BUILD_AGE:
                require(args.restamp_once, 'build budget exceeded; rerun before submitting')
                stamp = now()
                receipt('restamped', stamp=stamp)
                submit = build(args, directory, token, rows, stamp, fmt)
                print(f'RESTAMPED: {len(rows)} rows; one rebuild; no prior POST')
            receipt('submit-attempted', stamp=stamp)  # before the POST: an ambiguous POST leaves a record
            submit_batch(args, directory, token, submit, stamp, rows)
            receipt('submitted', stamp=stamp)
            # Coordinate-bearing local files removed before potentially long inclusion/sync polls.
            for path in ('cli.json', 'artifact.json', 'submit.json', 'http.json', 'http.headers'):
                (directory / path).unlink(missing_ok=True)
            poll(args, directory, token, rows, receipt)
        finally:
            if container_outputs_pending:
                command(['docker', 'exec', args.backend_container, 'rm', '-f', exported, projected],
                        'private container cleanup failed; owner must clean this batch', timeout=10)


def stage(args):
    """Write owner steps only; no external commands, key reads or network calls."""
    require(args.count is not None and 1 <= args.count <= 10000, 'count must be 1..10000')
    require(1 <= args.limit <= SAFE_ROWS, 'limit must be 1..21; split larger groups')
    require(not args.dry_run and args.submitted_at is None,
            'staging requires fresh runtime stamps and separate dry-run steps')
    parse_producers(args.producer)
    os.umask(0o077)
    directory = Path(args.stage_dir).absolute()
    directory.mkdir(mode=0o700)  # Never replace a previous staged owner run.
    launcher = Path(__file__).absolute()
    common = ['python3', str(launcher), '--require-count', '--cli', str(Path(args.cli).absolute()),
              '--governance-key', str(Path(args.governance_key).absolute()), '--governance-pubkey', args.governance_pubkey,
              '--node-url', args.node_url, '--backend-container', args.backend_container,
              '--node-container', args.node_container, '--postgres-container', args.postgres_container]
    for producer in args.producer:
        common += ['--producer', producer]
    if args.restamp_once:
        common.append('--restamp-once')
    if args.registration_format != 'auto':
        common += ['--registration-format', args.registration_format]
    if args.cli_sha_explicit:
        common += ['--cli-sha', args.cli_sha]
    batches = (args.count + args.limit - 1) // args.limit
    instructions = ['# Owner-staged phone activation', '',
                    'Run each line on the governance key host, in order. Inspect scripts first.',
                    'Dry-run checks the next pending batch; activation repeats preflight with a fresh stamp.',
                    'An activation attempt cannot be repeated from this directory, even after failure.',
                    'Ask the manager for readback after a possible POST before staging another run.', '']
    for batch in range(1, batches+1):
        limit = min(args.limit, args.count - (batch-1)*args.limit)
        command_line = shlex.join(common + ['--limit', str(limit)])
        marker = directory / f'batch-{batch}.complete'
        run_line = shlex.join(common + ['--limit', str(limit), '--receipt-dir', str(directory),
                                        '--complete-marker', str(marker)])
        prefix = '#!/usr/bin/env bash\nset +x\nset -euo pipefail\numask 077\n'
        prefix += 'cd -- ' + shlex.quote(str(directory)) + '\n'
        if batch > 1:
            prefix += f'test -f batch-{batch-1}.complete || {{ echo "STOP: previous batch incomplete"; exit 1; }}\n'
        dry = prefix + f'test ! -d batch-{batch}.attempted\n'
        dry += command_line + f' --dry-run\n: > batch-{batch}.ready\n'
        run = prefix + f'test -f batch-{batch}.ready || {{ echo "STOP: run dry-run first"; exit 1; }}\n'
        run += f'mkdir -m 700 batch-{batch}.attempted || {{ echo "STOP: attempt recorded; ask manager for readback"; exit 1; }}\n'
        run += run_line + f'\n: > batch-{batch}.complete\n'
        for step, content in [('dry-run', dry), ('activate', run)]:
            number = 2*batch - (1 if step == 'dry-run' else 0)
            path = directory / f'{number:03d}-{step}.sh'
            with path.open('x', encoding='utf-8') as stream:
                stream.write(content)
            path.chmod(0o700)
            instructions.append('bash ' + shlex.quote(str(path)))
    (directory / 'README.md').write_text('\n'.join(instructions) + '\n')
    print(f'STAGED: {args.count} requested rows; {batches} batches; {2*batches} owner steps')


def main():
    parser = PrivateParser(description=__doc__)
    parser.add_argument('--limit', type=int, default=SAFE_ROWS)
    parser.add_argument('--cli')
    parser.add_argument('--cli-sha', default=None)
    parser.add_argument('--registration-format', choices=('auto', 'v1', 'v2'), default='auto')
    parser.add_argument('--governance-key', default='/root/oracle-ceremony/oracle-governance.key')
    parser.add_argument('--governance-pubkey', default=GOV)
    parser.add_argument('--node-url', default='http://127.0.0.1:8556')
    parser.add_argument('--backend-container', default='wrfcoin-testnet-backend')
    parser.add_argument('--node-container', default='wrfcoin-testnet-node')
    parser.add_argument('--postgres-container', default='wrfcoin-testnet-postgres')
    parser.add_argument('--producer', action='append', default=[],
                        help='NAME=CONTAINER or NAME=DOCKER_HOST::CONTAINER; give exactly three')
    parser.add_argument('--receipt-dir')
    parser.add_argument('--complete-marker')
    parser.add_argument('--mark-reconciled', metavar='BATCH_ID')
    parser.add_argument('--confirmed-rows', type=int)
    parser.add_argument('--submitted-at', type=int)
    parser.add_argument('--restamp-once', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--stage-dir')
    parser.add_argument('--count', type=int)
    parser.add_argument('--require-count', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[1-9][0-9]*', CHAIN_ID) or CHAIN_ID == '1':
        parser.error('invalid testnet chain id')
    args.cli_sha_explicit = args.cli_sha is not None
    if args.cli_sha is None:
        args.cli_sha = CLI_SHA
    def interrupted(_signal, _frame):
        raise Stop('interrupted; read back before any new run')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        if args.mark_reconciled:
            mark_reconciled(args)
            return 0
        require(args.cli, 'invalid arguments: --cli is required')
        if args.stage_dir:
            stage(args)
        else:
            require(args.count is None, '--count requires --stage-dir')
            activate(args)
    except Unverified as error:
        print('ACTIVATION UNVERIFIED: ' + str(error))
        return 3
    except Stop as error:
        print('ACTIVATION STOP: ' + str(error))
        return 1
    except (OSError, ValueError, TypeError, KeyError, AttributeError, OverflowError):
        print('ACTIVATION STOP: invalid private data or local operation failed; details withheld')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
