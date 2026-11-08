import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import uuid
from types import SimpleNamespace
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pathsync_cli as cli
from sync_tree import ExcludeRules


class AgentCLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.local = self.root/'local'; self.local.mkdir()
        self.drive = self.root/'OneDrive'; self.cloud = self.drive/'Documents/Research'; self.cloud.mkdir(parents=True)
        self.identity = str(uuid.uuid4())
        self.config = self.root/'config.json'
        self.doc = self.drive/'PathSync-Exclusions.json'
        self.settings = {'oneDriveRoot': str(self.drive), 'pairs': [{'id': self.identity, 'name':'研究',
            'enabled':True,'scheduledDirection':'merge','localPath':str(self.local), 'cloudPath':str(self.cloud),
            'excludeRules':'results/', 'cloudOnlyPaths':['Archive']}]}
        self.document = {'version':1,'excludeLatexIntermediates':False,'pairs':{'Documents/Research':{
            'excludeRules':'.venv/\nnode_modules/\n*.pyc\n# comment\n!unsupported\n',
            'syncCodexFiles':True,'syncClaudeFiles':True,'syncTemporaryFiles':True}}}
        self.write()

    def write(self):
        self.config.write_text(json.dumps(self.settings)); self.doc.write_text(json.dumps(self.document))

    def check(self, name, **kwargs): return cli.check_path(cli.policy(self.config), self.local/name, **kwargs)

    def run_cli(self, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = cli.main(['--config',str(self.config),*args,'--json'])
        return code, json.loads(output.getvalue())

    def test_shared_root_is_the_only_rule_authority(self):
        result, code = self.check('results/final.pdf')
        self.assertEqual(code,0); self.assertTrue(result['safeForImportantOutput'])
        self.assertFalse(result['synchronizationVerified'])
        (self.local/'.pathsyncignore').write_text('results/')
        self.assertEqual(self.check('results/final.pdf')[1],0)

    def test_nested_exclusion_uses_the_engine_matcher(self):
        for name in ['.venv/a.pdf','p/node_modules/x/final.png','p/c.pyc','tmp/final.pdf','.build/final.png','results/x.pdf']:
            result, code = self.check(name)
            expected = ExcludeRules(self.document['pairs']['Documents/Research']['excludeRules'].splitlines()).matches(name)
            self.assertEqual(code,3 if expected else 0,name)
            self.assertEqual(bool(result['matchedRules']),expected)

    def test_directory_only_pattern_is_explicit_for_future_directories(self):
        self.assertEqual(self.check('.venv',directory=True)[1],3)
        self.assertEqual(self.check('.venv',directory=False)[1],0)

    def test_cloud_only_exact_subtree_is_not_a_global_wildcard(self):
        self.assertEqual(self.check('Archive/final.pdf')[0]['classification'],'cloud_only')
        self.assertEqual(self.check('Archive-copy/final.pdf')[1],0)

    def test_disabled_and_download_only_pairs_are_not_eligible_outputs(self):
        self.settings['pairs'][0]['enabled']=False; self.write()
        self.assertEqual(self.check('results/a.pdf')[0]['classification'],'disabled_pair')
        self.settings['pairs'][0]['enabled']=True; self.settings['pairs'][0]['scheduledDirection']='download'; self.write()
        self.assertEqual(self.check('results/a.pdf')[0]['classification'],'upload_disabled')

    def test_outside_and_cloud_mirror_have_explicit_nonzero_status(self):
        snapshot=cli.policy(self.config)
        self.assertEqual(cli.check_path(snapshot,self.root/'elsewhere/final.pdf')[1],4)
        self.assertEqual(cli.check_path(snapshot,self.cloud/'final.pdf')[0]['classification'],'cloud_mirror')

    def test_symbolic_link_into_excluded_or_external_paths_is_never_approved(self):
        (self.local/'.venv').mkdir(); (self.local/'alias').symlink_to(self.local/'.venv')
        result,code=self.check('alias/final.pdf')
        self.assertEqual(code,3); self.assertEqual(result['classification'],'symbolic_link')
        (self.local/'outside').symlink_to(self.root)
        self.assertEqual(self.check('outside/final.pdf')[1],3)

    def test_protocol_partial_directories_and_retired_root_rule_are_protected(self):
        for name in ['a.researchsync-partial','stage.researchsync-partial/final.pdf','.pathsyncignore']:
            self.assertEqual(self.check(name)[0]['classification'],'protocol_protected')
        self.assertEqual(self.check('nested/.pathsyncignore')[1],0)

    def test_missing_invalid_or_legacy_root_rules_fail_closed(self):
        self.doc.unlink()
        self.assertEqual(self.run_cli('rules')[0],2)
        self.document['excludeLatexIntermediates']=True; self.write()
        self.assertEqual(self.run_cli('check-path',str(self.local/'results/a.pdf'))[0],2)
        self.document['excludeLatexIntermediates']=False; self.document['pairs'].clear(); self.write()
        self.assertEqual(self.run_cli('rules')[0],2)

    def test_root_policy_symlink_or_online_placeholder_is_not_read(self):
        self.doc.rename(self.root/'actual.json'); self.doc.symlink_to(self.root/'actual.json')
        with self.assertRaises(cli.PolicyError): cli.policy(self.config)

    def test_cloud_only_malformed_and_nested_policies_fail_closed(self):
        self.settings['pairs'][0]['cloudOnlyPaths']='Archive';self.write()
        self.assertEqual(self.run_cli('rules')[0],2)
        self.settings['pairs'][0]['cloudOnlyPaths']=['Archive','Archive/sub'];self.write()
        self.assertEqual(self.run_cli('rules')[0],2)

    def test_json_read_only_rules_and_checks_never_invoke_native_or_graph(self):
        before={self.config:self.config.read_bytes(),self.doc:self.doc.read_bytes()}
        with mock.patch.object(cli,'invoke',side_effect=AssertionError('native launched')):
            self.assertEqual(self.run_cli('rules')[0],0)
            self.assertEqual(self.run_cli('check-path',str(self.local/'results/final.pdf'))[0],0)
        for path,data in before.items():self.assertEqual(path.read_bytes(),data)
        self.assertFalse(list(self.local.iterdir()))

    def test_invalid_or_duplicate_pair_names_do_not_fall_back_to_sync_all(self):
        with mock.patch.object(cli,'invoke',side_effect=AssertionError('sync launched')):
            self.assertEqual(self.run_cli('sync','--pair','typo')[0],2)
            self.settings['pairs'].append({**self.settings['pairs'][0],'id':str(uuid.uuid4())});self.write()
            self.assertEqual(self.run_cli('sync','--pair','研究')[0],2)

    def test_agent_sync_and_preview_call_the_same_core_with_exact_uuid(self):
        fake=subprocess.CompletedProcess([],0,'uploaded=0 downloaded=0','')
        with mock.patch.object(cli,'invoke',return_value=fake) as invoke:
            code,result=self.run_cli('sync','--pair','研究')
            self.assertEqual(code,0);self.assertTrue(result['ok'])
            self.assertEqual(invoke.call_args.args[0],['--sync','--pair',self.identity])
            self.run_cli('preview','--pair','研究')
            self.assertEqual(invoke.call_args.args[0],['--dry-run','--pair',self.identity])

    def test_stopped_native_run_keeps_130_and_a_neutral_state(self):
        with mock.patch.object(cli,'invoke',return_value=subprocess.CompletedProcess([],130,'','stopped')):
            code,result=self.run_cli('sync','--pair','研究')
        self.assertEqual(code,130);self.assertEqual(result['state'],'stopped')

    def test_overlapping_roots_are_not_guessed(self):
        second={**self.settings['pairs'][0],'id':str(uuid.uuid4()),'name':'nested','localPath':str(self.local/'sub')}
        self.settings['pairs'].append(second);self.write()
        self.assertEqual(self.run_cli('check-path',str(self.local/'sub/final.pdf'))[0],2)

    def test_stop_request_is_uuid_scoped_and_does_not_change_config_or_rules(self):
        support=self.root/'support';support.mkdir();active={'runID':str(uuid.uuid4()),'pid':os.getpid()}
        (support/'active-sync.json').write_text(json.dumps(active))
        with mock.patch.object(cli,'sync_running',return_value=True):
            result=cli.request_stop(support)
        self.assertEqual(result['state'],'stop_requested')
        self.assertEqual(json.loads((support/'stop-sync.json').read_text()),active)
        self.assertEqual((support/'stop-sync.json').stat().st_mode&0o777,0o600)
        with mock.patch.object(cli,'sync_running',return_value=False):
            self.assertEqual(cli.request_stop(support)['state'],'idle')

    def test_dataless_rule_document_is_not_opened(self):
        before=self.doc.stat()
        fake=SimpleNamespace(**{**{key:getattr(before,key) for key in dir(before) if key.startswith('st_')},'st_flags':0x40000000})
        with mock.patch.object(Path,'lstat',return_value=fake),mock.patch.object(cli.os,'open',side_effect=AssertionError('hydration')):
            with self.assertRaisesRegex(cli.PolicyError,'仅在线'):cli.read_json(self.doc)


class GuidanceInstallTests(unittest.TestCase):
    def test_launcher_and_guidance_are_idempotent_and_preserve_existing_content(self):
        spec=importlib.util.spec_from_file_location('install_agent_cli',Path(__file__).resolve().parents[1]/'tools/install-agent-cli.py')
        installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)
        original='# User naming rules\nDo not change this.  \n\n'
        block=installer.BEGIN+'\nOutput rule\n'+installer.END
        merged=installer.merge_guidance(original,block)
        self.assertTrue(merged.startswith(original))
        self.assertEqual(installer.merge_guidance(merged,block),merged)
        with self.assertRaises(ValueError):installer.merge_guidance(original+installer.BEGIN,block)


if __name__=='__main__':unittest.main()
