"""`activate-mobile-stations` with --source website, driven through the installed shell
entrypoint with fake tools. No socket, no real key, no real node. Made-up stations only."""
import hashlib
import json
import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import unittest

REPO = Path(sys.argv.pop(1)).resolve()
IDS = ['pws-00000000000000a1', 'pws-00000000000000b2']
NAMED = 'pws-fixture-garden-a1b2c3'
FAKE = r'''#!/usr/bin/env python3
import sys,os,json,pathlib,email.utils,stat
p=pathlib.Path(os.environ['FAKE_STATE']);s=json.loads(p.read_text());a=sys.argv[1:];name=pathlib.Path(sys.argv[0]).name
s['events'].append([name,a]);scenario=s['scenario'];now=1790000000+s['elapsed'];CHAIN=os.environ['WRFCOIN_CHAIN_ID']
IDS=['pws-00000000000000a1','pws-00000000000000b2'];NAMED='pws-fixture-garden-a1b2c3'
def save():p.write_text(json.dumps(s))
def row(i):
 r=dict(station_id=IDS[i],owner_address='0x'+format(i+1,'040x'),owner_pubkey='c'*64,owner_signature='d'*128,latitude=10.3,longitude=-20.7,hardware_model='personal-weather-station',provenance_class='real',data_quality_tier='unverified',submitted_at=s.get('stamp',now))
 if scenario=='off-grid' and i==0:r['latitude']=10+1/3
 if scenario=='phone-hardware' and i==0:r['hardware_model']='phone-barometer'
 if scenario=='gold-tier' and i==0:r['data_quality_tier']='gold'
 if scenario=='phone-id' and i==0:r['station_id']='mob-'+'0'*32
 if scenario=='extra-key' and i==0:r['elevation_meters']=5
 if scenario=='named-id' and i==0:r['station_id']=NAMED
 return r
def artifact(rows):
 version='mobile_station_registration_export_v1' if scenario=='phone-version' else 'website_station_registration_export_v1'
 # Station 1 has readings in the backend database; station 2 only on chain (`chain-evidence`), or
 # in the database too. The stamped export is told which ids were confirmed and never asks the node.
 def ev(i,x):
  if s['last']=='stamped' and x['station_id'] in s['confirmed']:return dict(source='confirmed',observations_24h=0,last_observation_age_minutes=None)
  if scenario=='no-source' and i==0:return dict(observations_24h=3,last_observation_age_minutes=12)
  return dict(source='chain' if scenario=='chain-evidence' and i==1 else 'db',observations_24h=3+i,last_observation_age_minutes=12+i)
 stations=[dict(x,evidence=ev(i,x)) for i,x in enumerate(rows)]
 skipped=[dict(stationId='pws-00000000000000c3',reason='no reading in the last 24 hours in the database or the chain tail (source none)'),dict(stationId='pws-00000000000000e5',reason='could not check the chain for readings (node read failed); not exported this run'),dict(stationId=NAMED,reason='station id is not a neutral id (it may hold a name); pass --allow-id to include it')]
 if scenario=='named-id':skipped=skipped[:1]
 if scenario=='bad-reason':skipped=[dict(stationId='pws-00000000000000c3',reason='at 12.3456 -45.6789 owner 0x'+'ab'*20)]
 return dict(version=version,chainId='999' if scenario=='other-chain' else CHAIN,networkId='testnet',stations=stations,not_exported=skipped)
if name=='date':print(now)
elif name=='timedatectl':print('yes')
elif name=='sleep':s['elapsed']+=int(a[0])
elif name=='docker':
 if a[0]=='inspect' and 'org.opencontainers.image.revision' in ' '.join(a):print('true|'+'a'*40)
 elif a[0]=='inspect':
  if 'backend' in a[-1]:print(json.dumps(['STATION_CHAIN_SYNC_ENABLED=true']+([] if scenario=='switch-off' else ['WEBSITE_STATION_CHAIN_REGISTRATION_ENABLED=true'])))
  else:print(json.dumps(['WRFCOIN_OPERATOR_TOKEN=TOKEN_SENTINEL_PRIVATE']))
 elif 'scripts/export-website-station-registrations.ts' in a:
  assert '--mark-submitted' not in a
  s['allow']=[a[i+1] for i,x in enumerate(a) if x=='--allow-id']
  s['confirmed']=[a[i+1] for i,x in enumerate(a) if x=='--confirmed-reporting']
  s['confirmed_by_call'].append(s['confirmed'])
  if '--submitted-at' in a:
   # The stamped export for signing. `changed` models a station joining between the look and the signing.
   s['stamp']=int(a[a.index('--submitted-at')+1]);s['rows']=[row(i) for i in range(2)]
   if scenario=='changed':s['rows'][1]['station_id']='pws-00000000000000d4'
   if scenario=='shrunk':s['rows']=s['rows'][:1]
   s['exports']+=1
  else:
   assert '--cli-batch-out' not in a;s['looks']+=1;s['look']=[row(i) for i in range(2)]
  s['last']='stamped' if '--submitted-at' in a else 'look'
  print('TOKEN_SENTINEL_PRIVATE export raw output')
 elif 'scripts/export-mobile-station-registrations.ts' in a:raise RuntimeError('website run used the phone export')
 elif 'cat' in a:
  print(json.dumps(s['rows'] if '-cli.json' in a[-1] else artifact(s['rows'] if s['last']=='stamped' else s['look'])))
 elif 'rm' in a:s['cleanups']+=1
 elif 'psql' in a:
  assert 'website_station_chain_registrations' in a[-1] and 'mobile_station_registrations' not in a[-1]
  assert not any(w in a[-1].upper() for w in ('UPDATE','INSERT','DELETE'))
  # The website source never reads the waiting list from the database: the export decides it.
  if 'SELECT station_id' in a[-1]:raise RuntimeError('website run read the waiting list from the database')
  else:
   assert 'owner_address=' in a[-1];print(0)
elif name=='wrfcoin':
 batch=pathlib.Path(a[a.index('--batch')+1]);assert stat.S_IMODE(batch.stat().st_mode)==0o600
 rows=json.loads(batch.read_text());s['builds']+=1;s['built'].append([x['station_id'] for x in rows])
 assert all(x['expected_nonce']==0 for x in rows)
 out=pathlib.Path(a[a.index('--out')+1]);out.write_text(json.dumps(dict(version='station_registration_artifact_v1',chain_id=CHAIN,network_id='testnet',transactions=[dict(station_id=x['station_id'],submitted_at=x['submitted_at']) for x in rows])))
 print(json.dumps(dict(self_verified=True,artifact=str(out),registrations=[])))
elif name=='curl':
 cfg='' if '--config' not in a else sys.stdin.read()
 assert 'TOKEN_SENTINEL_PRIVATE' not in ' '.join(a)
 output=pathlib.Path(a[a.index('--output')+1]);headers=pathlib.Path(a[a.index('--dump-header')+1]);url=a[-1]
 status=200;body={}
 if url.endswith('/readyz'):body={'ready':True}
 elif url.endswith('/transactions/oracle/pending?limit=1'):body=dict(active_features=['station_active_reward_gate','station_owner_actions','station_owner_consent','station_registration_nonce'])
 elif url.endswith('/owner-ledger'):status=404;body=dict(ok=False,error=dict(code='NOT_FOUND',message='station is not registered'))
 elif url.endswith('/network/info'):body=dict(chain_id=CHAIN,network_id='testnet',chain_height=123)
 elif '--data-binary' in a:
  data=json.loads(pathlib.Path(a[a.index('--data-binary')+1][1:]).read_text());assert set(data)=={'chain_id','network_id','transactions'}
  s['posts']+=1;status=201;body=dict(accepted=len(s['rows']),transaction_ids=['ab'*32 for _ in s['rows']])
 else:
  sid=url.rsplit('/',1)[1]
  if s['posts']==0:status=200 if scenario=='already-registered' else 404
  if status==200:
   found=next((x for x in s.get('rows',[])+[row(0),row(1)] if x['station_id']==sid))
   body=dict(station_id=sid,owner_address=found['owner_address'],provenance_class='real',is_active=True)
 output.write_text(json.dumps(body));headers.write_text('HTTP/1.1 '+str(status)+'\r\nDate: '+email.utils.formatdate(now,usegmt=True)+'\r\n\r\n');print(status)
else:raise RuntimeError('unexpected fake')
save()
'''


