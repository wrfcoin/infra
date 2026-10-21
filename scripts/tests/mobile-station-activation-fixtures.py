"""Drive the installed shell entrypoint using fake tools; never open a socket."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(sys.argv.pop(1)).resolve()
FAKE = r'''#!/usr/bin/env python3
import sys,os,json,pathlib,email.utils,stat,signal
p=pathlib.Path(os.environ['FAKE_STATE']);s=json.loads(p.read_text());a=sys.argv[1:];name=pathlib.Path(sys.argv[0]).name
s['events'].append([name,a]);scenario=s['scenario'];now=1790000000+s['elapsed']
def save():p.write_text(json.dumps(s))
def row(i=0):return dict(station_id='mob-'+format(i+1,'032x'),owner_address='0x'+format(i+1,'040x'),owner_pubkey='c'*64,owner_signature='d'*128,latitude=44.9,longitude=-93.2,hardware_model='phone-barometer',provenance_class='real',data_quality_tier='unverified',submitted_at=s.get('stamp',now))
if name=='date':print(now)
elif name=='timedatectl':print('no' if scenario=='clock' else 'yes')
elif name=='sleep':s['elapsed']+=int(a[0])
elif name=='docker':
 if a[0]=='inspect' and 'org.opencontainers.image.revision' in ' '.join(a):
  # Producer fence: every producer reports the release revision unless a scenario ages one.
  if scenario=='producer-read-error' and a[-1]=='prod-c':save();sys.exit(1)
  print('0'*40 if scenario=='producer-old' and a[-1]=='prod-b' else '620902bf7b01cf09b11b2bb0ff5a22571e7cb694')
 elif a[0]=='inspect':
  if 'backend' in a[-1]:print(json.dumps(['STATION_CHAIN_SYNC_ENABLED='+('false' if scenario=='sync-off' else 'true')]))
  else:print(json.dumps(['WRFCOIN_OPERATOR_TOKEN=TOKEN_SENTINEL_PRIVATE']))
 elif 'scripts/export-mobile-station-registrations.ts' in a:
  assert '--mark-submitted' not in a
  s['stamp']=int(a[a.index('--submitted-at')+1]);limit=int(a[a.index('--limit')+1]);s['rows']=[row(i) for i in range(22 if scenario=='oversize' else (limit if scenario in ('many','ambiguous-many') else 1))]
  s['elapsed']+=151 if scenario=='stale-export' else 0
  print('TOKEN_SENTINEL_PRIVATE KEY_SENTINEL_PRIVATE ENV_SENTINEL_PRIVATE 44.9876543,-93.2654321 export raw output')
  if scenario=='export-fail':save();sys.exit(1)
 elif 'cat' in a:
  if scenario=='cat-fail':print('KEY_SENTINEL_PRIVATE');save();sys.exit(1)
  print(json.dumps(s['rows'] if '-cli.json' in a[-1] else dict(version='mobile_station_registration_export_v1',chainId='777',networkId='testnet',stations=s['rows'])))
 elif 'rm' in a:
  s['cleanups']+=1
  if scenario=='cleanup-fail':print('ENV_SENTINEL_PRIVATE');save();sys.exit(1)
 elif 'psql' in a:
  if 'SELECT station_id' in a[-1]:
   limit=int(a[-1].split('LIMIT ')[1]);s['preview']=[row(i) for i in range(limit if scenario in ('many','ambiguous-many') else 1)]
   print('\n'.join(x['station_id'] for x in s['preview']))
  else:
   assert 'owner_address=' in a[-1]
   print(0 if scenario=='db-timeout' else 1)
elif name=='wrfcoin':
 batch=pathlib.Path(a[a.index('--batch')+1]);assert stat.S_IMODE(batch.stat().st_mode)==0o600 and stat.S_IMODE(batch.parent.stat().st_mode)==0o700
 rows=json.loads(batch.read_text());s['builds']+=1;assert s['cleanups']>=1
 assert all(x['submitted_at']==rows[0]['submitted_at'] for x in rows)
 s['build_stamps'].append(rows[0]['submitted_at'])
 s['elapsed']+=110 if scenario=='slow-build' and s['builds']==1 else (151 if scenario=='stale-build' else 0)
 if scenario.startswith('post-age-'):
  s['elapsed']+=110 if s['builds']==1 else int(scenario.rsplit('-',1)[1])
 if scenario=='build-fail':print('TOKEN_SENTINEL_PRIVATE 44.9876543');save();sys.exit(1)
 out=pathlib.Path(a[a.index('--out')+1]);out.write_text(json.dumps(dict(version='station_registration_artifact_v1',chain_id='777',network_id='testnet',transactions=[dict(station_id=x['station_id'],submitted_at=x['submitted_at']) for x in rows])))
 if scenario=='huge-artifact':out.write_text(out.read_text()+' '*65536)
 if scenario=='interrupted':save();os.kill(os.getppid(),signal.SIGTERM);sys.exit(1)
 print(json.dumps(dict(self_verified=scenario!='unverified',artifact=str(out),registrations=[])))
elif name=='curl':
 public=a[-1].endswith(('/readyz','/network/info'))
 cfg='' if '--config' not in a else sys.stdin.read()
 assert 'TOKEN_SENTINEL_PRIVATE' not in ' '.join(a)
 # Public routes go tokenless; every other node read keeps the token via config stdin.
 assert ('TOKEN_SENTINEL_PRIVATE' not in cfg and '--config' not in a) if public else 'TOKEN_SENTINEL_PRIVATE' in cfg
 assert '--max-time' in a and '--connect-timeout' in a
 output=pathlib.Path(a[a.index('--output')+1]);headers=pathlib.Path(a[a.index('--dump-header')+1]);url=a[-1]
 status=200;body={}
 if url.endswith('/readyz'):
  status=503 if scenario=='health' else 200;body={'ready':True}
 elif url.endswith('/transactions/oracle/status'):body=dict(active_features=[])
 elif url.endswith('/network/info'):body=dict(chain_id='999' if scenario=='identity' else '777',network_id='testnet',chain_height=123)
 elif '--data-binary' in a:
  data=json.loads(pathlib.Path(a[a.index('--data-binary')+1][1:]).read_text());assert set(data)=={'chain_id','network_id','transactions'}
  # The fake node models the protocol window, not the wrapper's POST margin.
  assert 0<=now-data['transactions'][0]['submitted_at']<=150
  s['posts']+=1;status=422 if scenario=='rejection' else 201
  body=dict(accepted=2 if scenario=='accepted-mismatch' else len(s['rows']))
  if scenario.startswith('ambiguous'):save();sys.exit(28)
 else:
  preflight=s['posts']==0
  status=(200 if scenario=='already-registered' else 404) if preflight else (404 if scenario=='inclusion-timeout' else 200)
  if scenario=='ambiguous-many':status=404  # Unknown admission must stay unknown on every later read.
  found=next(x for x in s.get('rows',s['preview']) if x['station_id']==url.rsplit('/',1)[1])
  body=dict(station_id=found['station_id'],owner_address=found['owner_address'],provenance_class='synthetic' if scenario=='wrong-provenance' else 'real',is_active=True)
  if scenario=='preflight-stale' and s['posts']==0:s['elapsed']+=151
 output.write_text(json.dumps(body));headers.write_text('HTTP/1.1 '+str(status)+'\r\nDate: '+email.utils.formatdate(now+ (30 if scenario=='node-clock' else 0),usegmt=True)+'\r\n\r\n');print(status)
else:raise RuntimeError('unexpected fake')
save()
'''


class OwnerFlow(unittest.TestCase):
    def run_flow(self, scenario='ok', extra=(), staged=False, relative_paths=False):
        with tempfile.TemporaryDirectory(prefix='sol-a-activation-test-') as temp:
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
            key.chmod(0o644 if scenario=='key-mode' else 0o600)
            state = root / 'state.json'
            state.write_text(json.dumps(dict(scenario=scenario,elapsed=0,events=[],posts=0,builds=0,cleanups=0,build_stamps=[])))
            env = dict(os.environ, PATH=str(tools)+':'+os.environ['PATH'], FAKE_STATE=str(state), TMPDIR=str(root))
            cli_arg = str((tools/'wrfcoin').relative_to(root)) if relative_paths else str(tools/'wrfcoin')
            key_arg = str(key.relative_to(root)) if relative_paths else str(key)
            argv = ['bash', str(REPO/'testnet/scripts/activate-mobile-stations.sh'), '--cli', cli_arg, '--cli-sha', hashlib.sha256(fake.read_bytes()).hexdigest(), '--governance-key', key_arg, '--producer', 'a=prod-a', '--producer', 'b=prod-b', '--producer', 'c=prod-c', *extra]
            steps = root/'owner steps'
            if staged:
                argv += ['--stage-dir',str(steps),'--count','23']
            result = subprocess.run(argv, cwd=root, env=env, text=True, capture_output=True, timeout=30)
            if staged:
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertEqual(json.loads(state.read_text())['events'],[], 'staging must be offline')
                self.assertEqual(steps.stat().st_mode & 0o777,0o700)
                names=['001-dry-run.sh','002-activate.sh','003-dry-run.sh','004-activate.sh']
                self.assertEqual(sorted(p.name for p in steps.glob('*.sh')),names)
                for name in names:
                    self.assertEqual((steps/name).stat().st_mode & 0o777,0o700)
                    self.assertEqual(subprocess.run(['bash','-n',str(steps/name)]).returncode,0)
                self.assertIn('--limit 2', (steps/'004-activate.sh').read_text())
                run_text=(steps/'002-activate.sh').read_text()
                self.assertIn('--receipt-dir',run_text);self.assertIn('batch-1.complete',run_text)
                self.assertNotIn('--receipt-dir',(steps/'001-dry-run.sh').read_text())
                def run_step(name):
                    return subprocess.run(['bash',str(steps/name)],env=env,text=True,capture_output=True,timeout=30)
                self.assertNotEqual(run_step('003-dry-run.sh').returncode,0)
                self.assertNotEqual(run_step('002-activate.sh').returncode,0)
                self.assertEqual(json.loads(state.read_text())['events'],[])
                dry=run_step('001-dry-run.sh')
                self.assertEqual(dry.returncode,0,dry.stdout+dry.stderr)
                self.assertEqual(json.loads(state.read_text())['posts'],0)
                result=run_step('002-activate.sh')
                if scenario.startswith('ambiguous'):
                    self.assertNotEqual(result.returncode,0)
                    self.assertFalse((steps/'batch-1.complete').exists())
                else:
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertTrue((steps/'batch-1.complete').exists())
                before_retry=json.loads(state.read_text())
                retry=run_step('002-activate.sh')
                self.assertNotEqual(retry.returncode,0)
                self.assertEqual(json.loads(state.read_text())['posts'],before_retry['posts'],
                                 'ambiguous admission must never cause another POST')
                self.assertIn('STOP: attempt recorded',retry.stdout+retry.stderr)
                self.assertEqual(json.loads(state.read_text()),before_retry,
                                 'repeat activation must invoke no tool and never sign or POST again')
                self.assertNotEqual(run_step('001-dry-run.sh').returncode,0)
                self.assertEqual(json.loads(state.read_text()),before_retry)
                if scenario.startswith('ambiguous'):
                    self.assertNotEqual(run_step('003-dry-run.sh').returncode,0)
                    self.assertNotEqual(run_step('004-activate.sh').returncode,0)
                    self.assertEqual(json.loads(state.read_text()),before_retry)
                self.assertEqual(before_retry['posts'],1)
            data = json.loads(state.read_text())
            self.assertNotIn('TOKEN_SENTINEL_PRIVATE', result.stdout+result.stderr)
            self.assertNotIn('KEY_SENTINEL_PRIVATE', result.stdout+result.stderr)
            self.assertNotIn('ENV_SENTINEL_PRIVATE', result.stdout+result.stderr)
            self.assertNotIn('44.9876543', result.stdout+result.stderr)
            self.assertNotIn('mob-00000000000000000000000000000001', result.stdout+result.stderr)
            self.assertFalse(list(root.glob('msr-activation-*')), 'private files must be cleaned')
            return result, data

    def test_complete_order_and_counts(self):
        result, state = self.run_flow()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('ACTIVATION OBSERVED: 1/1 stations active', result.stdout)
        self.assertEqual(state['posts'], 1)
        commands=[a for name,a in state['events'] if name=='docker' and 'scripts/export-mobile-station-registrations.ts' in a]
        self.assertEqual(commands[0][commands[0].index('--limit')+1], '21')
        names=[name for name,a in state['events']]
        self.assertLess(names.index('timedatectl'), names.index('wrfcoin'))

    def test_dry_run_exports_without_signing_or_post(self):
        result,state=self.run_flow('many',('--limit','2','--dry-run'))
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('DRY RUN PASS: 2 eligible rows; no signature or submission',result.stdout)
        self.assertEqual(state['builds'],0)
        self.assertEqual(state['posts'],0)
        self.assertEqual(state['cleanups'],1)

    def test_staged_owner_steps_are_offline_ordered_and_single_attempt(self):
        result,state=self.run_flow('many',staged=True)
        self.assertEqual(state['posts'],1)

    def test_staged_relative_cli_and_key_preserve_invocation_directory(self):
        result,state=self.run_flow('many',staged=True,relative_paths=True)
        self.assertEqual(state['posts'],1)

    def test_staged_ambiguous_post_cannot_be_retried(self):
        result,state=self.run_flow('ambiguous-many',staged=True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(state['posts'],1)

    def test_requested_count_shortfall_stops_before_signing(self):
        result,state=self.run_flow(extra=('--limit','2','--require-count'))
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(state['builds'],0)
        self.assertEqual(state['posts'],0)

    def test_dry_run_rechecks_preconditions_and_rows(self):
        for scenario in ['clock','health','oversize','export-fail','cleanup-fail']:
            with self.subTest(scenario=scenario):
                result,state=self.run_flow(scenario,('--dry-run',))
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(state['posts'],0)
                self.assertEqual(state['builds'],0)

    def test_per_row_progress_uses_index_without_station_ids(self):
        result,state=self.run_flow('many',('--limit','2'))
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        for index in [1,2]:
            self.assertIn(f'ROW {index}/2: station active, registered to owner',result.stdout)
            self.assertIn(f'ROW {index}/2: on_chain',result.stdout)
        self.assertIn('RECEIPT:',result.stdout);self.assertNotIn('ACTIVATION PASS',result.stdout)

    def test_stale_inputs_never_retried_or_posted(self):
        for scenario,extra in [('ok',('--submitted-at','1789999849','--restamp-once')), ('stale-export',('--restamp-once',)), ('stale-build',('--restamp-once',))]:
            with self.subTest(scenario=scenario):
                result,state=self.run_flow(scenario,extra)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(state['posts'],0)
                self.assertLessEqual(state['builds'],1)

    def test_explicit_pre_submit_restamp_rebuild(self):
        result,state=self.run_flow('slow-build',('--restamp-once',))
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(state['builds'],2)
        self.assertGreater(state['build_stamps'][1],state['build_stamps'][0])
        self.assertEqual(state['posts'],1)

    def test_restamped_receipt_carries_the_stamp_that_was_actually_posted(self):
        with tempfile.TemporaryDirectory(prefix='receipt-restamp-') as rdir:
            os.chmod(rdir,0o700)
            result,state=self.run_flow('slow-build',('--restamp-once','--receipt-dir',rdir))
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            receipts=list(Path(rdir).glob('*.receipt.json'))
            self.assertEqual(len(receipts),1)
            body=json.loads(receipts[0].read_text())
            self.assertEqual(state['builds'],2)
            self.assertGreater(state['build_stamps'][1],state['build_stamps'][0])
            self.assertEqual(body['submitted_at'],state['build_stamps'][1],'receipt must carry the POSTed stamp')
            self.assertNotEqual(body['submitted_at'],state['build_stamps'][0])

    def test_no_implicit_retry(self):
        result,state=self.run_flow('slow-build')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(state['posts'],0)

    def test_post_margin_after_one_explicit_rebuild(self):
        for elapsed in [120,121,135,149]:
            with self.subTest(elapsed=elapsed):
                result,state=self.run_flow(f'post-age-{elapsed}',('--restamp-once',))
                self.assertEqual(state['builds'],2)
                self.assertGreater(state['build_stamps'][1],state['build_stamps'][0])
                self.assertEqual(1790000000+state['elapsed']-state['build_stamps'][1],elapsed)
                if elapsed == 120:
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertEqual(state['posts'],1)
                else:
                    self.assertNotEqual(result.returncode,0)
                    self.assertIn('submit budget exceeded; no submission',result.stdout)
                    self.assertEqual(state['posts'],0)

    def test_node_host_override_is_loopback_only(self):
        for url,loopback in [
            ('http://127.0.0.1:8556',True),
            ('http://127.0.0.2:8556',True),
            ('http://localhost:8556',True),
            ('http://[::1]:8556',True),
            ('https://example.invalid:8556',False),
            ('https://192.0.2.1:8556',False),
        ]:
            with self.subTest(url=url):
                result,state=self.run_flow(extra=('--node-url',url))
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                requests=[a for name,a in state['events'] if name=='curl']
                self.assertGreater(len(requests),0)
                for args in requests:
                    headers=[args[i+1] for i,x in enumerate(args) if x=='--header']
                    hosts=[h for h in headers if h.lower().startswith('host:')]
                    self.assertEqual(hosts,['Host: 127.0.0.1'] if loopback else [])

    def test_stage_failures_stop_with_counts_only(self):
        for scenario in ['clock','node-clock','health','identity','sync-off','already-registered','export-fail','cat-fail','cleanup-fail','build-fail','unverified','oversize','huge-artifact','interrupted','rejection','accepted-mismatch','ambiguous','inclusion-timeout','wrong-provenance','db-timeout']:
            with self.subTest(scenario=scenario):
                result,state=self.run_flow(scenario,('--restamp-once',))
                self.assertNotEqual(result.returncode,0,scenario)
                self.assertLessEqual(state['posts'],1)
                if scenario in ['clock','node-clock','health','identity','sync-off','already-registered','export-fail','cat-fail','cleanup-fail','build-fail','unverified','oversize','huge-artifact','interrupted']:
                    self.assertEqual(state['posts'],0)

    def test_multiple_invitees_preserve_distinct_rows(self):
        for limit in [2,21]:
            with self.subTest(limit=limit):
                result,state=self.run_flow('many',('--limit',str(limit)))
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn(f'ACTIVATION OBSERVED: {limit}/{limit} stations active',result.stdout)
                self.assertEqual(len({x['station_id'] for x in state['rows']}),limit)
                self.assertEqual(state['posts'],1)

    def test_explicit_stamp_expires_during_preflight(self):
        result,state=self.run_flow('preflight-stale',('--submitted-at','1790000000','--restamp-once'))
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(state['posts'],0)
        self.assertEqual(state['builds'],0)
        self.assertFalse(any('scripts/export-mobile-station-registrations.ts' in a for _,a in state['events']))

    def test_bad_limits_fail_before_external_work(self):
        for limit in ['0','22','64','no','TOKEN_SENTINEL_PRIVATE']:
            with self.subTest(limit=limit):
                result,state=self.run_flow(extra=('--limit',limit))
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(state['events'],[])

    def test_key_mode_and_cli_digest_fail_before_external_work(self):
        for scenario,extra in [('key-mode',()),('ok',('--cli-sha','0'*64))]:
            with self.subTest(scenario=scenario):
                result,state=self.run_flow(scenario,extra)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(state['events'],[])

    def test_an_old_or_unreadable_producer_stops_before_any_token_node_sign_or_post(self):
        for scenario in ('producer-old','producer-read-error'):
            with self.subTest(scenario=scenario):
                result,state=self.run_flow(scenario)
                self.assertNotEqual(result.returncode,0)
                names=[e[0] for e in state['events']]
                self.assertTrue(set(names)<={'date','timedatectl','docker'} and 'curl' not in names)
                self.assertEqual(state['builds'],0);self.assertEqual(state['posts'],0)
                self.assertFalse(any(e[0]=='docker' and e[1][0]=='exec' for e in state['events']))
                self.assertFalse(any(e[0]=='docker' and 'WRFCOIN' in ' '.join(e[1]) for e in state['events']))

    def test_missing_producer_inputs_fail_before_external_work(self):
        with tempfile.TemporaryDirectory(prefix='fence-args-') as temp:
            cli=Path(temp)/'c';cli.write_text('x');key=Path(temp)/'k';key.write_text('x');key.chmod(0o600)
            result=subprocess.run(['bash',str(REPO/'testnet/scripts/activate-mobile-stations.sh'),'--cli',str(cli),
                '--governance-key',str(key),'--producer','a=prod-a'],text=True,capture_output=True,timeout=30)
            self.assertEqual(result.returncode,1)
            self.assertIn('exactly three --producer',result.stdout)

    def test_remote_node_token_requires_https(self):
        result,state=self.run_flow(extra=('--node-url','http://example.invalid:8556'))
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(state['events'],[])
        result,state=self.run_flow(extra=('--node-url','https://example.invalid:8556'))
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(state['posts'],1)


if __name__ == '__main__':
    unittest.main()
