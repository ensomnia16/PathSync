import base64
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import graph_index as g

CURSOR='https://graph.microsoft.com/v1.0/drives/drive/items/root/delta?token=one'
NEXT='https://graph.microsoft.com/v1.0/drives/drive/items/root/delta?token=two'
class GraphIndexTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
  self.root=Path(self.tmp.name);self.local=self.root/'local';self.cloud=self.root/'cloud'
  self.local.mkdir();self.cloud.mkdir();self.db=self.root/'index.sqlite';self.calls=[]
 def index(self,fetch,drive='drive'):
  obj=g.GraphIndex(self.db,self.local,self.cloud,drive,'文档/test',fetch)
  self.addCleanup(obj.close);return obj
 def file(self,name='a.txt',content=b'base',parent='root',identity='a'):
  p=self.local/name;p.parent.mkdir(exist_ok=True,parents=True);p.write_bytes(content)
  h=g.content_hashes(p)
  return {'id':identity,'name':p.name,'parentReference':{'id':parent},'size':len(content),
   'file':{'hashes':{'quickXorHash':h['quickXorHash']}},
   'fileSystemInfo':{'lastModifiedDateTime':datetime.fromtimestamp(p.stat().st_mtime,timezone.utc).isoformat()}}
 def seeded(self,items):
  def fetch(url):
   self.calls.append(url)
   if '/root:/' in url:return {'id':'root','name':'test','folder':{}}
   return {'value':items,'@odata.deltaLink':CURSOR}
  x=self.index(fetch);x.refresh();return x
 def test_colon_entity_matches_file_provider_name(self):
  f=self.file('a:b.txt');f['name']='a&#x3a;b.txt'
  (self.cloud/'a:b.txt').write_bytes(b'base')
  x=self.seeded([f]);self.assertIn('a:b.txt',x.entries);self.assertEqual(x.stats['mapped_names'],1)
 def test_literal_entity_exact_mirror_name_is_preserved(self):
  f=self.file('a&#x3a;b.txt');(self.cloud/f['name']).write_bytes(b'base')
  x=self.seeded([f]);self.assertIn('a&#x3a;b.txt',x.entries)
 def test_ambiguous_decoded_name_rolls_back(self):
  f=self.file('a:b.txt');other={**f,'id':'second','name':'a&#x3a;b.txt'}
  with self.assertRaises(g.IndexError):self.seeded([f,other])
 def test_restart_uses_one_delta_request_and_disk_hash_cache(self):
  f=self.file();x=self.seeded([f]);sig=[4,self.local.joinpath('a.txt').stat().st_mtime_ns]
  self.assertEqual(x.verified_common('a.txt',self.local/'a.txt',sig),hashlib.sha256(b'base').hexdigest())
  x.flush_hashes();self.assertEqual(x.stats['hash_reads'],1)
  calls=[]
  def fetch(url):calls.append(url);return {'value':[],'@odata.deltaLink':NEXT}
  y=self.index(fetch);y.refresh()
  self.assertEqual(calls,[CURSOR]);self.assertEqual(y.stats['rebuilt'],0)
  self.assertTrue(y.verified_common('a.txt',self.local/'a.txt',sig));self.assertEqual(y.stats['hash_hits'],1)
  self.assertEqual(os.stat(self.db).st_mode&0o777,0o600)
 def test_partial_delta_never_commits_items_or_cursor(self):
  f=self.file();x=self.seeded([f]);calls=[]
  def fetch(url):
   calls.append(url)
   if url==CURSOR:return {'value':[{'id':'a','deleted':{}}],'@odata.nextLink':NEXT}
   raise g.HTTPFailure(503,'unavailable')
  y=self.index(fetch)
  with self.assertRaises(g.HTTPFailure):y.refresh()
  self.assertFalse(y.fresh);self.assertEqual(y.meta('cursor'),CURSOR)
  self.assertEqual(y.db.execute('SELECT count(*) FROM items').fetchone()[0],1)
 def test_rename_parent_updates_descendant_path(self):
  f=self.file('old/a.txt',parent='dir');x=self.seeded([{'id':'dir','name':'old','folder':{},'parentReference':{'id':'root'}},f])
  x.fetch=lambda _: {'value':[{'id':'dir','name':'new','folder':{},'parentReference':{'id':'root'}}],'@odata.deltaLink':NEXT}
  x.refresh();self.assertIn('new/a.txt',x.entries);self.assertNotIn('old/a.txt',x.entries)
 def test_deleted_folder_removes_cached_descendants(self):
  f=self.file('d/a.txt',parent='dir');x=self.seeded([{'id':'dir','name':'d','folder':{},'parentReference':{'id':'root'}},f])
  x.fetch=lambda _: {'value':[{'id':'dir','deleted':{}}],'@odata.deltaLink':NEXT}
  x.refresh();self.assertEqual(x.entries,{})
 def test_expired_cursor_rebuilds_once(self):
  f=self.file();x=self.seeded([f]);calls=[]
  def fetch(url):
   calls.append(url)
   if url==CURSOR:raise g.HTTPFailure(410,'resyncRequired')
   return {'value':[],'@odata.deltaLink':NEXT}
  x.fetch=fetch;x.refresh();self.assertEqual(len(calls),2);self.assertEqual(x.entries,{})
  self.assertEqual(x.stats['rebuilt'],1);self.assertEqual(x.meta('cursor'),NEXT)
 def test_account_change_does_not_reuse_cursor(self):
  self.seeded([self.file()]);calls=[]
  def fetch(url):
   calls.append(url)
   return {'id':'root2','folder':{}} if '/root:/' in url else {'value':[],'@odata.deltaLink':NEXT}
  x=self.index(fetch,drive='other');x.refresh();self.assertNotIn(CURSOR,calls);self.assertEqual(len(calls),2)
 def test_read_failure_preserves_old_binding(self):
  x=self.seeded([self.file()]);old=x.meta('binding')
  y=self.index(lambda _: (_ for _ in ()).throw(g.HTTPFailure(401)),drive='other')
  with self.assertRaises(g.HTTPFailure):y.refresh()
  self.assertEqual(y.meta('binding'),old);self.assertFalse(y.fresh)
 def test_no_hash_or_unaligned_provider_metadata_does_not_read_local(self):
  f=self.file();f['file']={'hashes':{}};x=self.seeded([f])
  self.assertIsNone(x.verified_common('a.txt',self.local/'a.txt',[4,0]));self.assertEqual(x.stats['hash_reads'],0)
 def test_same_size_edit_with_restored_mtime_rehashes(self):
  f=self.file();x=self.seeded([f]);p=self.local/'a.txt';info=p.stat();sig=[4,info.st_mtime_ns]
  self.assertTrue(x.verified_common('a.txt',p,sig));x.flush_hashes();p.write_bytes(b'edit');os.utime(p,ns=(info.st_atime_ns,info.st_mtime_ns))
  self.assertIsNone(x.verified_common('a.txt',p,sig));self.assertEqual(x.stats['hash_reads'],2)
 def test_symlink_is_never_hashed(self):
  (self.local/'real').write_bytes(b'base');(self.local/'link').symlink_to(self.local/'real')
  with self.assertRaises(g.IndexError):g.content_hashes(self.local/'link')
 def test_unsafe_names_rollback(self):
  x=self.index(lambda u:{'id':'root','folder':{}} if '/root:/' in u else {'value':[{'id':'bad','name':'../bad','file':{},'parentReference':{'id':'root'}}],'@odata.deltaLink':CURSOR})
  with self.assertRaises(g.IndexError):x.refresh()
  self.assertIsNone(x.meta('cursor'))
 def test_untrusted_cursor_is_not_saved(self):
  x=self.index(lambda u:{'id':'root','folder':{}} if '/root:/' in u else {'value':[],'@odata.deltaLink':'https://evil.invalid/v1.0/leak'})
  with self.assertRaises(g.IndexError):x.refresh()
  self.assertIsNone(x.meta('cursor'))
 def test_incomplete_hierarchy_does_not_advance_cursor(self):
  f=self.file(parent='missing');x=self.index(lambda u:{'id':'root','folder':{}} if '/root:/' in u else {'value':[f],'@odata.deltaLink':CURSOR})
  with self.assertRaises(g.IndexError):x.refresh()
  self.assertIsNone(x.meta('cursor'))
 def test_client_never_sends_token_to_content_or_foreign_host(self):
  c=g.GraphClient('fixture-not-a-real-token')
  for url in ['https://evil.invalid/v1.0/me','https://graph.microsoft.com/v1.0/me/drive/root/content','http://graph.microsoft.com/v1.0/me']:
   with self.assertRaises(g.IndexError):c.get(url)
  self.assertEqual(c.requests,0)
 def test_native_hash_known_vectors(self):
  p=self.local/'a';p.write_bytes(b'abc');r=g.content_hashes(p)
  self.assertEqual(r['sha256'],hashlib.sha256(b'abc').hexdigest())
  q=bytearray(20);v=0
  for i,b in enumerate(b'abc'):v^=b<<(i*11)
  v^=3<<96
  self.assertEqual(r['quickXorHash'],base64.b64encode(v.to_bytes(20,'little')).decode())

if __name__=='__main__':unittest.main()