class WebsiteOwnerFlow(unittest.TestCase):
    @staticmethod
    def answered(argv, answer, **options):
        """Run with a terminal on stdin that already holds the owner's answer (None = no terminal)."""
        if answer is None:
            return subprocess.run(argv, stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=60, **options)
        master, slave = pty.openpty()
        try:
            os.write(master, answer.encode() + b'\n')
            return subprocess.run(argv, stdin=slave, text=True, capture_output=True, timeout=60, **options)
        finally:
            os.close(slave)
            os.close(master)

    def run_flow(self, scenario='ok', extra=(), answer='YES', source=('--source', 'website')):
        with tempfile.TemporaryDirectory(prefix='website-activation-test-') as temp:
            root = Path(temp)
            tools = root / 'bin'
            tools.mkdir()
            fake = tools / 'fake.py'
            fake.write_text(FAKE)
            fake.chmod(0o755)
            for name in ['date', 'timedatectl', 'docker', 'curl', 'sleep', 'wrfcoin']:
                (tools / name).symlink_to(fake)
            key = root / 'fixture-key'
            key.write_text('TEST_ONLY_NOT_A_KEY')
            key.chmod(0o600)
            state = root / 'state.json'
            state.write_text(json.dumps(dict(scenario=scenario, elapsed=0, events=[], posts=0, builds=0,
                                             built=[], cleanups=0, looks=0, exports=0, allow=[], last='', confirmed=[],
                                             confirmed_by_call=[])))
            env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'], FAKE_STATE=str(state),
                       TMPDIR=str(root), WRFCOIN_CHAIN_ID='888')
            argv = ['bash', str(REPO / 'testnet/scripts/activate-mobile-stations.sh'), '--cli', str(tools / 'wrfcoin'),
                    '--cli-sha', hashlib.sha256(fake.read_bytes()).hexdigest(), '--governance-key', str(key),
                    '--producer', 'a=prod-a', '--producer', 'b=prod-b', '--producer', 'c=prod-c', '--limit', '2',
                    *source, *extra]
            result = self.answered(argv, answer, cwd=root, env=env)
            data = json.loads(state.read_text())
            text = result.stdout + result.stderr
            self.assertNotIn('TOKEN_SENTINEL_PRIVATE', text)
            self.assertNotIn('TEST_ONLY_NOT_A_KEY', text)
            # Nothing that looks like a position, a full owner address, a key or a signature is printed.
            # ("0.1 degree grid" in a stop message is the only decimal the tool may print.)
            self.assertNotRegex(text.replace('the 0.1 degree grid', 'the grid'), r'-?\d+\.\d')
            self.assertNotRegex(text, r'0x[0-9a-f]{40}')
            self.assertNotIn('45.6789', text)
            self.assertNotRegex(text, r'[cd]{64}')
            self.assertFalse(list(root.glob('msr-activation-*')), 'private files must be cleaned')
            # The fake CLI is the only thing handed the key path; the tool itself never opens it.
            self.assertEqual(key.read_text(), 'TEST_ONLY_NOT_A_KEY')
            data['receipts'] = [json.loads(p.read_text()) for p in root.glob('msr-receipts/*.receipt.json')]
            data['receipt_dir'] = None
            if data['receipts'] and scenario == 'ok-reconcile':
                again = subprocess.run(['bash', str(REPO / 'testnet/scripts/activate-mobile-stations.sh'),
                                        '--mark-reconciled', data['receipts'][0]['batch_id'], '--confirmed-rows', '2'],
                                       text=True, capture_output=True, timeout=30, cwd=root, env=env)
                data['reconcile'] = again.stdout + again.stderr
            return result, data

    def assert_nothing_signed(self, result, state, text):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(text, result.stdout)
        self.assertEqual((state['builds'], state['posts']), (0, 0))

    def test_dry_run_lists_ids_evidence_and_what_was_left_out_and_signs_nothing(self):
        result, state = self.run_flow(extra=['--dry-run'], answer=None)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('EXPORTED: 2 rows', result.stdout)
        self.assertIn(f'ROW 1/2: eligible; ownership checked by exporter; station id {IDS[0]}; '
                      'source db; 3 reading(s) in 24 h, last 12 min ago', result.stdout)
        self.assertIn(f'ROW 2/2: eligible; ownership checked by exporter; station id {IDS[1]}; '
                      'source db; 4 reading(s) in 24 h, last 13 min ago', result.stdout)
        self.assertIn('NOT IN THIS BATCH: pws-00000000000000c3: no reading in the last 24 hours in the database '
                      'or the chain tail (source none)', result.stdout)
        self.assertIn('NOT IN THIS BATCH: pws-00000000000000e5: could not check the chain for readings '
                      '(node read failed); not exported this run', result.stdout)
        # Both were seen in the database, so the stamped export is told of no chain-only station.
        self.assertEqual(state['confirmed_by_call'], [[], []])
        self.assertIn(f'NOT IN THIS BATCH: {NAMED}: station id is not a neutral id (it may hold a name); '
                      'pass --allow-id to include it', result.stdout)
        self.assertIn('DRY RUN PASS: 2 eligible rows; no signature or submission', result.stdout)
        self.assertEqual((state['builds'], state['posts']), (0, 0))
        self.assertFalse(any(name == 'wrfcoin' for name, _ in state['events']))

    def test_a_station_seen_only_on_chain_says_so_and_the_stamped_export_does_not_ask_the_node_again(self):
        result, state = self.run_flow(scenario='chain-evidence', extra=['--dry-run'], answer=None)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'station id {IDS[0]}; source db; 3 reading(s) in 24 h, last 12 min ago', result.stdout)
        self.assertIn(f'station id {IDS[1]}; source chain; 4 reading(s) in the chain tail, last 13 min ago', result.stdout)
        # The look found station 2 on chain; only that id is passed on as confirmed, and only to the stamped export.
        self.assertEqual(state['confirmed_by_call'], [[], [IDS[1]]])
        result, state = self.run_flow(scenario='chain-evidence')
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertEqual((state['looks'], state['exports'], state['posts']), (1, 1, 1))
        self.assertEqual(state['confirmed_by_call'], [[], [IDS[1]]])

    def test_a_look_that_does_not_say_where_a_station_was_seen_reporting_signs_nothing(self):
        result, state = self.run_flow(scenario='no-source')
        self.assert_nothing_signed(result, state, 'the export did not say where each station was seen reporting')
        self.assertEqual(state['exports'], 0)

    def test_real_run_shows_exactly_the_ids_it_signs_asks_for_yes_and_posts_once(self):
        result, state = self.run_flow(scenario='ok-reconcile')
        # Chain 888 is v2: a good run ends UNVERIFIED with exit 3, for the manager's readback.
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        before_yes = result.stdout.split('Type YES to continue')[0]
        for index, station in enumerate(IDS, 1):
            self.assertIn(f'WILL BE PUBLIC ON CHAIN {index}/2: station id {station}', before_yes)
        self.assertIn('ABOUT TO SIGN AND SUBMIT: up to 2 stations to chain 888', before_yes)
        # One read-only look for the list, then one stamped export for signing.
        self.assertEqual((state['looks'], state['exports'], state['posts']), (1, 1, 1))
        self.assertEqual(state['built'], [[IDS[0]], [IDS[1]]])
        self.assertIn('SUBMITTED: 2 accepted; HTTP 201', result.stdout)
        self.assertIn('ACTIVATION UNVERIFIED', result.stdout)
        self.assertIn('SYNC NOW: 0/2 on_chain', result.stdout)
        # The receipt records which source the batch came from, and reconcile says so.
        self.assertEqual([r['source'] for r in state['receipts']], ['website'])
        self.assertIn('RECONCILED: website batch', state['reconcile'])

    def test_a_station_set_that_changed_after_it_was_shown_is_never_signed(self):
        for scenario in ('changed', 'shrunk'):
            with self.subTest(scenario=scenario):
                result, state = self.run_flow(scenario=scenario)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual((state['builds'], state['posts']), (0, 0))
                self.assertRegex(result.stdout, 'export selection changed; nothing submitted|'
                                                'the stations to sign are not the ones shown; nothing signed')

    def test_an_id_that_may_hold_a_name_needs_the_owners_explicit_allow(self):
        # The backend export would not hand over such an id unasked; if one arrives anyway it is refused.
        result, state = self.run_flow(scenario='named-id')
        self.assert_nothing_signed(result, state, 'a station id is not a neutral id and was not allowed by name')
        result, state = self.run_flow(scenario='named-id', extra=['--allow-station-id', NAMED, '--dry-run'], answer=None)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(state['allow'], [NAMED])
        self.assertIn(f'station id {NAMED}; source db; 3 reading(s) in 24 h, last 12 min ago; allowed by name', result.stdout)

    def test_allow_station_id_is_for_the_website_source_and_must_be_a_plain_id(self):
        for extra, source in ((['--allow-station-id', NAMED], ()), (['--allow-station-id', 'bad id'], ('--source', 'website')),
                              (['--allow-station-id', 'mob-' + '0' * 32], ('--source', 'website'))):
            result, state = self.run_flow(extra=extra, source=source)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('invalid arguments', result.stdout)
            self.assertEqual(state['events'], [])

    def test_a_reason_that_is_not_a_fixed_phrase_is_withheld(self):
        result, state = self.run_flow(scenario='bad-reason', extra=['--dry-run'], answer=None)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('NOT IN THIS BATCH: one station (details withheld)', result.stdout)

    def test_an_export_for_another_chain_is_refused_before_anything_is_shown(self):
        result, state = self.run_flow(scenario='other-chain')
        self.assert_nothing_signed(result, state, 'export identity invalid')
        self.assertNotIn('WILL BE PUBLIC ON CHAIN', result.stdout)

    def test_anything_but_yes_signs_nothing(self):
        for answer in ('yes', 'y', '', 'YES please'):
            result, state = self.run_flow(answer=answer)
            self.assert_nothing_signed(result, state, 'owner did not type YES; nothing signed')

    def test_no_terminal_signs_nothing(self):
        result, state = self.run_flow(answer=None)
        self.assert_nothing_signed(result, state, 'a real activation needs a terminal for the YES; nothing signed')

    def test_backend_switch_off_stops_before_any_token_read(self):
        result, state = self.run_flow(scenario='switch-off')
        self.assert_nothing_signed(result, state, 'backend website station registration is not enabled')
        self.assertFalse(any(name == 'curl' for name, _ in state['events']))

    def test_a_station_already_on_chain_stops_and_names_it(self):
        result, state = self.run_flow(scenario='already-registered')
        self.assert_nothing_signed(result, state, f'station {IDS[0]} is already registered on chain or the read was refused')
        self.assertIn('leaves the waiting list on the next backend sync; nothing signed', result.stdout)

    def test_a_phone_station_never_goes_through_the_website_source(self):
        result, state = self.run_flow(scenario='phone-id')
        self.assert_nothing_signed(result, state, 'no pending stations or pending station IDs invalid')

    def test_a_row_the_website_export_must_not_produce_is_refused(self):
        for scenario in ('phone-hardware', 'gold-tier', 'extra-key'):
            with self.subTest(scenario=scenario):
                result, state = self.run_flow(scenario=scenario)
                self.assert_nothing_signed(result, state, 'batch row invalid')

    def test_backend_switch_off_never_runs_the_export(self):
        result, state = self.run_flow(scenario='switch-off')
        self.assertEqual((state['looks'], state['exports']), (0, 0))

    def test_a_position_finer_than_the_grid_is_refused(self):
        result, state = self.run_flow(scenario='off-grid')
        self.assert_nothing_signed(result, state, 'batch row is not on the 0.1 degree grid; nothing signed')

    def test_a_phone_export_artifact_is_refused(self):
        result, state = self.run_flow(scenario='phone-version')
        self.assert_nothing_signed(result, state, 'export identity invalid')

    def test_an_unknown_source_is_a_usage_error(self):
        result, state = self.run_flow(source=('--source', 'elsewhere'))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(state['events'], [])

    def test_staged_steps_carry_the_source(self):
        with tempfile.TemporaryDirectory(prefix='website-stage-test-') as temp:
            steps = Path(temp) / 'steps'
            argv = ['bash', str(REPO / 'testnet/scripts/activate-mobile-stations.sh'), '--cli', '/opt/cli',
                    '--cli-sha', 'd' * 64, '--producer', 'a=prod-a', '--producer', 'b=prod-b',
                    '--producer', 'c=prod-c', '--source', 'website', '--allow-station-id', NAMED,
                    '--stage-dir', str(steps), '--count', '3']
            result = subprocess.run(argv, text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for name in ('001-dry-run.sh', '002-activate.sh'):
                self.assertIn('--source website', (steps / name).read_text())
                self.assertIn(f'--allow-station-id {NAMED}', (steps / name).read_text())
            self.assertIn('website station activation', (steps / 'README.md').read_text())


class WorkstationWrapperSource(unittest.TestCase):
    WRAPPER = REPO / 'testnet/scripts/activate-mobile-stations-888.sh'

    def run_wrapper(self, *extra):
        with tempfile.TemporaryDirectory(prefix='website-wrap-') as temp:
            root = Path(temp)
            log = root / 'calls'
            (root / 'host').write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> ' + str(log) + '\n')
            (root / 'host').chmod(0o755)
            reader = root / 'reader'
            reader.write_text('#!/usr/bin/env bash\necho ' + 'c' * 40 + '\n')
            reader.chmod(0o755)
            argv = ['bash', str(self.WRAPPER), '--key-host', str(root / 'host'), '--tool-dir', '/opt/tool',
                    '--key-host-producer', 'n=node', '--reader', f'a={reader}', '--reader', f'b={reader}',
                    '--cli', '/opt/cli', '--cli-sha', 'd' * 64, *extra]
            result = subprocess.run(argv, text=True, capture_output=True, timeout=30)
            return result, log.read_text().splitlines() if log.exists() else []

    def test_website_source_reaches_both_the_dry_run_and_the_real_run(self):
        result, calls = self.run_wrapper('--source', 'website')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn('--dry-run', calls[0])
        for call in calls:
            self.assertIn('--source website', call)

    def test_a_phone_run_passes_no_source_so_an_older_tool_still_works(self):
        result, calls = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(calls and all('--source' not in call for call in calls))

    def test_allowed_station_ids_are_passed_on_for_the_website_source_only(self):
        result, calls = self.run_wrapper('--source', 'website', '--allow-station-id', NAMED, '--allow-station-id', 'pws-x')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for call in calls:
            self.assertIn(f'--allow-station-id {NAMED} --allow-station-id pws-x', call)
        for extra in (('--allow-station-id', NAMED), ('--source', 'website', '--allow-station-id', 'a;b')):
            result, calls = self.run_wrapper(*extra)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(calls, [])

    def test_an_unknown_source_reaches_nothing(self):
        result, calls = self.run_wrapper('--source', 'website;x')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
