#!/usr/bin/env python3
"""Unit tests for the python helper embedded in bucketool.sh.

    python3 tests/test_py.py
"""
import gzip
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPT = os.path.join(ROOT, 'bucketool.sh')


def load_helper():
    text = open(SCRIPT, encoding='utf-8').read()
    m = re.search(r"<<'PYEOF' \|\| true\n(.*?)\nPYEOF\n", text, re.S)
    assert m, 'embedded python not found'
    tmp = tempfile.NamedTemporaryFile('w', suffix='.py', delete=False)
    tmp.write(m.group(1))
    tmp.close()
    spec = importlib.util.spec_from_file_location('bucketool_helper', tmp.name)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    os.unlink(tmp.name)
    return mod


H = load_helper()


def capture(fn, *a):
    buf = io.StringIO()
    with redirect_stdout(buf):
        fn(*a)
    return buf.getvalue()


def shell_vars(text):
    """Parse NAME='value' lines emitted by the helper."""
    out = {}
    for line in text.splitlines():
        k, _, v = line.partition('=')
        out[k] = v.strip("'")
    return out


class UrlTests(unittest.TestCase):
    def test_s3_url_defaults_to_tls(self):
        d = H.parse_s3_url('s3://AK:S%2FK@minio.example.com:9000?provider=Minio&path_style=true')
        self.assertEqual(d['endpoint'], 'https://minio.example.com:9000')
        self.assertEqual((d['access_key'], d['secret_key']), ('AK', 'S/K'))
        self.assertEqual(d['provider'], 'Minio')

    def test_http_and_tls_false(self):
        self.assertEqual(H.parse_s3_url('http://a:b@h:9000')['endpoint'], 'http://h:9000')
        self.assertEqual(H.parse_s3_url('s3://a:b@h:9000?tls=false')['endpoint'], 'http://h:9000')

    def test_unknown_params_pass_through(self):
        d = H.parse_s3_url('s3://a:b@h?storage_class=STANDARD_IA')
        self.assertEqual(d['options'], {'storage_class': 'STANDARD_IA'})

    def test_endpoint_id(self):
        ep = H.build_endpoint({'name': 'x', 'url': 'https://a:b@Host.Example:443'})
        self.assertEqual(H.endpoint_id(ep), 'host.example:443')
        ep = H.build_endpoint({'name': 'x', 'provider': 'AWS', 'region': 'eu-west-1', 'env_auth': True})
        self.assertEqual(H.endpoint_id(ep), 'aws-eu-west-1')


class KeyTests(unittest.TestCase):
    def test_problems(self):
        for key in ('a\nb', '/lead', 'x//y', 'a/../b', 'a/./b', 'dir/', 'L' * 256):
            self.assertTrue(H.key_problem(key), key)
        for key in ('plain.txt', 'sp ace/unié.txt', 'a/b/c', '.hidden', 'x' * 255):
            self.assertEqual(H.key_problem(key), '', key)

    def test_classify_markers_tiers_collisions(self):
        items = [
            {'Path': 'a', 'Size': 1, 'ModTime': '2026-01-01T00:00:00Z', 'IsDir': False},
            {'Path': 'a/b', 'Size': 2, 'ModTime': '2026-01-01T00:00:00Z', 'IsDir': False},
            {'Path': 'cold.bin', 'Size': 3, 'ModTime': '2026-01-01T00:00:00Z', 'IsDir': False, 'Tier': 'DEEP_ARCHIVE'},
            {'Path': 'marker', 'Size': 0, 'IsDir': True},
            {'Path': 'implied', 'Size': -1, 'IsDir': True},
        ]
        files, markers, skipped = H.classify(items)
        self.assertEqual(sorted(files), ['a/b'])
        self.assertEqual(markers, ['marker/'])
        reasons = {s['k']: s['reason'] for s in skipped}
        self.assertIn('folder', reasons['a'])
        self.assertIn('DEEP_ARCHIVE', reasons['cold.bin'])


class TimeTests(unittest.TestCase):
    def test_mtime_roundtrip(self):
        for s in ('2026-11-13T05:29:31.036000000Z', '2026-11-13T05:29:31Z', '2026-11-13T05:29:31.02Z'):
            ns = H.mtime_ns(s)
            self.assertEqual(H.mtime_ns(H.ns_str(ns)), ns)
        self.assertEqual(H.mtime_ns('2026-01-01T05:30:00+05:30'), H.mtime_ns('2026-01-01T00:00:00Z'))

    def test_parse_when(self):
        self.assertEqual(H.parse_when('2026-03-01'), H.ts_epoch('20260301T235959Z'))
        self.assertEqual(H.parse_when('20260301T020000Z'), H.ts_epoch('20260301T020000Z'))


class RetentionTests(unittest.TestCase):
    TS = ['20260301T020000Z', '20260215T020000Z', '20260201T020000Z', '20260115T020000Z',
          '20260101T020000Z', '20251201T020000Z']
    NOW = H.ts_epoch('20260310T000000Z')

    def plan(self, backups, **kw):
        a = dict(days=0, min_keep=1, kd=0, kw=0, km=0, ky=0)
        a.update(kw)
        return H.plan_retention(backups, a['days'], a['min_keep'], a['kd'], a['kw'], a['km'], a['ky'], self.NOW)

    def test_days(self):
        out = self.plan([(t, True) for t in self.TS], days=30)
        self.assertEqual(sorted(out), ['20251201T020000Z', '20260101T020000Z', '20260115T020000Z', '20260201T020000Z'])

    def test_min_keep_floor(self):
        out = self.plan([(t, True) for t in self.TS], days=1, min_keep=3)
        self.assertEqual(len(out), 3)
        self.assertNotIn('20260201T020000Z', out)

    def test_gfs_monthly(self):
        out = self.plan([(t, True) for t in self.TS], km=3)
        kept = sorted(set(self.TS) - set(out))
        self.assertEqual(kept, ['20260115T020000Z', '20260215T020000Z', '20260301T020000Z'])

    def test_failed_backups_never_count(self):
        bs = [('20260301T020000Z', False), ('20260215T020000Z', True), ('20260201T020000Z', True)]
        out = self.plan(bs, days=1, min_keep=1)
        self.assertNotIn('20260301T020000Z', out)      # newer than every good one: kept
        self.assertNotIn('20260215T020000Z', out)      # newest good backup: always kept
        self.assertIn('20260201T020000Z', out)

    def test_zero_days_keeps_everything(self):
        self.assertEqual(self.plan([(t, True) for t in self.TS]), {})


class ReconcileTests(unittest.TestCase):
    """The hardlink invariants: an older snapshot is never modified."""

    def setUp(self):
        self.d = tempfile.mkdtemp()

    def p(self, *a):
        return os.path.join(self.d, *a)

    def write(self, path, data, mtime):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as fh:
            fh.write(data)
        os.utime(path, ns=(mtime, mtime))

    def test_snapshot_reconcile(self):
        t0 = H.mtime_ns('2026-01-01T00:00:00Z')
        t1 = H.mtime_ns('2026-01-02T00:00:00Z')
        prev = self.p('prev', 'data')
        for k in ('same.txt', 'changed.txt', 'gone.txt'):
            self.write(os.path.join(prev, k), 'v1', t0)
        rows = {k: (2, t0, 'h-' + k) for k in ('same.txt', 'changed.txt', 'gone.txt')}
        H.write_manifest(self.p('prev', 'manifest.jsonl.gz'), rows, [])
        subprocess.check_call(['cp', '-al', prev, self.p('work')])
        listing = [
            {'Path': 'same.txt', 'Size': 2, 'ModTime': H.ns_str(t0), 'IsDir': False},
            {'Path': 'changed.txt', 'Size': 2, 'ModTime': H.ns_str(t1), 'IsDir': False},
            {'Path': 'new.txt', 'Size': 5, 'ModTime': H.ns_str(t1), 'IsDir': False},
        ]
        json.dump(listing, open(self.p('listing.json'), 'w'))
        os.makedirs(self.p('sd'))
        out = shell_vars(capture(H.cmd_reconcile, 'snapshot', self.p('listing.json'),
                                 self.p('prev', 'manifest.jsonl.gz'), prev, self.p('work'), self.p('sd'), ''))
        self.assertEqual(out['R_DL_COUNT'], '2')
        self.assertTrue(os.path.exists(self.p('work', 'same.txt')))
        self.assertFalse(os.path.exists(self.p('work', 'changed.txt')))   # unlinked, not overwritten
        self.assertFalse(os.path.exists(self.p('work', 'gone.txt')))
        self.assertEqual(open(os.path.join(prev, 'changed.txt')).read(), 'v1')
        self.assertEqual(sorted(H.read_lines(self.p('sd', 'delta.txt'))), ['changed.txt', 'new.txt'])
        self.assertEqual(H.read_lines(self.p('sd', 'deleted.txt')), ['gone.txt'])
        st = H.load_state(self.p('sd'))
        self.assertEqual(st['rows']['same.txt'][2], 'h-same.txt')       # hash inherited via shared inode

    def test_resumed_download_is_kept(self):
        t1 = H.mtime_ns('2026-01-02T00:00:00Z')
        self.write(self.p('work', 'done.bin'), 'abc', t1)                # finished by a killed run
        self.write(self.p('work', 'x.bin.partial'), 'ab', t1)            # temp file of a killed run
        json.dump([{'Path': 'done.bin', 'Size': 3, 'ModTime': H.ns_str(t1), 'IsDir': False}],
                  open(self.p('listing.json'), 'w'))
        os.makedirs(self.p('sd'))
        out = shell_vars(capture(H.cmd_reconcile, 'snapshot', self.p('listing.json'), '', '',
                                 self.p('work'), self.p('sd'), ''))
        self.assertEqual(out['R_DL_COUNT'], '0')
        self.assertFalse(os.path.exists(self.p('work', 'x.bin.partial')))


class ConfigTests(unittest.TestCase):
    def emit(self, path, *mode):
        r = subprocess.run([sys.executable, '-c', 'import sys;sys.argv=["h"]+sys.argv[1:];exec(open(%r).read())' % self.helper]
                           + [mode[0], path] + list(mode[1:]), capture_output=True, text=True, env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def setUp(self):
        text = open(SCRIPT, encoding='utf-8').read()
        m = re.search(r"<<'PYEOF' \|\| true\n(.*?)\nPYEOF\n", text, re.S)
        fd, self.helper = tempfile.mkstemp(suffix='.py')
        os.write(fd, m.group(1).encode())
        os.close(fd)
        self.env = dict(os.environ, MINIO_ACCESS_KEY='ak', MINIO_SECRET_KEY='sk', AWS_ACCESS_KEY_ID='a',
                        AWS_SECRET_ACCESS_KEY='s', OFFSITE_ACCESS_KEY='o', OFFSITE_SECRET_KEY='o')

    def tearDown(self):
        os.unlink(self.helper)

    def test_yaml_and_json_examples_agree(self):
        y = os.path.join(ROOT, 'bucketool.example.yml')
        j = os.path.join(ROOT, 'bucketool.example.json')
        for mode in (('defaults', 'CFG_'), ('names', 'sources'), ('names', 'targets'),
                     ('source', 'media', 'S_'), ('source', 'invoices', 'S_'), ('source', 'minio_all', 'S_'),
                     ('target', 'scratch', 'T_'), ('section', 'offsite', 'O_'), ('section', 'drill', 'D_')):
            self.assertEqual(self.emit(y, *mode), self.emit(j, *mode), mode)

    def test_endpoint_emits_env_not_argv(self):
        out = self.emit(os.path.join(ROOT, 'bucketool.example.yml'), 'endpoint', 'minio_prod', 'SRC', 'E_')
        self.assertIn("export RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY='sk'", out)
        self.assertIn("E_ID='minio.example.com:9000'", out)

    def test_bad_values_are_rejected(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, 'c.yml')
        for body in ('defaults:\n  format: rar\n', 'defaults:\n  retention_days: soon\n',
                     'endpoints:\n  e: {url: "s3://a:b@h"}\nsources:\n  - name: x\n    endpoint: e\n'):
            open(p, 'w').write(body)
            r = subprocess.run([sys.executable, self.helper, 'defaults', p, 'C_'] if 'sources' not in body
                               else [sys.executable, self.helper, 'source', p, 'x', 'S_'],
                               capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0, body)

    def test_age_needs_tar_format(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, 'c.yml')
        open(p, 'w').write('endpoints:\n  e: {url: "s3://a:b@h"}\nsources:\n  - name: x\n    endpoint: e\n'
                           '    bucket: bkt\n    format: zip\n    encrypt: age\n    age_recipients: [age1x]\n')
        r = subprocess.run([sys.executable, self.helper, 'source', p, 'x', 'S_'], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('tar.zst', r.stderr)


class ManifestTests(unittest.TestCase):
    def test_roundtrip_and_markers(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, 'm.jsonl.gz')
        rows = {'b': (1, H.mtime_ns('2026-01-01T00:00:00Z'), 'hb'), 'a\tb': (2, 5, 'ha')}
        H.write_manifest(p, rows, ['dir/'])
        got, markers = H.load_manifest(p)
        self.assertEqual(got, rows)
        self.assertEqual(markers, ['dir/'])
        with gzip.open(p, 'rt') as fh:
            self.assertEqual(json.loads(fh.readline())['k'], 'a\tb')   # sorted, tab survives


if __name__ == '__main__':
    unittest.main(verbosity=1)
