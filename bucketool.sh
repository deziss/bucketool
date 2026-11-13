#!/usr/bin/env bash
#
# bucketool.sh — S3 / MinIO bucket backup, restore and verify
#
# Description: Config-driven (YAML or JSON) backup tool for any S3-compatible
#              object store (AWS S3, MinIO, Ceph, R2, Wasabi, Garage, ...).
#              Backups land on local disk as hardlinked incremental snapshots
#              or as tar.zst / tar.gz / zip archives, each with a manifest that
#              drives verification, restore checks, retention and off-site copy.
# Usage:       ./bucketool.sh <command> [options]     (run with -h for full help)
# Prereqs:     bash 4+, python3, GNU coreutils/tar, flock, and either rclone
#              >= 1.66 or docker. Optional: zstd, pigz, age, curl.
#
# Copyright (C) 2026 Anshu Kushwaha
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option) any
# later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for more
# details: <https://www.gnu.org/licenses/>.
#
set -Eeuo pipefail
umask 077

readonly BUCKETOOL_VERSION="1.0.2"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME SCRIPT_DIR
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s/%s' "$SCRIPT_DIR" "$SCRIPT_NAME")"
BUCKETOOL_REPO="${BUCKETOOL_REPO:-deziss/bucketool}"
BUCKETOOL_UPDATE_CHANNEL="${BUCKETOOL_UPDATE_CHANNEL:-release}"
BUCKETOOL_UPDATE_URL="${BUCKETOOL_UPDATE_URL:-}"
readonly RCLONE_MIN="1.66.0"

# ===========================================================================
#  Embedded helper: config parsing + backup engine (python3 stdlib only)
# ===========================================================================
read -r -d '' BUCKETOOL_PY <<'PYEOF' || true
#!/usr/bin/env python3
# bucketool helper: config parsing and the backup engine (listing diff, reconcile,
# hashing, manifests, verify, retention, archives). Called by bucketool.sh.
import sys, os, re, json, gzip, hashlib, fnmatch, stat, time, calendar
import urllib.parse, tarfile, zipfile
from concurrent.futures import ThreadPoolExecutor

PROG = 'bucketool'
TS_RE = re.compile(r'^\d{8}T\d{6}Z$')


def die(msg, code=1):
    sys.stderr.write('%s: %s\n' % (PROG, msg))
    sys.exit(code)


def warn(msg):
    sys.stderr.write('%s: warning: %s\n' % (PROG, msg))


# ---------- minimal YAML subset parser (used only when PyYAML is absent) ----------
def _split_flow(s):
    out, buf, q, depth = [], '', None, 0
    for ch in s:
        if q:
            buf += ch
            if ch == q:
                q = None
        elif ch in '"\'':
            q = ch; buf += ch
        elif ch in '[{':
            depth += 1; buf += ch
        elif ch in ']}':
            depth -= 1; buf += ch
        elif ch == ',' and depth == 0:
            out.append(buf); buf = ''
        else:
            buf += ch
    if buf.strip():
        out.append(buf)
    return out


def _scalar(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in '"\'':
        return s[1:-1]
    if s in ('', '~', 'null', 'Null', 'NULL'):
        return None
    if s in ('true', 'True', 'TRUE', 'yes', 'on'):
        return True
    if s in ('false', 'False', 'FALSE', 'no', 'off'):
        return False
    if re.fullmatch(r'-?\d+', s):
        return int(s)
    if re.fullmatch(r'-?\d+\.\d+', s):
        return float(s)
    if s.startswith('[') and s.endswith(']'):
        inner = s[1:-1].strip()
        return [_scalar(x) for x in _split_flow(inner)] if inner else []
    if s.startswith('{') and s.endswith('}'):
        inner = s[1:-1].strip()
        d = {}
        for part in (_split_flow(inner) if inner else []):
            k, _, v = part.partition(':')
            d[k.strip().strip('"\'')] = _scalar(v)
        return d
    return s


def _strip_comment(line):
    q = None
    for i, ch in enumerate(line):
        if q:
            if ch == q:
                q = None
        elif ch in '"\'':
            q = ch
        elif ch == '#' and (i == 0 or line[i - 1] in ' \t'):
            return line[:i]
    return line


def _tokens(text):
    out = []
    for raw in text.splitlines():
        line = _strip_comment(raw).rstrip()
        if not line.strip() or line.strip() in ('---', '...'):
            continue
        indent = len(line) - len(line.lstrip(' '))
        out.append((indent, line.strip()))
    return out


def _parse(lines, i, indent):
    if i >= len(lines):
        return None, i
    _, first = lines[i]
    if first == '-' or first.startswith('- '):
        arr = []
        while i < len(lines):
            ind, content = lines[i]
            if ind != indent or not (content == '-' or content.startswith('- ')):
                break
            rest = content[2:].strip() if content.startswith('- ') else ''
            if rest == '':
                i += 1
                if i < len(lines) and lines[i][0] > ind:
                    child, i = _parse(lines, i, lines[i][0])
                    arr.append(child)
                else:
                    arr.append(None)
            elif re.match(r'^[^:\[{]+:(\s|$)', rest):
                sub = [(ind + 2, rest)]
                j = i + 1
                while j < len(lines) and lines[j][0] > ind:
                    sub.append(lines[j]); j += 1
                obj, _ = _parse(sub, 0, ind + 2)
                arr.append(obj); i = j
            else:
                arr.append(_scalar(rest)); i += 1
        return arr, i
    d = {}
    while i < len(lines):
        ind, content = lines[i]
        if ind < indent:
            break
        if ind > indent:
            die('config: cannot parse the line "%s" (indentation?) — install PyYAML or fix the YAML' % content)
        m = re.match(r'^("[^"]*"|\'[^\']*\'|[^:]+):\s*(.*)$', content)
        if not m:
            i += 1; continue
        k = m.group(1).strip().strip('"\'')
        v = m.group(2).strip()
        if v == '':
            nxt = i + 1
            if nxt < len(lines) and (lines[nxt][0] > ind or
                                     (lines[nxt][0] == ind and (lines[nxt][1] == '-' or lines[nxt][1].startswith('- ')))):
                child, i = _parse(lines, nxt, lines[nxt][0])
                d[k] = child
            else:
                d[k] = None; i += 1
        else:
            d[k] = _scalar(v); i += 1
    return d, i


def mini_yaml(text):
    obj, _ = _parse(_tokens(text), 0, 0)
    return obj if obj is not None else {}


def load_cfg(path):
    with open(path, 'r', encoding='utf-8') as fh:
        text = fh.read()
    stripped = text.lstrip()
    if stripped.startswith('{') or path.endswith('.json'):
        return json.loads(text)
    try:
        import yaml  # noqa
        return yaml.safe_load(text) or {}
    except ImportError:
        return mini_yaml(text)


# ---------- env handling ----------
ENVRE = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}')


def load_env_file(path):
    if not os.path.isfile(path):
        warn('env_file not found: %s' % path)
        return
    with open(path, 'r', encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('export '):
                line = line[7:].strip()
            if '=' not in line:
                continue
            k, v = line.split('=', 1)
            k = k.strip(); v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
                v = v[1:-1]
            os.environ.setdefault(k, v)


def expand(val):
    if not isinstance(val, str):
        return val

    def sub(m):
        name, default = m.group(1), m.group(2)
        if name in os.environ:
            return os.environ[name]
        if default is not None:
            return default
        warn('${%s} is not set (expanded to empty)' % name)
        return ''
    return ENVRE.sub(sub, val)


def deep_expand(o):
    if isinstance(o, dict):
        return {k: deep_expand(v) for k, v in o.items()}
    if isinstance(o, list):
        return [deep_expand(v) for v in o]
    return expand(o)


# ---------- shell emission ----------
def q(v):
    if v is None:
        return "''"
    if isinstance(v, bool):
        v = 'true' if v else 'false'
    return "'" + str(v).replace("'", "'\\''") + "'"


def emit(name, value):
    if isinstance(value, (list, tuple)):
        print('%s=(%s)' % (name, ' '.join(q(x) for x in value)))
    else:
        print('%s=%s' % (name, q(value)))


# ---------- config model ----------
DEFAULTS = {
    'backup_dir': '/backup/s3',
    'log_file': '',
    'format': 'snapshot',
    'compression_level': 6,
    'zstd_long': True,
    'cache': 'keep',
    'hash_workers': 4,
    'verify': 'quick',
    'retention_days': 30,
    'retention_min_keep': 3,
    'keep_daily': 0,
    'keep_weekly': 0,
    'keep_monthly': 0,
    'keep_yearly': 0,
    'transfers': 16,
    'checkers': 32,
    'bwlimit': '',
    'max_size': '',
    'min_free_space': '10%',
    'timeout': 14400,
    'lock_wait': 3600,
    'part_max_age_days': 7,
    'max_delete_percent': 50,
    'rclone': 'auto',
    'rclone_image': 'rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5',
    'rclone_flags': [],
    'engine': 'rclone',
    'aws_image': 'amazon/aws-cli:2.40.2@sha256:acc32af784911165a8e78b63950625d174ba79b800a66a436c974689c87cd755',
    'encrypt': 'none',
    'age_recipients': [],
    'age_recipients_file': '',
    'age_identity_file': '',
}
CHOICES = {
    'format': ('snapshot', 'tar.zst', 'tar.gz', 'zip'),
    'verify': ('none', 'quick', 'full'),
    'cache': ('keep', 'drop'),
    'encrypt': ('none', 'age'),
    'rclone': ('auto', 'native', 'docker'),
    'engine': ('rclone', 'aws'),
}
INTS = ('compression_level', 'hash_workers', 'retention_days', 'retention_min_keep', 'keep_daily',
        'keep_weekly', 'keep_monthly', 'keep_yearly', 'transfers', 'checkers', 'timeout',
        'lock_wait', 'part_max_age_days', 'max_delete_percent')
BOOLS = ('zstd_long',)
LISTS = ('age_recipients', 'rclone_flags')
OVERRIDABLE = ('format', 'compression_level', 'zstd_long', 'cache', 'verify', 'retention_days',
               'retention_min_keep', 'keep_daily', 'keep_weekly', 'keep_monthly', 'keep_yearly',
               'transfers', 'checkers', 'bwlimit', 'max_size', 'encrypt', 'age_recipients',
               'age_recipients_file', 'hash_workers')
NAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
BUCKET_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')


def as_bool(v, where):
    if isinstance(v, bool):
        return v
    if v is None:
        return False
    s = str(v).strip().lower()
    if s in ('true', 'yes', 'on', '1'):
        return True
    if s in ('false', 'no', 'off', '0', ''):
        return False
    die('%s: expected true or false, got %r' % (where, v))


def as_list(v):
    if v in (None, ''):
        return []
    if isinstance(v, (list, tuple)):
        return [str(x) for x in v if x not in (None, '')]
    return [str(v)]


def norm_settings(d, where):
    out = {}
    for k, v in d.items():
        if k in INTS:
            try:
                v = int(str(v).strip())
            except ValueError:
                die('%s.%s must be a whole number (got %r)' % (where, k, v))
            if v < 0:
                die('%s.%s must not be negative' % (where, k))
        elif k in BOOLS:
            v = as_bool(v, '%s.%s' % (where, k))
        elif k in CHOICES:
            v = '' if v is None else str(v).strip().lower()
            if v not in CHOICES[k]:
                die('%s.%s must be one of %s (got %r)' % (where, k, ' | '.join(CHOICES[k]), v))
        elif k in LISTS:
            v = as_list(v)
        elif v is None:
            v = ''
        out[k] = v
    return out


def effective_defaults(cfg):
    node = cfg.get('defaults') or {}
    if not isinstance(node, dict):
        die('defaults: must be a mapping')
    for k in node:
        if k not in DEFAULTS:
            warn('defaults.%s is not a known setting (typo?)' % k)
    d = dict(DEFAULTS)
    d.update(norm_settings({k: v for k, v in node.items() if k in DEFAULTS}, 'defaults'))
    return d


def entries(cfg, section):
    node = cfg.get(section)
    if node is None:
        return []
    out = []
    if isinstance(node, dict):
        for k, v in node.items():
            e = dict(v or {})
            e.setdefault('name', k)
            out.append(e)
    elif isinstance(node, list):
        out = [dict(e) for e in node if isinstance(e, dict)]
    else:
        die('%s: must be a list or a mapping' % section)
    for e in out:
        n = e.get('name')
        if n is None or not NAME_RE.match(str(n)):
            die('%s: every entry needs a name of letters, digits, ".", "_" or "-" (got %r)' % (section, n))
        e['name'] = str(n)
        if section == 'sources' and e['name'] in ('reports',):
            die('sources: "%s" is a reserved name' % e['name'])
    return out


def find(cfg, section, name):
    for e in entries(cfg, section):
        if e['name'] == name:
            return e
    die('"%s" is not defined under %s:' % (name, section))


# ---------- endpoints ----------
def parse_s3_url(url):
    url = url.strip()
    scheme, sep, rest = url.partition('://')
    if not sep:
        die('not an S3 URL: %s' % url)
    scheme = scheme.lower()
    if scheme not in ('s3', 'http', 'https'):
        die('unsupported URL scheme %r (use s3://, https:// or http://)' % scheme)
    userinfo, _, hostpart = rest.rpartition('@') if '@' in rest else ('', '', rest)
    hostport, _, query = hostpart.partition('?')
    hostport = hostport.split('/')[0]
    params = dict(urllib.parse.parse_qsl(query)) if query else {}
    ak = sk = ''
    if userinfo:
        a, _, s = userinfo.partition(':')
        ak, sk = urllib.parse.unquote(a), urllib.parse.unquote(s)
    tls = params.pop('tls', params.pop('secure', None))
    if scheme == 'http':
        secure = False
    elif scheme == 'https':
        secure = True
    else:
        secure = True if tls is None else as_bool(tls, 'url tls')
    out = {'endpoint': (('https://' if secure else 'http://') + hostport) if hostport else '',
           'access_key': ak, 'secret_key': sk}
    for k in ('provider', 'region', 'path_style', 'env_auth', 'engine'):
        if k in params:
            out[k] = params.pop(k)
    out['options'] = params
    return out


def _secret(e, keys, envkey, filekey, quiet=False):
    v = None
    for a in keys:
        if e.get(a) not in (None, ''):
            v = str(e[a]); break
    if e.get(envkey):
        name = str(e[envkey])
        if not re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', name) or (name not in os.environ and name.lower() == name):
            # most likely the secret itself was pasted here: never echo it
            die('endpoint %s: %s must be the NAME of a variable in env_file (e.g. MINIO_SECRET_KEY), '
                'not the key itself — put the value in the env file, or use %s: instead'
                % (e['name'], envkey, envkey[:-4]))
        if name not in os.environ:
            warn('endpoint %s: environment variable %s is not set (is env_file loaded?)' % (e['name'], name))
        v = os.environ.get(name, v)
    if e.get(filekey):
        p = os.path.expanduser(str(e[filekey]))
        try:
            with open(p, encoding='utf-8') as fh:
                v = fh.read().strip()
        except OSError as x:
            die('endpoint %s: cannot read %s: %s' % (e['name'], filekey, x))
    return v


def build_endpoint(e, default_engine='rclone', need_creds=True):
    if e.get('name') != 'url':
        check_keys(e, ENDPOINT_KEYS, 'endpoint')
    base = parse_s3_url(str(e['url'])) if e.get('url') else {'options': {}}
    engine = str(e.get('engine') or base.get('engine') or default_engine).strip().lower()
    if engine not in CHOICES['engine']:
        die('endpoint %s.engine must be rclone or aws (got %r)' % (e['name'], engine))
    ep = {
        'name': e['name'],
        'engine': engine,
        'provider': str(e.get('provider') or base.get('provider') or 'Other'),
        'endpoint': str(e.get('endpoint') or e.get('endpoint_url') or base.get('endpoint') or ''),
        'region': str(e.get('region') or base.get('region') or ''),
        'access_key': _secret(e, ('access_key', 'access_key_id'), 'access_key_env', 'access_key_file')
                      or base.get('access_key') or '',
        'secret_key': _secret(e, ('secret_key', 'secret_access_key'), 'secret_key_env', 'secret_key_file')
                      or base.get('secret_key') or '',
        'session_token': _secret(e, ('session_token',), 'session_token_env', 'session_token_file') or '',
        'env_auth': as_bool(e.get('env_auth', base.get('env_auth', False)), 'endpoint %s.env_auth' % e['name']),
        'path_style': e.get('path_style', base.get('path_style')),
        'options': dict(base.get('options') or {}),
    }
    opts = e.get('options') or {}
    if not isinstance(opts, dict):
        die('endpoint %s.options must be a mapping' % e['name'])
    ep['options'].update({str(k): v for k, v in opts.items()})
    if ep['endpoint'] and not re.match(r'^https?://', ep['endpoint']):
        ep['endpoint'] = 'https://' + ep['endpoint']
    if need_creds and not ep['env_auth'] and not (ep['access_key'] and ep['secret_key']):
        die('endpoint %s: no credentials (use access_key_env/secret_key_env, a url with key:secret, '
            'or env_auth: true)' % e['name'])
    return ep


def endpoint_id(ep):
    if ep['endpoint']:
        u = urllib.parse.urlsplit(ep['endpoint'])
        port = u.port or (443 if u.scheme == 'https' else 80)
        return '%s:%s' % ((u.hostname or '').lower(), port)
    return 'aws-%s' % (ep['region'] or 'default')


def emit_endpoint(ep, remote, pfx):
    r = 'RCLONE_CONFIG_%s_' % remote.upper()

    def ex(k, v):
        if isinstance(v, bool):
            v = 'true' if v else 'false'
        print('export %s%s=%s' % (r, k, q(v)))
    ex('TYPE', 's3')
    ex('PROVIDER', ep['provider'])
    if ep['endpoint']:
        ex('ENDPOINT', ep['endpoint'])
    if ep['region']:
        ex('REGION', ep['region'])
    if ep['env_auth']:
        ex('ENV_AUTH', 'true')
    if ep['access_key']:
        ex('ACCESS_KEY_ID', ep['access_key'])
    if ep['secret_key']:
        ex('SECRET_ACCESS_KEY', ep['secret_key'])
    if ep['session_token']:
        ex('SESSION_TOKEN', ep['session_token'])
    if ep['path_style'] not in (None, ''):
        ex('FORCE_PATH_STYLE', as_bool(ep['path_style'], 'path_style'))
    for k, v in sorted(ep['options'].items()):
        if not re.match(r'^[A-Za-z0-9_]+$', k):
            die('endpoint %s: invalid rclone option name %r' % (ep['name'], k))
        ex(k.upper(), v)
    emit(pfx + 'ID', endpoint_id(ep))
    emit(pfx + 'URL', ep['endpoint'] or '(AWS default endpoint)')
    emit(pfx + 'PROVIDER', ep['provider'])
    # for the aws-cli engine: plain shell variables, exported only inside its subshell
    emit(pfx + 'ENGINE', ep['engine'])
    emit(pfx + 'EPURL', ep['endpoint'])
    emit(pfx + 'REGION', ep['region'])
    emit(pfx + 'AK', ep['access_key'])
    emit(pfx + 'SK', ep['secret_key'])
    emit(pfx + 'TOKEN', ep['session_token'])
    emit(pfx + 'ENV_AUTH', ep['env_auth'])
    ps = ep['path_style']
    emit(pfx + 'PATH_STYLE', '' if ps in (None, '') else as_bool(ps, 'path_style'))


# ---------- sources / targets ----------
SOURCE_KEYS = {'name', 'endpoint', 'bucket', 'prefix', 'all_buckets', 'enabled', 'include', 'exclude',
               'include_buckets', 'exclude_buckets'} | set(OVERRIDABLE)
TARGET_KEYS = {'name', 'endpoint', 'bucket', 'prefix', 'create', 'scratch', 'verify'}
ENDPOINT_KEYS = {'name', 'url', 'engine', 'provider', 'endpoint', 'endpoint_url', 'region', 'access_key', 'access_key_id',
                 'access_key_env', 'access_key_file', 'secret_key', 'secret_access_key', 'secret_key_env',
                 'secret_key_file', 'session_token', 'session_token_env', 'session_token_file', 'env_auth',
                 'path_style', 'options'}


def check_keys(e, known, what):
    for k in e:
        if k not in known:
            die('%s %s: unknown setting %r (typo?)' % (what, e['name'], k))


def build_source(cfg, e, d):
    check_keys(e, SOURCE_KEYS, 'source')
    w = 'source %s' % e['name']
    out = {
        'NAME': e['name'],
        'ENDPOINT': str(e.get('endpoint') or ''),
        'BUCKET': str(e.get('bucket') or ''),
        'PREFIX': str(e.get('prefix') or '').strip('/'),
        'ALL_BUCKETS': as_bool(e.get('all_buckets', False), w + '.all_buckets'),
        'ENABLED': as_bool(e.get('enabled', True), w + '.enabled'),
        'INCLUDE': as_list(e.get('include')),
        'EXCLUDE': as_list(e.get('exclude')),
        'INCLUDE_BUCKETS': as_list(e.get('include_buckets')),
        'EXCLUDE_BUCKETS': as_list(e.get('exclude_buckets')),
    }
    if not out['ENDPOINT']:
        die('%s: endpoint is required' % w)
    find(cfg, 'endpoints', out['ENDPOINT'])
    if out['ALL_BUCKETS'] == bool(out['BUCKET']):
        die('%s: set exactly one of bucket: or all_buckets: true' % w)
    if out['BUCKET'] and not BUCKET_RE.match(out['BUCKET']):
        die('%s: invalid bucket name %r' % (w, out['BUCKET']))
    eff = dict(d)
    eff.update(norm_settings({k: e[k] for k in OVERRIDABLE if k in e}, w))
    for k in OVERRIDABLE:
        out[k.upper()] = eff[k]
    if eff['encrypt'] == 'age':
        if not eff['format'].startswith('tar.'):
            die('%s: encrypt: age needs format tar.zst or tar.gz (got %s)' % (w, eff['format']))
        if not eff['age_recipients'] and not eff['age_recipients_file']:
            die('%s: encrypt: age needs age_recipients or age_recipients_file' % w)
    return out


def build_target(cfg, e):
    check_keys(e, TARGET_KEYS, 'target')
    w = 'target %s' % e['name']
    out = {
        'NAME': e['name'],
        'ENDPOINT': str(e.get('endpoint') or ''),
        'BUCKET': str(e.get('bucket') or ''),
        'PREFIX': str(e.get('prefix') or '').strip('/'),
        'CREATE': as_bool(e.get('create', False), w + '.create'),
        'SCRATCH': as_bool(e.get('scratch', False), w + '.scratch'),
        'VERIFY': str(e.get('verify') or ''),
    }
    if not out['ENDPOINT'] or not out['BUCKET']:
        die('%s: endpoint and bucket are required' % w)
    find(cfg, 'endpoints', out['ENDPOINT'])
    if not BUCKET_RE.match(out['BUCKET']):
        die('%s: invalid bucket name %r' % (w, out['BUCKET']))
    if out['VERIFY'] and out['VERIFY'] not in CHOICES['verify']:
        die('%s.verify must be none | quick | full' % w)
    return out


def source_for_label(cfg, label):
    best = None
    for e in entries(cfg, 'sources'):
        if e['name'] == label:
            return e, ''
        if as_bool(e.get('all_buckets', False), 'all_buckets') and label.startswith(e['name'] + '_'):
            if best is None or len(e['name']) > len(best['name']):
                best = e
    if best:
        return best, label[len(best['name']) + 1:]
    return None, ''


SECTION_DEFAULTS = {
    'notify': {'webhook': '', 'on_success': False, 'healthcheck_url': ''},
    'metrics': {'textfile_dir': ''},
    'offsite': {'enabled': False, 'endpoint': '', 'bucket': '', 'prefix': '', 'retention_days': 90},
    'drill': {'target': '', 'sources': []},
}


def emit_section(cfg, name, pfx):
    node = dict(SECTION_DEFAULTS[name])
    given = cfg.get(name) or {}
    if not isinstance(given, dict):
        die('%s: must be a mapping' % name)
    node.update(given)
    if name == 'offsite':
        node['enabled'] = as_bool(node['enabled'], 'offsite.enabled')
        node['prefix'] = str(node.get('prefix') or '').strip('/')
        if node['enabled']:
            if not node['endpoint'] or not node['bucket']:
                die('offsite: endpoint and bucket are required when enabled')
            find(cfg, 'endpoints', str(node['endpoint']))
    if name == 'notify':
        node['on_success'] = as_bool(node['on_success'], 'notify.on_success')
    if name == 'drill':
        node['sources'] = as_list(node.get('sources'))
    for k, v in node.items():
        emit(pfx + k.upper(), v)


# ---------- time helpers ----------
MT_RE = re.compile(r'^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:?\d\d)?$')


def mtime_ns(s):
    m = MT_RE.match(s or '')
    if not m:
        return 0
    y, mo, d, h, mi, se = (int(x) for x in m.groups()[:6])
    frac = (m.group(7) or '0').ljust(9, '0')
    ns = calendar.timegm((y, mo, d, h, mi, se, 0, 0, 0)) * 10 ** 9 + int(frac)
    tz = m.group(8)
    if tz and tz != 'Z':
        sign = 1 if tz[0] == '+' else -1
        t = tz[1:].replace(':', '')
        ns -= sign * (int(t[:2]) * 3600 + int(t[2:]) * 60) * 10 ** 9
    return ns


def ns_str(ns):
    s, frac = divmod(int(ns), 10 ** 9)
    return time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(s)) + '.%09dZ' % frac


def ts_epoch(ts):
    return calendar.timegm(time.strptime(ts, '%Y%m%dT%H%M%SZ'))


def parse_when(s):
    """--at value -> epoch (UTC). A bare date means the end of that day."""
    s = s.strip()
    if TS_RE.match(s):
        return ts_epoch(s)
    for fmt, add in (('%Y-%m-%d', 86399), ('%Y-%m-%dT%H:%M', 59), ('%Y-%m-%d %H:%M', 59),
                     ('%Y-%m-%dT%H:%M:%S', 0), ('%Y-%m-%dT%H:%M:%SZ', 0)):
        try:
            return calendar.timegm(time.strptime(s, fmt)) + add
        except ValueError:
            pass
    die('cannot read the date %r (use 2026-11-10, 2026-11-10T14:30 or a backup timestamp)' % s)


# ---------- listing / keys ----------
ARCHIVE_TIERS = ('GLACIER', 'DEEP_ARCHIVE')


def key_problem(key):
    """Why an object key cannot be stored as a file below data/ ('' if it can)."""
    if not key:
        return 'empty key'
    if '\n' in key or '\r' in key:
        return 'line break in key'
    if '\x00' in key:
        return 'NUL byte in key'
    if key.startswith('/'):
        return 'leading slash'
    if key.endswith('/'):
        return 'data stored under a folder-style key ending in /'
    segs = key.split('/')
    if '' in segs:
        return 'empty path segment (//)'
    if any(s in ('.', '..') for s in segs):
        return '"." or ".." path segment'
    if any(len(s.encode('utf-8', 'surrogateescape')) > 255 for s in segs):
        return 'path segment longer than 255 bytes'
    return ''


def load_listing(path):
    with open(path, encoding='utf-8') as fh:
        data = json.load(fh)
    if not isinstance(data, list):
        die('unexpected listing format in %s' % path)
    return data


def classify(items):
    """lsjson items -> (files {key: (size, mtime_ns)}, markers [key/], skipped [dict])."""
    files, markers, skipped = {}, [], []
    for it in items:
        key = it.get('Path', '')
        if it.get('IsDir'):
            if it.get('Size') == 0 and not key_problem(key.rstrip('/')):
                markers.append(key.rstrip('/') + '/')
            continue
        reason = key_problem(key)
        tier = str(it.get('Tier') or '').upper()
        if not reason and tier in ARCHIVE_TIERS:
            reason = 'storage class %s must be restored on the server before it can be read' % tier
            skipped.append({'k': key, 's': it.get('Size'), 'reason': reason, 'tier': tier,
                            'm': mtime_ns(it.get('ModTime'))})
            continue
        if reason:
            skipped.append({'k': key, 's': it.get('Size'), 'reason': reason})
            continue
        files[key] = (int(it.get('Size') or 0), mtime_ns(it.get('ModTime')))
    dirs = set()
    for k in files:
        p = k.rfind('/')
        while p > 0:
            d = k[:p]
            if d in dirs:
                break
            dirs.add(d)
            p = k.rfind('/', 0, p)
    for k in [k for k in files if k in dirs]:
        skipped.append({'k': k, 's': files[k][0], 'reason': 'object name is also a folder of other objects'})
        del files[k]
    return files, sorted(set(markers)), skipped


def count_dirs(keys):
    dirs = set()
    for k in keys:
        p = k.rfind('/')
        while p > 0 and k[:p] not in dirs:
            dirs.add(k[:p])
            p = k.rfind('/', 0, p)
    return len(dirs)


# ---------- manifests / state ----------
def load_manifest(path):
    rows, markers = {}, []
    if not path or not os.path.isfile(path):
        return rows, markers
    with gzip.open(path, 'rt', encoding='utf-8') as fh:
        for line in fh:
            if not line.strip():
                continue
            r = json.loads(line)
            if r.get('d'):
                markers.append(r['k'])
            else:
                rows[r['k']] = (int(r['s']), mtime_ns(r['m']), r.get('h') or '')
    return rows, markers


def write_manifest(path, rows, markers):
    tmp = path + '.tmp'
    with open(tmp, 'wb') as raw:
        with gzip.GzipFile(fileobj=raw, mode='wb', compresslevel=6, mtime=0) as gz:
            for k in sorted(rows):
                s, m, h = rows[k]
                gz.write((json.dumps({'k': k, 's': s, 'm': ns_str(m), 'h': h}, ensure_ascii=False) + '\n').encode('utf-8'))
            for k in markers:
                gz.write((json.dumps({'k': k, 'd': 1}, ensure_ascii=False) + '\n').encode('utf-8'))
        raw.flush()
        os.fsync(raw.fileno())
    os.replace(tmp, path)


def state_path(sd):
    return os.path.join(sd, 'state.json')


def load_state(sd):
    with open(state_path(sd), encoding='utf-8') as fh:
        return json.load(fh)


def save_state(sd, st):
    tmp = state_path(sd) + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(st, fh, ensure_ascii=False)
    os.replace(tmp, state_path(sd))


def write_lines(path, keys):
    with open(path, 'w', encoding='utf-8') as fh:
        for k in keys:
            fh.write(k + '\n')


def read_lines(path):
    if not path or not os.path.isfile(path):
        return []
    with open(path, encoding='utf-8') as fh:
        return [ln.rstrip('\n') for ln in fh if ln.rstrip('\n')]


def walk_files(root):
    """Yield (key, path) for every non-directory entry below root."""
    for dp, dns, fns in os.walk(root):
        for fn in fns:
            p = os.path.join(dp, fn)
            yield os.path.relpath(p, root), p


def prune_empty_dirs(root):
    for dp, dns, fns in os.walk(root, topdown=False):
        if dp != root and not os.listdir(dp):
            try:
                os.rmdir(dp)
            except OSError:
                pass


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        while True:
            b = fh.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def diff_counts(files, prev):
    new = changed = unchanged = 0
    dl_bytes = largest = 0
    for k, (s, m) in files.items():
        p = prev.get(k)
        if p is None:
            new += 1
        elif (p[0], p[1]) != (s, m):
            changed += 1
        else:
            unchanged += 1
            continue
        dl_bytes += s
        largest = max(largest, s)
    deleted = sum(1 for k in prev if k not in files)
    return new, changed, deleted, unchanged, dl_bytes, largest


def cmd_estimate(listing, prev_manifest):
    files, markers, skipped = classify(load_listing(listing))
    prev, _ = load_manifest(prev_manifest)
    for sk in skipped:
        p = prev.get(sk['k']) if sk.get('tier') else None
        if p is not None and p[0] == sk['s']:
            files[sk['k']] = (p[0], p[1])
    new, changed, deleted, unchanged, dl, largest = diff_counts(files, prev)
    emit('E_FILES', len(files)); emit('E_BYTES', sum(s for s, _ in files.values()))
    emit('E_NEW', new); emit('E_CHANGED', changed); emit('E_DELETED', deleted)
    emit('E_UNCHANGED', unchanged); emit('E_DL_BYTES', dl); emit('E_DL_COUNT', new + changed)
    emit('E_LARGEST', largest); emit('E_DIRS', count_dirs(files)); emit('E_SKIPPED', len(skipped))
    emit('E_MARKERS', len(markers))


def cmd_reconcile(mode, listing, prev_manifest, prev_data, work, sd, redl_file):
    """Bring `work` in line with the listing: keep what is provably current,
    unlink everything else (this is what keeps hardlinked snapshots immutable),
    and write the list of objects that still have to be downloaded."""
    files, markers, skipped = classify(load_listing(listing))
    prev, _ = load_manifest(prev_manifest)
    # an object moved to an archive tier still exists: keep the copy we already have
    still = []
    for sk in skipped:
        p = prev.get(sk['k']) if sk.get('tier') else None
        if p is not None and p[0] == sk['s']:
            files[sk['k']] = (p[0], p[1])
            sk['reason'] += ' (kept the copy from the previous backup)'
        still.append(sk)
    skipped = still
    redl = set(read_lines(redl_file))
    os.makedirs(work, exist_ok=True)
    rows, removed = {}, 0
    for key, path in walk_files(work):
        st = os.lstat(path)
        e = files.get(key)
        keep, h = False, ''
        if e is not None and stat.S_ISREG(st.st_mode) and key not in redl and st.st_size == e[0]:
            s, m = e
            p = prev.get(key)
            same_as_prev = p is not None and (p[0], p[1]) == (s, m)
            if mode == 'snapshot':
                pst = None
                if prev_data:
                    try:
                        pst = os.lstat(os.path.join(prev_data, key))
                    except OSError:
                        pst = None
                if pst is not None and (pst.st_dev, pst.st_ino) == (st.st_dev, st.st_ino):
                    # hardlinked from the previous snapshot: valid only if the object did not change
                    if same_as_prev and p[2]:
                        keep, h = True, p[2]
                elif st.st_nlink == 1 and abs(st.st_mtime_ns - m) < 10 ** 9:
                    keep = True   # downloaded by an interrupted run of this backup
            elif abs(st.st_mtime_ns - m) < 10 ** 9:
                keep = True   # staging mirror: always re-hashed, its bytes are not trusted
        if keep:
            rows[key] = [e[0], e[1], h]
        else:
            os.unlink(path)
            removed += 1
    prune_empty_dirs(work)
    download = sorted(k for k in files if k not in rows)
    for k in download:
        rows[k] = [files[k][0], files[k][1], '']
    changed = sorted(k for k, (s, m) in files.items() if k not in prev or (prev[k][0], prev[k][1]) != (s, m))
    deleted = sorted(k for k in prev if k not in files)
    write_lines(os.path.join(sd, 'delta.txt'), download)
    write_lines(os.path.join(sd, 'changed.txt'), changed)
    write_lines(os.path.join(sd, 'deleted.txt'), deleted)
    new, nchanged, ndeleted, unchanged, _, _ = diff_counts(files, prev)
    save_state(sd, {'rows': rows, 'markers': markers, 'skipped': skipped, 'warnings': [],
                    'counts': {'new': new, 'changed': nchanged, 'deleted': ndeleted, 'unchanged': unchanged}})
    emit('R_DL_COUNT', len(download)); emit('R_DL_BYTES', sum(files[k][0] for k in download))
    emit('R_KEPT', len(rows) - len(download)); emit('R_REMOVED', removed)


def cmd_gate(sd, work, relist):
    st = load_state(sd)
    rows = st['rows']
    present, strays = {}, 0
    for key, path in walk_files(work):
        if key not in rows:
            os.unlink(path)       # deleted object, or a temp file of a killed transfer
            strays += 1
            continue
        present[key] = os.lstat(path).st_size
    mismatch = sorted(k for k, r in rows.items() if present.get(k) != r[0])
    if not relist:
        write_lines(os.path.join(sd, 'mismatch.txt'), mismatch)
        emit('G_MISMATCH', len(mismatch)); emit('G_STRAYS', strays)
        return
    now = {}
    for it in load_listing(relist):
        if not it.get('IsDir'):
            now[it.get('Path', '')] = (int(it.get('Size') or 0), mtime_ns(it.get('ModTime')))
    failed, dropped, accepted = [], [], []
    for k in mismatch:
        local = os.path.join(work, k)
        if k not in now:
            dropped.append({'k': k, 's': rows[k][0], 'reason': 'deleted on the source during the backup'})
        elif present.get(k) == now[k][0]:
            rows[k] = [now[k][0], now[k][1], '']
            accepted.append(k)
            continue
        elif (rows[k][0], rows[k][1]) != now[k]:
            dropped.append({'k': k, 's': now[k][0], 'reason': 'changed on the source during the backup'})
        else:
            failed.append(k)
            continue
        rows.pop(k, None)
        if os.path.lexists(local):
            os.unlink(local)
    st['skipped'].extend(dropped)
    st['warnings'].extend('%s: %s' % (d['k'], d['reason']) for d in dropped)
    save_state(sd, st)
    write_lines(os.path.join(sd, 'failed.txt'), failed)
    emit('G_FAILED', len(failed)); emit('G_DROPPED', len(dropped)); emit('G_ACCEPTED', len(accepted))


def cmd_finalize(sd, work, outdir, workers, mode):
    st = load_state(sd)
    rows = st['rows']
    todo = [k for k, r in rows.items() if not r[2]]

    def one(k):
        return k, sha256_file(os.path.join(work, k))
    with ThreadPoolExecutor(max(1, int(workers))) as ex:
        for k, d in ex.map(one, todo):
            rows[k][2] = d
    write_manifest(os.path.join(outdir, 'manifest.jsonl.gz'), {k: tuple(r) for k, r in rows.items()}, st['markers'])
    if st['skipped']:
        with open(os.path.join(outdir, 'skipped.jsonl'), 'w', encoding='utf-8') as fh:
            for s in st['skipped']:
                fh.write(json.dumps(s, ensure_ascii=False) + '\n')
    unique = 0
    if mode == 'snapshot':
        for k, r in rows.items():
            if os.lstat(os.path.join(work, k)).st_nlink == 1:
                unique += r[0]
    c = st['counts']
    emit('F_OBJECTS', len(rows)); emit('F_BYTES', sum(r[0] for r in rows.values()))
    emit('F_HASHED', len(todo)); emit('F_UNIQUE', unique); emit('F_SKIPPED', len(st['skipped']))
    emit('F_MARKERS', len(st['markers'])); emit('F_NEW', c['new']); emit('F_CHANGED', c['changed'])
    emit('F_DELETED', c['deleted']); emit('F_UNCHANGED', c['unchanged']); emit('F_WARNINGS', len(st['warnings']))


def cmd_members(manifest, out):
    rows, _ = load_manifest(manifest)
    with open(out, 'wb') as fh:
        for k in sorted(rows):
            fh.write(k.encode('utf-8', 'surrogateescape') + b'\0')


# ---------- meta.json ----------
def _coerce(v):
    if v.startswith('json:'):
        return json.loads(v[5:])
    if re.fullmatch(r'-?\d+', v):
        return int(v)
    if v in ('true', 'false'):
        return v == 'true'
    return v


def cmd_meta_set(path, pairs):
    meta = {}
    if os.path.isfile(path):
        with open(path, encoding='utf-8') as fh:
            meta = json.load(fh)
    for p in pairs:
        k, _, v = p.partition('=')
        meta[k] = _coerce(v)
    import tempfile
    fd, tmp = tempfile.mkstemp(prefix='.meta.', dir=os.path.dirname(os.path.abspath(path)))
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        json.dump(meta, fh, indent=2, sort_keys=True, ensure_ascii=False)
        fh.write('\n')
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def read_meta(bdir):
    try:
        with open(os.path.join(bdir, 'meta.json'), encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def list_backups(ldir):
    """Completed backups of one label, newest first: (ts, good, meta, path)."""
    out = []
    if not os.path.isdir(ldir):
        return out
    for n in os.listdir(ldir):
        p = os.path.join(ldir, n)
        if TS_RE.match(n) and os.path.isdir(p):
            meta = read_meta(p)
            if meta is None:
                continue
            out.append((n, meta.get('verify') not in ('failed', 'pending'), meta, p))
    out.sort(key=lambda b: b[0], reverse=True)
    return out


def labels_in(bdir):
    try:
        names = sorted(os.listdir(bdir))
    except OSError:
        return []
    return [n for n in names if not n.startswith('.') and n != 'reports' and os.path.isdir(os.path.join(bdir, n))]


def cmd_resolve(bdir, name):
    """NAME -> labels: the label itself, or every label an all_buckets source produced."""
    if os.path.isdir(os.path.join(bdir, name)) and not name.startswith('.'):
        print(name)
        return
    hits = []
    for lab in labels_in(bdir):
        b = list_backups(os.path.join(bdir, lab))
        if b and str(b[0][2].get('source')) == name:
            hits.append(lab)
    for h in hits:
        print(h)


def cmd_pick(ldir, which, when):
    bs = list_backups(ldir)
    if which == 'any':
        bs = bs[:1]
    elif which == 'good':
        bs = [b for b in bs if b[1]][:1]
    elif which == 'at':
        lim = parse_when(when)
        bs = [b for b in bs if b[1] and ts_epoch(b[0]) <= lim][:1]
    if bs:
        print(bs[0][3])


# ---------- retention ----------
def plan_retention(backups, days, min_keep, kd, kw, km, ky, now):
    """backups: [(ts, good)] newest first -> {ts: reason} to delete."""
    goods = [ts for ts, good in backups if good]
    keep = set(goods[:max(1, min_keep)])
    if any((kd, kw, km, ky)):
        for n, fmt in ((kd, '%Y-%m-%d'), (kw, '%G-W%V'), (km, '%Y-%m'), (ky, '%Y')):
            last, left = None, n
            for ts in goods:
                if left <= 0:
                    break
                key = time.strftime(fmt, time.gmtime(ts_epoch(ts)))
                if key != last:
                    keep.add(ts); left -= 1; last = key
        why = 'outside keep_daily/weekly/monthly/yearly'
    elif days > 0:
        cutoff = now - days * 86400
        keep.update(ts for ts in goods if ts_epoch(ts) >= cutoff)
        why = 'older than %d days' % days
    else:
        keep.update(goods)
        why = ''
    out = {}
    newest_good = goods[0] if goods else None
    for ts, good in backups:
        if ts in keep:
            continue
        if not good:
            if newest_good and ts < newest_good:
                out[ts] = 'failed verification, newer good backup exists'
        elif why:
            out[ts] = why
    return out


def cmd_retention(ldir, days, min_keep, kd, kw, km, ky, now):
    bs = [(b[0], b[1]) for b in list_backups(ldir)]
    plan = plan_retention(bs, int(days), int(min_keep), int(kd), int(kw), int(km), int(ky), int(now))
    for ts in sorted(plan):
        print('%s\t%s' % (ts, plan[ts]))


def cmd_label_policy(cfg, label, pfx):
    d = effective_defaults(cfg)
    e, _ = source_for_label(cfg, label)
    if e is not None:
        d.update(norm_settings({k: e[k] for k in OVERRIDABLE if k in e}, 'source ' + e['name']))
    if e is not None and 'retention_days' in e and any(d[k] for k in ('keep_daily', 'keep_weekly', 'keep_monthly', 'keep_yearly')):
        warn('source %s sets retention_days, but keep_* (GFS) is active and takes precedence' % e['name'])
    for k in ('retention_days', 'retention_min_keep', 'keep_daily', 'keep_weekly', 'keep_monthly', 'keep_yearly'):
        emit(pfx + k.upper(), d[k])
    emit(pfx + 'KNOWN', e is not None)


def cmd_freeable(bdir):
    total = 0
    for _, p in walk_files(bdir):
        st = os.lstat(p)
        if st.st_nlink == 1:
            total += st.st_size
    print(total)


# ---------- verify ----------
def report(lines, path):
    if path:
        with open(path, 'a', encoding='utf-8') as fh:
            for ln in lines:
                fh.write(ln + '\n')


def cmd_verify_tree(bdir, data, full, workers, ldir, sel, rep):
    rows, _ = load_manifest(os.path.join(bdir, 'manifest.jsonl.gz'))
    if sel:
        want = set(read_lines(sel))
        rows = {k: v for k, v in rows.items() if k in want}
    present = {}
    if os.path.isdir(data):
        for key, path in walk_files(data):
            present[key] = os.lstat(path)
    probs = []
    for k, (s, m, h) in sorted(rows.items()):
        st = present.get(k)
        if st is None:
            probs.append(('MISSING', k, ''))
        elif st.st_size != s:
            probs.append(('SIZE', k, 'expected %d bytes, found %d' % (s, st.st_size)))
    if not sel:
        for k in sorted(set(present) - set(rows)):
            probs.append(('EXTRA', k, 'not in the manifest'))
    bad_size = {p[1] for p in probs}
    if full:
        todo = [k for k in rows if k in present and k not in bad_size]

        def one(k):
            return k, sha256_file(os.path.join(data, k))
        with ThreadPoolExecutor(max(1, int(workers))) as ex:
            for k, d in ex.map(one, todo):
                if d != rows[k][2]:
                    probs.append(('HASH', k, 'content differs from the manifest'))
    lines = []
    damaged = [p[1] for p in probs if p[0] in ('SIZE', 'HASH')]
    for kind, k, why in probs:
        lines.append('%-8s %s%s' % (kind, k, ('  (' + why + ')') if why else ''))
    if damaged and ldir:
        # a damaged inode is shared by every snapshot that hardlinks it
        for k in damaged:
            st = present[k]
            shared = []
            for ts, _, _, p in list_backups(ldir):
                try:
                    o = os.lstat(os.path.join(p, 'data', k))
                except OSError:
                    continue
                if (o.st_dev, o.st_ino) == (st.st_dev, st.st_ino) and os.path.realpath(p) != os.path.realpath(bdir):
                    shared.append(ts)
            if shared:
                lines.append('SHARED   %s  (same damaged file in: %s)' % (k, ', '.join(shared)))
        with open(os.path.join(ldir, '.redownload'), 'a', encoding='utf-8') as fh:
            for k in damaged:
                fh.write(k + '\n')
    for ln in lines:
        print(ln)
    report(lines, rep)
    print('checked %d objects (%s): %s' % (len(rows), 'size+sha256' if full else 'presence+size',
                                           'OK' if not probs else '%d problem(s)' % len(probs)))
    sys.exit(1 if probs else 0)


def _compare_members(rows, seen, full, rep):
    probs = []
    for k, (s, m, h) in sorted(rows.items()):
        got = seen.get(k)
        if got is None:
            probs.append('MISSING  %s' % k)
        elif got[0] != s:
            probs.append('SIZE     %s  (expected %d bytes, found %d)' % (k, s, got[0]))
        elif full and got[1] != h:
            probs.append('HASH     %s  (content differs from the manifest)' % k)
    for k in sorted(set(seen) - set(rows)):
        probs.append('EXTRA    %s  (not in the manifest)' % k)
    for ln in probs:
        print(ln)
    report(probs, rep)
    print('checked %d archive members (%s): %s' % (len(rows), 'size+sha256' if full else 'list+size',
                                                   'OK' if not probs else '%d problem(s)' % len(probs)))
    sys.exit(1 if probs else 0)


def _hash_stream(fh):
    h = hashlib.sha256()
    while True:
        b = fh.read(1 << 20)
        if not b:
            break
        h.update(b)
    return h.hexdigest()


def cmd_verify_tar(manifest, full, rep):
    rows, _ = load_manifest(manifest)
    seen = {}
    with tarfile.open(fileobj=sys.stdin.buffer, mode='r|') as tf:
        for ti in tf:
            if not ti.isfile():
                continue
            h = _hash_stream(tf.extractfile(ti)) if full else ''
            seen[ti.name] = (ti.size, h)
    _compare_members(rows, seen, full, rep)


def cmd_verify_zip(archive, manifest, full, rep):
    rows, _ = load_manifest(manifest)
    seen = {}
    with zipfile.ZipFile(archive) as z:
        for zi in z.infolist():
            if zi.is_dir():
                continue
            h = ''
            if full:
                with z.open(zi) as fh:     # zipfile checks each member's CRC while reading
                    h = _hash_stream(fh)
            seen[zi.filename] = (zi.file_size, h)
    _compare_members(rows, seen, full, rep)


def cmd_verify_target(sel, manifest, listing, rep):
    rows, _ = load_manifest(manifest)
    want = read_lines(sel)
    got = {}
    for it in load_listing(listing):
        if not it.get('IsDir'):
            got[it.get('Path', '')] = int(it.get('Size') or 0)
    probs = []
    for k in want:
        if k not in got:
            probs.append('MISSING  %s' % k)
        elif got[k] != rows[k][0]:
            probs.append('SIZE     %s  (expected %d bytes, found %d)' % (k, rows[k][0], got[k]))
    for ln in probs:
        print(ln)
    report(probs, rep)
    print('checked %d restored objects (presence+size): %s' % (len(want), 'OK' if not probs else '%d problem(s)' % len(probs)))
    sys.exit(1 if probs else 0)


# ---------- restore helpers ----------
def cmd_select(manifest, prefix, out, globs):
    rows, markers = load_manifest(manifest)
    prefix = prefix.strip('/')
    pre = prefix + '/' if prefix else ''

    def ok(k):
        if pre and not (k.startswith(pre) or k == prefix):
            return False
        return not globs or any(fnmatch.fnmatchcase(k, g) for g in globs)
    keys = [k for k in sorted(rows) if ok(k)]
    mk = [m for m in markers if not pre or m.startswith(pre)]
    write_lines(out, keys)
    write_lines(out + '.markers', mk)
    emit('S_COUNT', len(keys)); emit('S_BYTES', sum(rows[k][0] for k in keys)); emit('S_MARKERS', len(mk))


def _safe_dest(dest, name):
    if key_problem(name):
        die('refusing unsafe archive member %r' % name)
    p = os.path.join(dest, name)
    if not os.path.realpath(p).startswith(os.path.realpath(dest) + os.sep):
        die('refusing archive member outside the restore directory: %r' % name)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    return p


def cmd_tar_extract(dest, sel):
    want = set(read_lines(sel)) if sel else None
    os.makedirs(dest, exist_ok=True)
    n = 0
    with tarfile.open(fileobj=sys.stdin.buffer, mode='r|') as tf:
        for ti in tf:
            if not ti.isfile() or (want is not None and ti.name not in want):
                continue
            p = _safe_dest(dest, ti.name)
            with open(p, 'wb') as out:
                src = tf.extractfile(ti)
                while True:
                    b = src.read(1 << 20)
                    if not b:
                        break
                    out.write(b)
            os.utime(p, (ti.mtime, ti.mtime))
            n += 1
    emit('X_COUNT', n)


def cmd_zip_pack(work, manifest, out, level):
    rows, _ = load_manifest(manifest)
    level = int(level)
    comp = zipfile.ZIP_DEFLATED if level > 0 else zipfile.ZIP_STORED
    kw = {'compresslevel': min(9, level)} if level > 0 else {}
    with zipfile.ZipFile(out, 'w', compression=comp, allowZip64=True, strict_timestamps=False, **kw) as z:
        for k in sorted(rows):
            z.write(os.path.join(work, k), arcname=k)


def cmd_zip_extract(archive, dest, sel):
    want = set(read_lines(sel)) if sel else None
    n = 0
    with zipfile.ZipFile(archive) as z:
        for zi in z.infolist():
            if zi.is_dir() or (want is not None and zi.filename not in want):
                continue
            p = _safe_dest(dest, zi.filename)
            with z.open(zi) as src, open(p, 'wb') as out:
                while True:
                    b = src.read(1 << 20)
                    if not b:
                        break
                    out.write(b)
            t = calendar.timegm(zi.date_time + (0, 0, 0))
            os.utime(p, (t, t))
            n += 1
    emit('X_COUNT', n)


# ---------- buckets / discovery ----------
def bucket_selected(name, inc, exc):
    if inc and not any(fnmatch.fnmatchcase(name, g) for g in inc):
        return False
    return not any(fnmatch.fnmatchcase(name, g) for g in exc)


def cmd_buckets(listing, spec):
    sp = json.loads(spec)
    for it in load_listing(listing):
        n = it.get('Path', '').strip('/')
        if it.get('IsDir') and n and bucket_selected(n, sp.get('include', []), sp.get('exclude', [])):
            print(n)


def cmd_discover(cfg, epid, listing):
    covers = []
    for e in entries(cfg, 'sources'):
        if not as_bool(e.get('enabled', True), 'enabled'):
            continue
        ep = build_endpoint(find(cfg, 'endpoints', str(e.get('endpoint'))))
        if endpoint_id(ep) == epid:
            covers.append(e)
    for it in load_listing(listing):
        b = it.get('Path', '').strip('/')
        if not it.get('IsDir') or not b:
            continue
        who = ''
        for e in covers:
            if as_bool(e.get('all_buckets', False), 'all_buckets'):
                if bucket_selected(b, as_list(e.get('include_buckets')), as_list(e.get('exclude_buckets'))):
                    who = '%s (all_buckets)' % e['name']; break
            elif str(e.get('bucket')) == b:
                who = e['name'] + ('  prefix ' + str(e.get('prefix')) if e.get('prefix') else ''); break
        print('%s\t%s' % (b, who))


def bare_endpoint_id(cfg, name):
    """endpoint_id without resolving credentials (they may be unreadable for this user)."""
    e = find(cfg, 'endpoints', name)
    base = parse_s3_url(str(e['url'])) if e.get('url') else {}
    ep = {'endpoint': str(e.get('endpoint') or e.get('endpoint_url') or base.get('endpoint') or ''),
          'region': str(e.get('region') or base.get('region') or '')}
    if ep['endpoint'] and not re.match(r'^https?://', ep['endpoint']):
        ep['endpoint'] = 'https://' + ep['endpoint']
    return endpoint_id(ep)


def cmd_bucket_owner(cfg, epid, bucket):
    """Name of a configured source that reads this bucket on this server.
    Exit 3 when none does; any other failure is an error the caller must not read as 'none'."""
    for e in entries(cfg, 'sources'):
        sid = bare_endpoint_id(cfg, str(e.get('endpoint')))
        # AWS bucket names are global: any two AWS-default endpoints are the same server
        if sid != epid and not (sid.startswith('aws-') and epid.startswith('aws-')):
            continue
        if as_bool(e.get('all_buckets', False), 'all_buckets'):
            if bucket_selected(bucket, as_list(e.get('include_buckets')), as_list(e.get('exclude_buckets'))):
                print(e['name']); return
        elif str(e.get('bucket')) == bucket:
            print(e['name']); return
    sys.exit(3)


# ---------- list / metrics ----------
def human(n):
    n = float(n)
    for u in ('B', 'KB', 'MB', 'GB', 'TB'):
        if n < 1024 or u == 'TB':
            return ('%.0f%s' if u == 'B' else '%.1f%s') % (n, u)
        n /= 1024


def physical_bytes(path):
    seen, total = set(), 0
    for _, p in walk_files(path):
        st = os.lstat(p)
        if (st.st_dev, st.st_ino) not in seen:
            seen.add((st.st_dev, st.st_ino))
            total += st.st_size
    return total


def cmd_list(bdir, only):
    labs = [l for l in labels_in(bdir) if not only or l == only]
    if not labs:
        print('  (no backups in %s)' % bdir)
        return
    for lab in labs:
        bs = list_backups(os.path.join(bdir, lab))
        parts = [n for n in os.listdir(os.path.join(bdir, lab)) if n.endswith('.part')]
        logical = sum(int(b[2].get('bytes') or 0) for b in bs if b[2].get('format') == 'snapshot')
        phys = physical_bytes(os.path.join(bdir, lab))
        print('\n%s  %d backup(s)%s  on disk %s%s' % (
            lab, len(bs), ('  [%d interrupted run(s)]' % len(parts)) if parts else '', human(phys),
            ('  (snapshots hold %s logical: hardlinks save %s)' % (human(logical), human(max(0, logical - phys))))
            if logical > phys else ''))
        print('  %-18s %-8s %9s %10s %10s  %-10s %s' % ('BACKUP', 'FORMAT', 'OBJECTS', 'SIZE', 'NEW DATA', 'VERIFY', 'OFFSITE'))
        for ts, good, m, p in bs:
            print('  %-18s %-8s %9s %10s %10s  %-10s %s' % (
                ts, m.get('format', '?'), m.get('objects', '?'), human(m.get('bytes') or 0),
                human(m.get('unique_bytes') or m.get('archive_bytes') or 0), m.get('verify', '?'),
                m.get('offsite') or '-'))


def cmd_metrics(bdir):
    out = []

    def g(name, help_, rows):
        out.append('# HELP bucketool_%s %s' % (name, help_))
        out.append('# TYPE bucketool_%s gauge' % name)
        for lab, v in rows:
            out.append('bucketool_%s{label="%s"} %s' % (name, lab.replace('"', ''), v))
    data = []
    for lab in labels_in(bdir):
        bs = list_backups(os.path.join(bdir, lab))
        if bs:
            data.append((lab, bs))
    goods = [(lab, [b for b in bs if b[1]]) for lab, bs in data]
    g('last_success_timestamp_seconds', 'Finish time of the newest good backup.',
      [(lab, int(gb[0][2].get('finished_epoch') or ts_epoch(gb[0][0]))) for lab, gb in goods if gb])
    g('last_backup_ok', '1 if the newest backup passed verification.',
      [(lab, 1 if bs[0][1] else 0) for lab, bs in data])
    g('backup_objects', 'Objects in the newest backup.', [(lab, int(bs[0][2].get('objects') or 0)) for lab, bs in data])
    g('backup_bytes', 'Logical bytes in the newest backup.', [(lab, int(bs[0][2].get('bytes') or 0)) for lab, bs in data])
    g('backup_unique_bytes', 'Bytes the newest backup added on disk.',
      [(lab, int(bs[0][2].get('unique_bytes') or bs[0][2].get('archive_bytes') or 0)) for lab, bs in data])
    g('backup_skipped_objects', 'Objects that could not be backed up.',
      [(lab, int(bs[0][2].get('skipped') or 0)) for lab, bs in data])
    g('backup_duration_seconds', 'Duration of the newest backup.',
      [(lab, int(bs[0][2].get('duration_s') or 0)) for lab, bs in data])
    g('backups', 'Number of backups kept.', [(lab, len(bs)) for lab, bs in data])
    print('\n'.join(out))


# ---------- aws-cli engine ----------
def _aws_doc(path):
    try:
        with open(path, encoding='utf-8') as fh:
            text = fh.read().strip()
    except OSError:
        return {}
    return json.loads(text) if text else {}


def aws_selected(key, spec):
    """aws-cli filter semantics: shell globs on the key relative to the prefix ('*' crosses '/')."""
    if any(fnmatch.fnmatchcase(key, g) for g in spec.get('exclude') or []):
        return False
    inc = spec.get('include') or []
    return not inc or any(fnmatch.fnmatchcase(key, g) for g in inc)


def cmd_aws_listing(raw, out, prefix, spec_json):
    """list-objects-v2 JSON -> the lsjson shape the engine reads (keys relative to prefix)."""
    spec = json.loads(spec_json or '{}')
    prefix = prefix.strip('/')
    pre = prefix + '/' if prefix else ''
    maxs = spec.get('max_size')
    items, toobig = [], []
    for o in _aws_doc(raw).get('Contents') or []:
        k = o.get('Key', '')
        if pre:
            if not k.startswith(pre):
                continue
            k = k[len(pre):]
        if not k:
            continue
        size = int(o.get('Size') or 0)
        if not aws_selected(k, spec):
            continue
        if maxs is not None and size > int(maxs):
            toobig.append(k)
            continue
        if k.endswith('/') and size == 0:
            items.append({'Path': k.rstrip('/'), 'Size': 0, 'IsDir': True})
        else:
            items.append({'Path': k, 'Size': size, 'ModTime': o.get('LastModified', ''), 'IsDir': False,
                          'Tier': o.get('StorageClass', '')})
    with open(out, 'w', encoding='utf-8') as fh:
        json.dump(items, fh, ensure_ascii=False)
    write_lines(out + '.toobig', toobig)


def _aws_escape(k):
    return ''.join('[%s]' % c if c in '*?[' else c for c in k)


def cmd_aws_sync_args(sd, spec_json, toobig, out):
    """`aws s3 sync` filter arguments that download exactly the objects bucketool expects."""
    spec = json.loads(spec_json or '{}')
    args = []
    if spec.get('include'):
        args += ['--exclude', '*']
        for g in spec['include']:
            args += ['--include', g]
    for g in spec.get('exclude') or []:
        args += ['--exclude', g]
    args += ['--exclude', '*/']                     # folder markers and folder-style keys
    for s in load_state(sd)['skipped']:
        args += ['--exclude', _aws_escape(s['k'])]
    for k in read_lines(toobig):
        args += ['--exclude', _aws_escape(k)]
    with open(out, 'wb') as fh:
        for a in args:
            fh.write(a.encode('utf-8', 'surrogateescape') + b'\0')


def cmd_aws_buckets(raw, out):
    items = [{'Path': b['Name'], 'Size': -1, 'IsDir': True} for b in _aws_doc(raw).get('Buckets') or []]
    with open(out, 'w', encoding='utf-8') as fh:
        json.dump(items, fh)


def cmd_aws_prefixes(raw):
    for p in _aws_doc(raw).get('CommonPrefixes') or []:
        print(p['Prefix'].rstrip('/').rsplit('/', 1)[-1])


def cmd_aws_delete_batches(sel, markers, prefix, outdir):
    prefix = prefix.strip('/')
    pre = prefix + '/' if prefix else ''
    keys = [pre + k for k in read_lines(sel)] + [pre + m for m in read_lines(markers)]
    os.makedirs(outdir, exist_ok=True)
    for i in range(0, len(keys), 1000):
        p = os.path.join(outdir, 'delete-%05d.json' % (i // 1000))
        with open(p, 'w', encoding='utf-8') as fh:
            json.dump({'Objects': [{'Key': k} for k in keys[i:i + 1000]], 'Quiet': True}, fh, ensure_ascii=False)
        print(p)


def cmd_stage_sel(src, sel, dest, how):
    """Selected keys of src under dest: hardlinks (staging for an upload) or real copies (--to-dir)."""
    import shutil
    n = 0
    for k in read_lines(sel):
        d = _safe_dest(dest, k)
        if how == 'link':
            try:
                os.link(os.path.join(src, k), d)
                n += 1
                continue
            except OSError:
                pass
        shutil.copy2(os.path.join(src, k), d)
        n += 1
    emit('X_COUNT', n)


def cmd_sel_minus(sel, listing, out):
    have_keys = {it.get('Path') for it in load_listing(listing) if not it.get('IsDir')}
    keep = [k for k in read_lines(sel) if k not in have_keys]
    write_lines(out, keep)
    emit('S_COUNT', len(keep))


def cmd_listing_bytes(listing):
    print(sum(int(it.get('Size') or 0) for it in load_listing(listing) if not it.get('IsDir')))


# ---------- main ----------
def with_cfg(path):
    cfg = load_cfg(path)
    if not isinstance(cfg, dict):
        die('config root must be a mapping')
    envf = cfg.get('env_file')
    if envf:
        for p in ([envf] if isinstance(envf, str) else envf):
            load_env_file(os.path.expanduser(expand(str(p))))
    return deep_expand(cfg)


def main():
    a = sys.argv[1:]
    if not a:
        die('no mode')
    mode = a[0]
    if mode == 'url':
        ep = build_endpoint(dict(parse_s3_url(a[1]), name='url', url=a[1]))
        for k in ('engine', 'provider', 'endpoint', 'region', 'access_key'):
            print('%-12s %s' % (k, ep[k] or '-'))
        print('%-12s %s' % ('secret_key', '****' if ep['secret_key'] else '-'))
        print('%-12s %s' % ('id', endpoint_id(ep)))
        for k, v in sorted(ep['options'].items()):
            print('%-12s %s=%s' % ('option', k, v))
        return
    cfg_modes = ('defaults', 'section', 'names', 'source', 'target', 'endpoint', 'url-endpoint',
                 'label-policy', 'discover', 'bucket-owner', 'engines')
    if mode in cfg_modes:
        cfg = with_cfg(a[1])
        if mode == 'defaults':
            for k, v in effective_defaults(cfg).items():
                emit(a[2] + k.upper(), v)
        elif mode == 'section':
            emit_section(cfg, a[2], a[3])
        elif mode == 'names':
            for e in entries(cfg, a[2]):
                if a[2] != 'sources' or as_bool(e.get('enabled', True), 'enabled'):
                    print(e['name'])
        elif mode == 'source':
            for k, v in build_source(cfg, find(cfg, 'sources', a[2]), effective_defaults(cfg)).items():
                emit(a[3] + k, v)
        elif mode == 'target':
            for k, v in build_target(cfg, find(cfg, 'targets', a[2])).items():
                emit(a[3] + k, v)
        elif mode == 'endpoint':
            emit_endpoint(build_endpoint(find(cfg, 'endpoints', a[2]), effective_defaults(cfg)['engine']), a[3], a[4])
        elif mode == 'url-endpoint':
            emit_endpoint(build_endpoint(dict(parse_s3_url(a[2]), name='url', url=a[2]),
                                         effective_defaults(cfg)['engine']), a[3], a[4])
        elif mode == 'engines':
            d = effective_defaults(cfg)['engine']
            names = set()
            for e in entries(cfg, 'endpoints'):
                names.add(str(e.get('engine') or (parse_s3_url(str(e['url'])).get('engine') if e.get('url') else '') or d).lower())
            print(' '.join(sorted(names or {d})))
        elif mode == 'label-policy':
            cmd_label_policy(cfg, a[2], a[3])
        elif mode == 'discover':
            cmd_discover(cfg, a[2], a[3])
        elif mode == 'bucket-owner':
            cmd_bucket_owner(cfg, a[2], a[3])
        return
    handlers = {
        'estimate': lambda: cmd_estimate(a[1], a[2]),
        'reconcile': lambda: cmd_reconcile(a[1], a[2], a[3], a[4], a[5], a[6], a[7]),
        'gate': lambda: cmd_gate(a[1], a[2], a[3]),
        'finalize': lambda: cmd_finalize(a[1], a[2], a[3], a[4], a[5]),
        'members': lambda: cmd_members(a[1], a[2]),
        'meta-set': lambda: cmd_meta_set(a[1], a[2:]),
        'meta-get': lambda: print((read_meta(a[1]) or {}).get(a[2], '')),
        'resolve': lambda: cmd_resolve(a[1], a[2]),
        'pick': lambda: cmd_pick(a[1], a[2], a[3] if len(a) > 3 else ''),
        'retention': lambda: cmd_retention(*a[1:9]),
        'freeable': lambda: cmd_freeable(a[1]),
        'verify-tree': lambda: cmd_verify_tree(a[1], a[2], a[3] == '1', a[4], a[5], a[6], a[7]),
        'verify-tar': lambda: cmd_verify_tar(a[1], a[2] == '1', a[3]),
        'verify-zip': lambda: cmd_verify_zip(a[1], a[2], a[3] == '1', a[4]),
        'verify-target': lambda: cmd_verify_target(a[1], a[2], a[3], a[4]),
        'select': lambda: cmd_select(a[1], a[2], a[3], a[4:]),
        'tar-extract': lambda: cmd_tar_extract(a[1], a[2]),
        'zip-pack': lambda: cmd_zip_pack(a[1], a[2], a[3], a[4]),
        'zip-extract': lambda: cmd_zip_extract(a[1], a[2], a[3]),
        'buckets': lambda: cmd_buckets(a[1], a[2]),
        'list': lambda: cmd_list(a[1], a[2] if len(a) > 2 else ''),
        'metrics': lambda: cmd_metrics(a[1]),
        'first-key': lambda: print(min(classify(load_listing(a[1]))[0], default='')),
        'aws-listing': lambda: cmd_aws_listing(a[1], a[2], a[3], a[4]),
        'aws-sync-args': lambda: cmd_aws_sync_args(a[1], a[2], a[3], a[4]),
        'aws-buckets': lambda: cmd_aws_buckets(a[1], a[2]),
        'aws-prefixes': lambda: cmd_aws_prefixes(a[1]),
        'aws-delete-batches': lambda: cmd_aws_delete_batches(a[1], a[2], a[3], a[4]),
        'stage-sel': lambda: cmd_stage_sel(a[1], a[2], a[3], a[4]),
        'sel-minus': lambda: cmd_sel_minus(a[1], a[2], a[3]),
        'listing-bytes': lambda: cmd_listing_bytes(a[1]),
        'count': lambda: print(len(load_listing(a[1]))),
    }
    if mode not in handlers:
        die('unknown helper mode %s' % mode)
    handlers[mode]()


if __name__ == '__main__':
    main()
PYEOF

# ===========================================================================
#  Globals
# ===========================================================================
CONFIG="${BUCKETOOL_CONFIG:-}"
DRY_RUN=false
ASSUME_YES=false
QUIET=false
VERBOSE=false
JSON_OUT=false
NO_OFFSITE=false
NO_PRUNE=false
RC_RETRIES=5                 # rclone --retries / aws max attempts (test lowers them to fail fast)
RC_LL_RETRIES=20
ALLOW_SHRINK=false
FORCE=false
WORST=0                      # 0 ok, 3 warnings, 1 failure — the exit status of a multi-source run

BOOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bucketool.XXXXXXXX")"
PY="$BOOT_DIR/bucketool.py"
RUNDIR=""                    # below backup_dir/.tmp once the config is loaded: docker can see it
CONTAINER=""                 # the rclone container currently running, killed on exit
RCLONE_MODE=""
RCLONE_BIN=""
RCLONE_VER=""
AWS_MODE=""
AWS_BIN=""
AWS_VER=""
CFG_LOG_FILE=""
declare -a DOCKER_MOUNTS=()
declare -A LOCK_FDS=()

kill_container() {
    if [[ -n $CONTAINER ]]; then docker kill "$CONTAINER" >/dev/null 2>&1 || true; CONTAINER=""; fi
}

cleanup() {
    kill_container
    rm -rf "$BOOT_DIR" 2>/dev/null || true
    [[ -n $RUNDIR && $RUNDIR == */.tmp/run.* ]] && rm -rf "$RUNDIR" 2>/dev/null
    return 0
}
trap cleanup EXIT
trap 'err "aborted (signal)"; exit 130' INT TERM

# A process environment can carry RCLONE_* settings (RCLONE_INPLACE, a config
# file with other remotes ...). None of them may leak into a backup run.
scrub_rclone_env() {
    local v
    for v in $(compgen -e); do [[ $v == RCLONE_* ]] && unset "$v"; done
    export RCLONE_CONFIG=/dev/null
}
scrub_rclone_env

# ===========================================================================
#  Logging
# ===========================================================================
if [[ -t 1 ]]; then C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
else C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''; fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_write_log() { [[ -n $CFG_LOG_FILE ]] && printf '[%s] %s\n' "$(_ts)" "$1" >>"$CFG_LOG_FILE" 2>/dev/null || true; }
log()  { $QUIET || printf '%s[%s]%s %s\n' "$C_B" "$(_ts)" "$C_0" "$*"; _write_log "$*"; }
ok()   { $QUIET || printf '%s[%s] OK%s %s\n' "$C_G" "$(_ts)" "$C_0" "$*"; _write_log "OK: $*"; }
warn() { printf '%s[%s] WARN%s %s\n' "$C_Y" "$(_ts)" "$C_0" "$*" >&2; _write_log "WARN: $*"; }
err()  { printf '%s[%s] ERROR%s %s\n' "$C_R" "$(_ts)" "$C_0" "$*" >&2; _write_log "ERROR: $*"; }
die()  { err "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
    $ASSUME_YES && return 0
    local reply
    printf '%s%s%s [y/N] ' "$C_Y" "$1" "$C_0" >&2
    read -r reply </dev/tty || return 1
    [[ $reply =~ ^[Yy]([Ee][Ss])?$ ]]
}

human() { local b=${1:-0}; awk -v b="$b" 'BEGIN{u="B KB MB GB TB";split(u,a," ");i=1;while(b>=1024&&i<5){b/=1024;i++}printf (i==1?"%d%s":"%.1f%s"),b,a[i]}'; }

to_bytes() {  # 500M / 20G / 1T / 1024 -> bytes, or -1
    local s="${1^^}" n u
    [[ $s =~ ^([0-9]+)([KMGT]?)I?B?$ ]] || { echo -1; return; }
    n=${BASH_REMATCH[1]}; u=${BASH_REMATCH[2]}
    case $u in K) n=$((n << 10)) ;; M) n=$((n << 20)) ;; G) n=$((n << 30)) ;; T) n=$((n << 40)) ;; esac
    echo "$n"
}

worst() {  # worst <status>: fold a per-source status into the run status
    local s=$1
    if (( s == 3 )); then (( WORST == 1 )) || WORST=3
    elif (( s != 0 )); then WORST=1; fi
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ===========================================================================
#  Config
# ===========================================================================
cfgpy() { python3 "$PY" "$@"; }

# eval the shell assignments a helper mode prints; a parse error stops the run
cfg_eval() {
    local out
    out="$(cfgpy "$@")" || exit 1
    eval "$out"
}

find_config() {
    [[ -n $CONFIG ]] && { [[ -f $CONFIG ]] || die "config not found: $CONFIG"; return; }
    local c
    for c in ./bucketool.yml ./bucketool.yaml ./bucketool.json \
             "$SCRIPT_DIR/bucketool.yml" "$SCRIPT_DIR/bucketool.yaml" "$SCRIPT_DIR/bucketool.json" \
             /etc/bucketool/bucketool.yml /etc/bucketool/bucketool.yaml /etc/bucketool/bucketool.json; do
        [[ -f $c ]] && { CONFIG="$c"; return; }
    done
    die "no config found. Pass -c <file> or create ./bucketool.yml (see bucketool.example.yml)"
}

load_config() {
    have python3 || die "python3 is required"
    find_config
    CONFIG="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"
    cfg_eval defaults "$CONFIG" CFG_
    cfg_eval section "$CONFIG" notify NOTIFY_
    cfg_eval section "$CONFIG" metrics METRICS_
    cfg_eval section "$CONFIG" offsite OFFSITE_
    cfg_eval section "$CONFIG" drill DRILL_
    [[ $CFG_BACKUP_DIR == /* ]] || die "defaults.backup_dir must be an absolute path"
    mkdir -p "$CFG_BACKUP_DIR" 2>/dev/null || die "cannot create backup_dir: $CFG_BACKUP_DIR"
    chmod 0700 "$CFG_BACKUP_DIR" 2>/dev/null || true
    RUNDIR="$CFG_BACKUP_DIR/.tmp/run.$$"
    mkdir -p "$RUNDIR" "$CFG_BACKUP_DIR/reports" || die "cannot write below $CFG_BACKUP_DIR"
    if [[ -n $CFG_LOG_FILE ]]; then
        mkdir -p "$(dirname "$CFG_LOG_FILE")" 2>/dev/null || true
        touch "$CFG_LOG_FILE" 2>/dev/null || { warn "cannot write $CFG_LOG_FILE — logging to the console only"; CFG_LOG_FILE=""; }
    fi
    if [[ $CFG_MIN_FREE_SPACE != *% ]] && (( $(to_bytes "$CFG_MIN_FREE_SPACE") < 0 )); then
        die "defaults.min_free_space: '$CFG_MIN_FREE_SPACE' is neither a size (20G) nor a percentage (10%)"
    fi
}

# ===========================================================================
#  Locks — fatal when they cannot be had (never run unlocked)
#    global shared   : backup, verify, restore, drill
#    global exclusive: prune
#    label-<x> excl. : one backup of a label at a time
# ===========================================================================
lock() {  # lock <name> <shared|exclusive> [try]
    have flock || die "flock (util-linux) is required"
    local name="$1" mode=-x fd
    [[ $2 == shared ]] && mode=-s
    mkdir -p "$CFG_BACKUP_DIR/.locks"
    if [[ -n ${LOCK_FDS[$name]:-} ]]; then fd=${LOCK_FDS[$name]}
    else exec {fd}>>"$CFG_BACKUP_DIR/.locks/$name.lock" || die "cannot open lock $name"; LOCK_FDS[$name]=$fd; fi
    flock -n "$mode" "$fd" && return 0
    [[ ${3:-} == try ]] && return 1
    log "waiting up to ${CFG_LOCK_WAIT}s for lock '$name' (another bucketool run holds it)"
    flock -w "$CFG_LOCK_WAIT" "$mode" "$fd" && return 0
    die "lock '$name' is still held by another bucketool run after ${CFG_LOCK_WAIT}s"
}

# ===========================================================================
#  rclone — native binary if new enough, otherwise a pinned container
# ===========================================================================
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

resolve_rclone() {
    [[ -n $RCLONE_MODE ]] && return 0
    local c v
    if [[ $CFG_RCLONE != docker ]]; then
        for c in "${BUCKETOOL_RCLONE:-}" "$SCRIPT_DIR/bin/rclone" /opt/bucketool/bin/rclone "$(command -v rclone 2>/dev/null || true)"; do
            [[ -n $c && -x $c ]] || continue
            v="$("$c" version 2>/dev/null | sed -n '1s/^rclone v\([0-9.]*\).*/\1/p')"
            if [[ -n $v ]] && version_ge "$v" "$RCLONE_MIN"; then
                RCLONE_MODE=native; RCLONE_BIN="$c"; RCLONE_VER="$v"; return 0
            fi
            [[ -n $v ]] && warn "ignoring $c: rclone v$v is older than v$RCLONE_MIN"
        done
        [[ $CFG_RCLONE == native ]] && die "no rclone >= v$RCLONE_MIN found (install it, run install.sh --with-rclone, or set rclone: docker)"
    fi
    have docker && docker info >/dev/null 2>&1 \
        || die "no usable rclone: install rclone >= v$RCLONE_MIN (install.sh --with-rclone) or make docker available"
    if ! docker image inspect "$CFG_RCLONE_IMAGE" >/dev/null 2>&1; then
        log "pulling $CFG_RCLONE_IMAGE"
        docker pull -q "$CFG_RCLONE_IMAGE" >/dev/null || die "cannot pull $CFG_RCLONE_IMAGE"
    fi
    RCLONE_MODE=docker
    RCLONE_VER="$(docker run --rm "$CFG_RCLONE_IMAGE" version 2>/dev/null | sed -n '1s/^rclone v\([0-9.]*\).*/\1/p')"
}

rclone_exec() {  # rclone with no extra flags; stdout passes through, stdin only for rcat
    # Anything else gets /dev/null: rclone (and docker -i) would otherwise eat the
    # stdin of a surrounding `while read` loop.
    if [[ ${1:-} != rcat ]]; then rclone_exec_in "$@" </dev/null; else rclone_exec_in "$@"; fi
}

rclone_exec_in() {
    [[ -n $RCLONE_MODE ]] || resolve_rclone
    if [[ $RCLONE_MODE == native ]]; then
        timeout --foreground --kill-after=60 "$CFG_TIMEOUT" "$RCLONE_BIN" "$@"
    else
        container_run "$CFG_RCLONE_IMAGE" RCLONE_ "$@"
    fi
}

# rclone with the run's transfer settings; stderr is kept for error summaries
rclone_run() {
    local -a f=(--retries "$RC_RETRIES" --low-level-retries "$RC_LL_RETRIES" --contimeout 15s --transfers "${X_TRANSFERS:-$CFG_TRANSFERS}"
                --checkers "${X_CHECKERS:-$CFG_CHECKERS}" --stats 0)
    local bw="${X_BWLIMIT:-$CFG_BWLIMIT}"
    [[ -n $bw ]] && f+=(--bwlimit "$bw")
    if $VERBOSE; then f+=(-v); else f+=(-q); fi
    f+=(${CFG_RCLONE_FLAGS[@]+"${CFG_RCLONE_FLAGS[@]}"})
    : >"$RUNDIR/rclone.err"
    if $VERBOSE; then rclone_exec "$@" "${f[@]}" 2> >(tee "$RUNDIR/rclone.err" >&2)
    else rclone_exec "$@" "${f[@]}" 2>"$RUNDIR/rclone.err"; fi
}

rclone_err() { grep -v '^[[:space:]]*$' "$RUNDIR/rclone.err" 2>/dev/null | tail -3 | tr '\n' ' ' || true; }

use_endpoint() {  # use_endpoint <endpoint-name> <REMOTE> <PFX>
    local v r="RCLONE_CONFIG_${2^^}_"
    for v in $(compgen -e); do [[ $v == "$r"* ]] && unset "$v"; done
    cfg_eval endpoint "$CONFIG" "$1" "$2" "$3"
}

# ===========================================================================
#  Containers (rclone and aws-cli images): backup_dir is bind-mounted at the
#  same path, so every file handed over lives below it.
# ===========================================================================
container_run() {  # container_run <image> <env-prefix> args...
    local image="$1" envp="$2"; shift 2
    local -a envs=() mounts=() m v
    for v in $(compgen -e); do [[ $v == "$envp"* ]] && envs+=(-e "$v"); done
    mounts=(--mount "type=bind,src=$CFG_BACKUP_DIR,dst=$CFG_BACKUP_DIR")
    for m in ${DOCKER_MOUNTS[@]+"${DOCKER_MOUNTS[@]}"}; do mounts+=(--mount "type=bind,src=$m,dst=$m"); done
    CONTAINER="bucketool-$$-$RANDOM"
    local rc=0
    timeout --foreground --kill-after=60 "$CFG_TIMEOUT" docker run --rm -i --init --pull never --name "$CONTAINER" \
        --network host --user "$(id -u):$(id -g)" -e HOME=/tmp ${envs[@]+"${envs[@]}"} "${mounts[@]}" \
        -w "$CFG_BACKUP_DIR" "$image" "$@" || rc=$?
    if (( rc == 0 )); then CONTAINER=""; else kill_container; fi   # a timeout kills the client, not the container
    return $rc
}

# ===========================================================================
#  aws-cli engine (endpoint or defaults `engine: aws`)
# ===========================================================================
resolve_aws() {
    [[ -n $AWS_MODE ]] && return 0
    local v
    if [[ $CFG_RCLONE != docker ]] && have aws; then
        v="$(aws --version 2>/dev/null | sed -n 's#^aws-cli/\([0-9.]*\).*#\1#p')"
        if [[ -n $v ]] && version_ge "$v" 2.0.0; then AWS_MODE=native; AWS_BIN="$(command -v aws)"; AWS_VER="$v"; return 0; fi
        [[ -n $v ]] && warn "ignoring aws-cli v$v: v2 is required"
    fi
    have docker && docker info >/dev/null 2>&1 || die "engine aws needs aws-cli v2 or docker"
    if ! docker image inspect "$CFG_AWS_IMAGE" >/dev/null 2>&1; then
        log "pulling $CFG_AWS_IMAGE"
        docker pull -q "$CFG_AWS_IMAGE" >/dev/null || die "cannot pull $CFG_AWS_IMAGE"
    fi
    AWS_MODE=docker
    AWS_VER="$(docker run --rm "$CFG_AWS_IMAGE" --version 2>/dev/null | sed -n 's#^aws-cli/\([0-9.]*\).*#\1#p')"
}

aws_bw() {  # rclone-style bwlimit -> aws max_bandwidth ('' if not expressible)
    local b="${1^^}"
    [[ -z $b ]] && return 0
    if [[ $b =~ ^([0-9]+)([KMG]?)$ ]]; then printf '%s%sB/s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else warn "bwlimit '$1' (timetable) is not supported by the aws engine — running unlimited"; fi
}

aws_exec() {  # aws_exec <role> [--stdin] args...   credentials exported only inside a subshell
    local role="$1"; shift
    local stdin=false
    [[ ${1:-} == --stdin ]] && { stdin=true; shift; }
    resolve_aws
    local p cfgf ps bw ep_url
    p="$(role_pfx "$role")"; cfgf="$RUNDIR/aws-$role.cfg"; ps="$(gv "${p}PATH_STYLE")"
    bw="$(aws_bw "${X_BWLIMIT:-$CFG_BWLIMIT}")"; ep_url="$(gv "${p}EPURL")"
    {
        echo '[default]'
        echo 's3 ='
        echo "    max_concurrent_requests = ${X_TRANSFERS:-$CFG_TRANSFERS}"
        if [[ $ps == true || ( -z $ps && $(gv "${p}PROVIDER") != AWS ) ]]; then echo '    addressing_style = path'; fi
        [[ -n $bw ]] && echo "    max_bandwidth = $bw"
    } >"$cfgf"
    local -a ep=(--cli-connect-timeout 15)
    [[ -n $ep_url ]] && ep+=(--endpoint-url "$ep_url")
    (
        trap kill_container EXIT
        local v
        if [[ $(gv "${p}ENV_AUTH") != true ]]; then
            for v in $(compgen -e); do [[ $v == AWS_* ]] && unset "$v"; done
            AWS_ACCESS_KEY_ID="$(gv "${p}AK")"; AWS_SECRET_ACCESS_KEY="$(gv "${p}SK")"
            export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SHARED_CREDENTIALS_FILE=/dev/null
            if [[ -n $(gv "${p}TOKEN") ]]; then AWS_SESSION_TOKEN="$(gv "${p}TOKEN")"; export AWS_SESSION_TOKEN; fi
        fi
        AWS_DEFAULT_REGION="$(gv "${p}REGION")"
        export AWS_CONFIG_FILE="$cfgf" AWS_PAGER="" AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
        # aws-cli >= 2.23 sends CRC checksums by default, which many S3-compatible servers reject
        export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
        export AWS_MAX_ATTEMPTS="$RC_RETRIES" AWS_RETRY_MODE=standard
        if [[ $AWS_MODE == native ]]; then
            if $stdin; then timeout --foreground --kill-after=60 "$CFG_TIMEOUT" "$AWS_BIN" ${ep[@]+"${ep[@]}"} "$@"
            else timeout --foreground --kill-after=60 "$CFG_TIMEOUT" "$AWS_BIN" ${ep[@]+"${ep[@]}"} "$@" </dev/null; fi
        else
            if $stdin; then container_run "$CFG_AWS_IMAGE" AWS_ ${ep[@]+"${ep[@]}"} "$@"
            else container_run "$CFG_AWS_IMAGE" AWS_ ${ep[@]+"${ep[@]}"} "$@" </dev/null; fi
        fi
    )
}

aws_run() {  # aws_run <role> args...   stderr kept for error summaries
    : >"$RUNDIR/rclone.err"
    if $VERBOSE; then aws_exec "$@" 2> >(tee "$RUNDIR/rclone.err" >&2)
    else aws_exec "$@" 2>"$RUNDIR/rclone.err"; fi
}

aws_s3() {  # aws_s3 <role> <s3-subcommand> args...
    local role="$1" sub="$2"; shift 2
    local -a q=()
    case "$sub" in
        cp|sync|mv) q=(--only-show-errors --no-progress) ;;
        rm)         q=(--only-show-errors) ;;
    esac
    aws_run "$role" s3 "$sub" "$@" ${q[@]+"${q[@]}"}
}

# ===========================================================================
#  S3 operations — one function per operation, rclone or aws-cli per endpoint.
#  A location is <role> <bucket> <prefix>; roles: SRC, DST (targets), OFF.
# ===========================================================================
gv() { eval "printf '%s' \"\${$1-}\""; }
role_pfx() { case "$1" in SRC) echo SEP_ ;; DST) echo DEP_ ;; OFF) echo OEP_ ;; *) die "bad role $1" ;; esac; }
eng() { local e; e="$(gv "$(role_pfx "$1")ENGINE")"; printf '%s' "${e:-rclone}"; }
rpath() { printf '%s:%s%s' "$1" "$2" "${3:+/$3}"; }
s3url() { printf 's3://%s/%s' "$1" "${2:+$2/}"; }
joinp() { local a="${1%/}" b="${2#/}"; printf '%s' "${a:+$a${b:+/}}$b"; }

aws_spec() {  # the source's filters as JSON for the aws engine
    local mx=""
    [[ -n ${SRC_MAX_SIZE:-} ]] && mx="$(to_bytes "$SRC_MAX_SIZE")"
    python3 -c 'import json,sys
a=sys.argv[1:]; i=a.index("--"); j=a.index("--", i + 1)
print(json.dumps({"max_size": int(a[0]) if a[0] not in ("", "-1") else None, "include": a[1:i], "exclude": a[i+1:j]}))' \
        "$mx" ${SRC_INCLUDE[@]+"${SRC_INCLUDE[@]}"} -- ${SRC_EXCLUDE[@]+"${SRC_EXCLUDE[@]}"} --
}

s3_list() {  # s3_list <role> <bucket> <prefix> <out> [filtered] -> lsjson-shaped file, keys relative to prefix
    local role="$1" b="$2" pre="$3" out="$4" filtered="${5:-}"
    if [[ $(eng "$role") == aws ]]; then
        local -a pa=()
        [[ -n $pre ]] && pa=(--prefix "$pre/")
        aws_run "$role" s3api list-objects-v2 --bucket "$b" ${pa[@]+"${pa[@]}"} --output json >"$out.raw" || return 1
        local spec='{}'
        [[ -n $filtered ]] && spec="$(aws_spec)"
        cfgpy aws-listing "$out.raw" "$out" "$pre" "$spec"
    else
        local -a f=()
        [[ -n $filtered ]] && f=(${FILT[@]+"${FILT[@]}"})
        rclone_run lsjson -R --fast-list --use-server-modtime --no-mimetype ${f[@]+"${f[@]}"} "$(rpath "$role" "$b" "$pre")" >"$out"
    fi
}

s3_download() {  # s3_download <role> <bucket> <prefix> <data-dir> <keys-file> <state-dir>
    local role="$1" b="$2" pre="$3" data="$4" keys="$5" sd="$6"
    if [[ $(eng "$role") == aws ]]; then
        # everything already on disk is current (reconcile unlinked the rest), so a
        # sync downloads exactly the missing objects; s3transfer writes temp files
        # and renames them, which never touches a hardlinked inode
        cfgpy aws-sync-args "$sd" "$(aws_spec)" "$sd/listing.json.toobig" "$sd/aws.args" || return 1
        local -a xa=()
        mapfile -d '' -t xa <"$sd/aws.args"
        aws_s3 "$role" sync "$(s3url "$b" "$pre")" "$data" ${xa[@]+"${xa[@]}"}
    else
        rclone_run copy --files-from-raw "$keys" --no-check-dest --fast-list --use-server-modtime \
            "$(rpath "$role" "$b" "$pre")" "$data"
    fi
}

s3_buckets() {  # s3_buckets <role> <out>  -> lsjson-shaped list of buckets
    if [[ $(eng "$1") == aws ]]; then
        aws_run "$1" s3api list-buckets --output json >"$2.raw" && cfgpy aws-buckets "$2.raw" "$2"
    else
        rclone_run lsjson --dirs-only "$1:" >"$2"
    fi
}

s3_bucket_exists() {  # s3_bucket_exists <role> <bucket>
    if [[ $(eng "$1") == aws ]]; then aws_run "$1" s3api head-bucket --bucket "$2" >/dev/null 2>&1
    else rclone_run lsf --max-depth 1 "$1:$2" >/dev/null 2>&1; fi
}

s3_peek() {  # s3_peek <role> <bucket> <prefix>: can we list it at all?
    if [[ $(eng "$1") == aws ]]; then
        local -a pa=()
        [[ -n $3 ]] && pa=(--prefix "$3/")
        aws_run "$1" s3api list-objects-v2 --bucket "$2" ${pa[@]+"${pa[@]}"} --max-items 1 >/dev/null
    else rclone_run lsf --max-depth 1 "$(rpath "$1" "$2" "$3")" >/dev/null; fi
}

s3_is_empty() {  # s3_is_empty <role> <bucket> <prefix>  (0 = provably empty; any error counts as not empty)
    if ! s3_bucket_exists "$1" "$2"; then
        # missing bucket is empty; an unreachable server is not
        s3_buckets "$1" "$RUNDIR/empty-check.json" || return 1
        python3 -c 'import json,sys; sys.exit(1 if any(i.get("Path")==sys.argv[2] for i in json.load(open(sys.argv[1]))) else 0)' \
            "$RUNDIR/empty-check.json" "$2"
        return
    fi
    if [[ $(eng "$1") == aws ]]; then
        local -a pa=()
        [[ -n $3 ]] && pa=(--prefix "$3/")
        [[ "$(aws_run "$1" s3api list-objects-v2 --bucket "$2" ${pa[@]+"${pa[@]}"} --max-items 1 \
              --query 'Contents[0].Key' --output text 2>/dev/null)" == None ]]
    else
        local out
        out="$(rclone_run lsf -R --files-only "$(rpath "$1" "$2" "$3")")" || return 1
        [[ -z $out ]]
    fi
}

s3_mkbucket() {  # s3_mkbucket <role> <bucket>
    if [[ $(eng "$1") == aws ]]; then aws_s3 "$1" mb "s3://$2"
    else rclone_run mkdir "$1:$2"; fi
}

s3_upload() {  # s3_upload <role> <src-dir> <sel> <bucket> <prefix> <merge|skip-existing|mirror> <scope>
    local role="$1" src="$2" sel="$3" b="$4" pre="$5" mode="$6" scope="$7"
    if [[ $(eng "$role") == aws ]]; then
        local stage="$RUNDIR/upload" use="$sel"
        rm -rf "$stage"; mkdir -p "$stage"
        if [[ $mode == skip-existing ]]; then
            s3_list "$role" "$b" "$pre" "$RUNDIR/upload-existing.json" || return 1
            cfg_eval sel-minus "$sel" "$RUNDIR/upload-existing.json" "$RUNDIR/upload.sel"
            use="$RUNDIR/upload.sel"
        fi
        cfg_eval stage-sel "$src" "$use" "$stage" link
        case "$mode" in
            mirror) aws_s3 "$role" sync "$(joinp "$stage" "$scope")" "$(s3url "$b" "$(joinp "$pre" "$scope")")" --delete ;;
            *)      (( X_COUNT == 0 )) || aws_s3 "$role" cp --recursive "$stage" "$(s3url "$b" "$pre")" ;;
        esac
    else
        local dest; dest="$(rpath "$role" "$b" "$pre")"
        case "$mode" in
            mirror) rclone_run sync "$(joinp "$src" "$scope")" "$(joinp "$dest" "$scope")" --s3-no-check-bucket ;;
            skip-existing) rclone_run copy --ignore-existing --files-from-raw "$sel" --s3-no-check-bucket "$src" "$dest" ;;
            *) rclone_run copy --files-from-raw "$sel" --s3-no-check-bucket "$src" "$dest" ;;
        esac
    fi
}

s3_marker() {  # s3_marker <role> <bucket> <prefix> <marker/>
    if [[ $(eng "$1") == aws ]]; then aws_run "$1" s3api put-object --bucket "$2" --key "$(joinp "$3" "$4")" >/dev/null
    else rclone_run mkdir --s3-directory-markers "$(rpath "$1" "$2" "$3")/${4%/}"; fi
}

s3_delete_sel() {  # s3_delete_sel <role> <bucket> <prefix> <sel> <markers-file>
    local role="$1" b="$2" pre="$3" sel="$4" markers="$5" f
    if [[ $(eng "$role") == aws ]]; then
        local rc=0
        while IFS= read -r f; do
            aws_run "$role" s3api delete-objects --bucket "$b" --delete "file://$f" >/dev/null || rc=1
        done < <(cfgpy aws-delete-batches "$sel" "$markers" "$pre" "$RUNDIR/delete")
        return $rc
    fi
    if [[ -s $sel ]]; then rclone_run delete --files-from-raw "$sel" "$(rpath "$role" "$b" "$pre")" || return 1; fi
    rclone_run rmdirs --s3-directory-markers --leave-root "$(rpath "$role" "$b" "$pre")" 2>/dev/null || true
}

s3_check_full() {  # s3_check_full <role> <bucket> <prefix> <local-dir> <sel> <backup-dir>: byte-level check
    local role="$1" b="$2" pre="$3" local_dir="$4" sel="$5" bk="$6"
    if [[ $(eng "$role") == aws ]]; then
        local tmp="$RUNDIR/check"
        rm -rf "$tmp"; mkdir -p "$tmp"
        disk_guard "$CFG_BACKUP_DIR" "$(cfgpy listing-bytes "$RUNDIR/target.json")" 0 "downloading the target for a full check" || return 1
        aws_s3 "$role" sync "$(s3url "$b" "$pre")" "$tmp" || return 1
        cfgpy verify-tree "$bk" "$tmp" 1 "$CFG_HASH_WORKERS" "" "$sel" ""
        local rc=$?
        rm -rf "$tmp"
        return $rc
    fi
    rclone_run check --download --one-way --files-from-raw "$sel" "$local_dir" "$(rpath "$role" "$b" "$pre")"
}

s3_read_one() {  # s3_read_one <role> <bucket> <prefix> <key>
    if [[ $(eng "$1") == aws ]]; then
        aws_run "$1" s3api head-object --bucket "$2" --key "$(joinp "$3" "$4")" >/dev/null
    else rclone_run cat --count 1 "$(rpath "$1" "$2" "$3")/$4" >/dev/null; fi
}

s3_write_probe() {  # s3_write_probe <role> <bucket> <prefix>
    local key; key="$(joinp "$3" ".bucketool-probe-$$")"
    if [[ $(eng "$1") == aws ]]; then
        echo probe | aws_run "$1" --stdin s3 cp - "s3://$2/$key" --only-show-errors && aws_s3 "$1" rm "s3://$2/$key"
    else
        echo probe | rclone_run rcat "$1:$2/$key" && rclone_run deletefile "$1:$2/$key"
    fi
}

s3_versioning() {  # s3_versioning <role> <bucket> -> Enabled | Suspended | ...
    if [[ $(eng "$1") == aws ]]; then aws_run "$1" s3api get-bucket-versioning --bucket "$2" --query Status --output text 2>/dev/null
    else rclone_run backend versioning "$1:$2" 2>/dev/null; fi
}

s3_put_dir() {  # s3_put_dir <role> <local-dir> <bucket> <prefix> [exclude-data]
    if [[ $(eng "$1") == aws ]]; then
        local -a x=()
        [[ -n ${5:-} ]] && x=(--exclude 'data/*')
        aws_s3 "$1" cp --recursive "$2" "$(s3url "$3" "$4")" ${x[@]+"${x[@]}"}
    else
        local -a x=()
        [[ -n ${5:-} ]] && x=(--filter "- data/**")
        rclone_run copy "$2" "$(rpath "$1" "$3" "$4")" ${x[@]+"${x[@]}"}
    fi
}

s3_subdirs() {  # s3_subdirs <role> <bucket> <prefix>  -> immediate "folder" names
    if [[ $(eng "$1") == aws ]]; then
        aws_run "$1" s3api list-objects-v2 --bucket "$2" --prefix "$3/" --delimiter / --output json >"$RUNDIR/dirs.raw" \
            && cfgpy aws-prefixes "$RUNDIR/dirs.raw"
    else
        rclone_run lsf --dirs-only "$(rpath "$1" "$2" "$3")" 2>/dev/null | sed 's#/$##'
    fi
}

s3_purge() {  # s3_purge <role> <bucket> <prefix>
    if [[ $(eng "$1") == aws ]]; then aws_s3 "$1" rm --recursive "$(s3url "$2" "$3")"
    else rclone_run purge "$(rpath "$1" "$2" "$3")"; fi
}

engine_version() {  # engine_version <role>
    if [[ $(eng "$1") == aws ]]; then resolve_aws; printf 'aws-cli %s' "$AWS_VER"
    else resolve_rclone; printf 'rclone %s' "$RCLONE_VER"; fi
}

# pre-resolve the engines the config uses, so subshells do not each probe them
resolve_engines() {
    local e
    for e in $(cfgpy engines "$CONFIG"); do
        case "$e" in rclone) resolve_rclone ;; aws) resolve_aws ;; esac
    done
}

# ===========================================================================
#  Disk, notifications, metrics
# ===========================================================================
disk_guard() {  # disk_guard <dir> <need-bytes> <need-inodes> <what>
    local dir="$1" need="$2" inodes="${3:-0}" what="$4" size avail margin ia
    read -r size avail < <(df -B1 --output=size,avail "$dir" | tail -1)
    if [[ $CFG_MIN_FREE_SPACE == *% ]]; then margin=$(( size / 100 * ${CFG_MIN_FREE_SPACE%\%} ))
    else margin=$(to_bytes "$CFG_MIN_FREE_SPACE"); fi
    if (( avail - need < margin )); then
        err "$what needs $(human "$need") and must leave $(human "$margin") free (min_free_space), but only $(human "$avail") is available on $dir"
        return 1
    fi
    ia="$(df --output=iavail "$dir" | tail -1 | tr -d ' ')"
    if [[ $ia =~ ^[0-9]+$ ]] && (( ia > 0 && inodes > ia )); then
        err "$what needs about $inodes inodes, only $ia are free on $dir"
        return 1
    fi
}

json_str() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"; }

notify() {  # notify <status> <summary>
    local status="$1" summary="$2" word=ok
    (( status == 1 )) && word=failed
    (( status == 3 )) && word=warning
    have curl || return 0
    if [[ -n $NOTIFY_HEALTHCHECK_URL ]]; then
        local u="$NOTIFY_HEALTHCHECK_URL"
        (( status == 1 )) && u="${u%/}/fail"
        printf 'url = "%s"\n' "$u" | curl -K - -fsS -m 15 --retry 3 -o /dev/null --data-raw "$summary" 2>/dev/null \
            || warn "healthcheck ping failed"
    fi
    if [[ -n $NOTIFY_WEBHOOK ]] && { (( status != 0 )) || [[ $NOTIFY_ON_SUCCESS == true ]]; }; then
        curl -fsS -m 15 --retry 2 -o /dev/null -X POST -H 'Content-Type: application/json' \
            -d "{\"tool\":\"bucketool\",\"host\":$(json_str "$(hostname)"),\"status\":\"$word\",\"summary\":$(json_str "$summary")}" \
            -K <(printf 'url = "%s"\n' "$NOTIFY_WEBHOOK") 2>/dev/null || warn "webhook notification failed"
    fi
    return 0
}

hc_start() {
    [[ -n $NOTIFY_HEALTHCHECK_URL ]] && have curl && ! $DRY_RUN || return 0
    printf 'url = "%s"\n' "${NOTIFY_HEALTHCHECK_URL%/}/start" | curl -K - -fsS -m 10 --retry 2 -o /dev/null 2>/dev/null || true
}

write_metrics() {
    [[ -n $METRICS_TEXTFILE_DIR ]] && ! $DRY_RUN || return 0
    local prom="$METRICS_TEXTFILE_DIR/bucketool.prom"
    { cfgpy metrics "$CFG_BACKUP_DIR" >"$prom.$$" && mv -f "$prom.$$" "$prom"; } 2>/dev/null \
        || warn "cannot write metrics to $METRICS_TEXTFILE_DIR"
}

# ===========================================================================
#  Compression / archives
# ===========================================================================
zstd_level() { local l=${1:-6}; (( l < 1 )) && l=1; (( l > 19 )) && l=19; echo "$l"; }
gzip_level() { local l=${1:-6}; (( l < 1 )) && l=1; (( l > 9 )) && l=9; echo "$l"; }

decomp_cmd() {  # archive name -> decompressor reading stdin
    case "${1%.age}" in
        *.tar.zst) zstd -dcq --long=27 ;;
        *.tar.gz)  if have pigz; then pigz -dc; else gzip -dc; fi ;;
        *) die "not a tar archive: $1" ;;
    esac
}

check_identity() {
    [[ -n $CFG_AGE_IDENTITY_FILE ]] || die "this archive is encrypted: set defaults.age_identity_file to restore or fully verify it"
    [[ -r $CFG_AGE_IDENTITY_FILE ]] || die "cannot read age identity file $CFG_AGE_IDENTITY_FILE"
    local perm; perm="$(stat -c %a "$CFG_AGE_IDENTITY_FILE")"
    [[ $perm =~ [0-7]00$ ]] || die "age identity file $CFG_AGE_IDENTITY_FILE is readable by others (mode $perm) — chmod 600 it"
    have age || die "age is not installed"
}

archive_stream() {  # archive_stream <archive> -> uncompressed tar on stdout
    local a="$1"
    if [[ $a == *.age ]]; then
        check_identity
        age -d -i "$CFG_AGE_IDENTITY_FILE" "$a" | decomp_cmd "$a"
    else
        decomp_cmd "$a" <"$a"
    fi
}

find_archive() {  # find_archive <backup-dir> -> path of its archive (if any)
    local f
    for f in "$1"/*.tar.zst "$1"/*.tar.gz "$1"/*.tar.zst.age "$1"/*.tar.gz.age "$1"/*.zip; do
        [[ -f $f ]] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

pack_archive() {  # pack_archive <data-dir> <part-dir> <label>   (SRC_* loaded)
    local data="$1" part="$2" label="$3" fmt="$SRC_FORMAT" out members
    members="$RUNDIR/$label/members"
    if [[ $fmt == zip ]]; then
        out="$part/$label.zip"
        cfgpy zip-pack "$data" "$part/manifest.jsonl.gz" "$out.tmp" "$(gzip_level "$SRC_COMPRESSION_LEVEL")" || return 1
        mv "$out.tmp" "$out"; return 0
    fi
    cfgpy members "$part/manifest.jsonl.gz" "$members" || return 1
    local -a comp age_args=()
    case "$fmt" in
        tar.zst) have zstd || die "zstd is not installed (format tar.zst)"
                 out="$part/$label.tar.zst"
                 comp=(zstd -q -T0 "-$(zstd_level "$SRC_COMPRESSION_LEVEL")" -c)
                 [[ $SRC_ZSTD_LONG == true ]] && comp+=(--long=27) ;;
        tar.gz)  out="$part/$label.tar.gz"
                 if have pigz; then comp=(pigz "-$(gzip_level "$SRC_COMPRESSION_LEVEL")" -c)
                 else comp=(gzip "-$(gzip_level "$SRC_COMPRESSION_LEVEL")" -c); fi ;;
    esac
    if [[ $SRC_ENCRYPT == age ]]; then
        have age || die "age is not installed (encrypt: age)"
        local r
        for r in ${SRC_AGE_RECIPIENTS[@]+"${SRC_AGE_RECIPIENTS[@]}"}; do age_args+=(-r "$r"); done
        [[ -n $SRC_AGE_RECIPIENTS_FILE ]] && age_args+=(-R "$SRC_AGE_RECIPIENTS_FILE")
        out+=".age"
        tar -C "$data" --format=pax --owner=0 --group=0 --numeric-owner \
            --null --verbatim-files-from -T "$members" -cf - | "${comp[@]}" | age "${age_args[@]}" >"$out.tmp" || return 1
    else
        tar -C "$data" --format=pax --owner=0 --group=0 --numeric-owner \
            --null --verbatim-files-from -T "$members" -cf - | "${comp[@]}" >"$out.tmp" || return 1
    fi
    mv "$out.tmp" "$out"
}

# ===========================================================================
#  Verify a backup directory
# ===========================================================================
verify_backup() {  # verify_backup <backup-dir> <none|quick|full> [report-file] -> 0 ok / 1 problems
    local b="$1" level="$2" rep="${3:-}" fmt archive rc=0 full=0
    if [[ $level == none ]]; then cfgpy meta-set "$b/meta.json" verify=none; return 0; fi
    [[ $level == full ]] && full=1
    fmt="$(cfgpy meta-get "$b" format)"
    if ! (cd "$b" && sha256sum --quiet --strict -c SHA256SUMS); then
        err "$(basename "$b"): SHA256SUMS check failed"; rc=1
    fi
    case "$fmt" in
        snapshot)
            cfgpy verify-tree "$b" "$b/data" "$full" "$CFG_HASH_WORKERS" "$(dirname "$b")" "" "$rep" || rc=1 ;;
        zip)
            archive="$(find_archive "$b")" || { err "no archive in $b"; return 1; }
            cfgpy verify-zip "$archive" "$b/manifest.jsonl.gz" "$full" "$rep" || rc=1 ;;
        tar.*)
            archive="$(find_archive "$b")" || { err "no archive in $b"; return 1; }
            if (( full )) || [[ $archive != *.age ]]; then
                if [[ $archive == *.age && -z $CFG_AGE_IDENTITY_FILE ]]; then
                    err "full verify of an encrypted archive needs defaults.age_identity_file"; rc=1
                elif (( full )); then
                    archive_stream "$archive" | cfgpy verify-tar "$b/manifest.jsonl.gz" 1 "$rep" || rc=1
                else
                    # quick: the compressor's own checksums catch truncation and bit rot
                    case "$archive" in
                        *.zst) zstd -tq --long=27 "$archive" || { err "zstd integrity test failed: $archive"; rc=1; } ;;
                        *.gz)  gzip -t "$archive" || { err "gzip integrity test failed: $archive"; rc=1; } ;;
                    esac
                fi
            fi ;;
        *) err "$b: unknown format '$fmt'"; rc=1 ;;
    esac
    local res="${level}-ok"
    (( rc == 0 )) || res=failed
    cfgpy meta-set "$b/meta.json" "verify=$res" "verified_at=$(now_utc)"
    return $rc
}

# ===========================================================================
#  BACKUP
# ===========================================================================
src_path() { printf '%s/%s%s' "$SEP_URL" "$1" "${SRC_PREFIX:+/$SRC_PREFIX}"; }   # for messages

filter_flags() {  # rclone filter flags from the source's include/exclude
    FILT=()
    local p
    for p in ${SRC_EXCLUDE[@]+"${SRC_EXCLUDE[@]}"}; do FILT+=(--filter "- $p"); done
    for p in ${SRC_INCLUDE[@]+"${SRC_INCLUDE[@]}"}; do FILT+=(--filter "+ $p"); done
    (( ${#SRC_INCLUDE[@]} )) && FILT+=(--filter "- **")
    [[ -n $SRC_MAX_SIZE ]] && FILT+=(--max-size "$SRC_MAX_SIZE")
    return 0
}

prepare_snapshot_part() {  # sets PART; reuses an interrupted run when that is safe
    local ldir="$1" prev="$2" ts="$3" p newest="" pts
    for p in "$ldir"/*.part; do [[ -d $p ]] && newest="$p"; done
    for p in "$ldir"/*.part; do [[ -d $p && $p != "$newest" ]] && rm -rf "$p"; done
    PART="$ldir/$ts.part"
    if [[ -n $newest ]]; then
        pts="$(basename "$newest" .part)"
        if [[ -n $prev && $pts < $(basename "$prev") ]] || [[ -n $(find "$newest" -maxdepth 0 -mtime +"$CFG_PART_MAX_AGE_DAYS") ]]; then
            log "discarding stale interrupted run $pts"; rm -rf "$newest"
        else
            log "resuming interrupted run $pts"; mv "$newest" "$PART"
        fi
    fi
    mkdir -p "$PART"
    if [[ ! -d $PART/data ]]; then
        if [[ -n $prev && -d $prev/data ]]; then
            log "linking unchanged objects from $(basename "$prev")"
            cp -al "$prev/data" "$PART/data.tmp" || die "cp -al failed (backups must stay on one filesystem)"
            mv "$PART/data.tmp" "$PART/data"
        else
            mkdir -p "$PART/data"
        fi
    fi
}

backup_label() {  # backup_label <source-name> <bucket> <label>   (SRC_* loaded; run in a subshell)
    local name="$1" bucket="$2" label="$3" t0=$SECONDS
    local ldir="$CFG_BACKUP_DIR/$label" work="$RUNDIR/$label" ts prev prevman="" prevdata="" data mode
    local srcpath; srcpath="$(src_path "$bucket")"
    local engine; engine="$(eng SRC)"
    X_TRANSFERS="$SRC_TRANSFERS"; X_CHECKERS="$SRC_CHECKERS"; X_BWLIMIT="$SRC_BWLIMIT"
    lock "label-$label" exclusive
    mkdir -p "$ldir" "$work"
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    while [[ -e $ldir/$ts ]]; do sleep 1; ts="$(date -u +%Y%m%dT%H%M%SZ)"; done
    local started; started="$(now_utc)"

    # 1. list once — no per-object HEAD requests
    filter_flags
    log "$label: listing $srcpath ($engine)"
    s3_list SRC "$bucket" "$SRC_PREFIX" "$work/listing.json" filtered \
        || die "$label: listing $srcpath failed: $(rclone_err)"

    # 2. what changed since the last good backup
    prev="$(cfgpy pick "$ldir" good)"
    [[ -n $prev ]] && prevman="$prev/manifest.jsonl.gz"
    cfg_eval estimate "$work/listing.json" "$prevman"
    log "$label: $E_FILES objects ($(human "$E_BYTES")) — new $E_NEW, changed $E_CHANGED, deleted $E_DELETED, unchanged $E_UNCHANGED"
    (( E_SKIPPED > 0 )) && warn "$label: $E_SKIPPED object(s) cannot be stored as files and will be skipped (see skipped.jsonl)"
    # A short or empty listing must not become the newest backup (and empty the off-site copy).
    if [[ -n $prev ]] && ! $ALLOW_SHRINK; then
        local prev_n; prev_n="$(cfgpy meta-get "$prev" objects)"; prev_n="${prev_n:-0}"
        if (( prev_n > 0 && E_FILES == 0 )); then
            die "$label: the listing is empty but $(basename "$prev") holds $prev_n objects — refusing (pass --allow-shrink if the bucket really was emptied)"
        fi
        if (( prev_n > 0 && E_DELETED * 100 > prev_n * CFG_MAX_DELETE_PERCENT )); then
            die "$label: $E_DELETED of $prev_n objects disappeared since $(basename "$prev") (> max_delete_percent ${CFG_MAX_DELETE_PERCENT}%) — refusing (pass --allow-shrink if that is expected)"
        fi
    fi
    if $DRY_RUN; then
        ok "$label: dry run — would download $E_DL_COUNT object(s), $(human "$E_DL_BYTES"), format $SRC_FORMAT"
        return 0
    fi

    # 3. room on disk
    local need=$(( E_DL_BYTES + E_LARGEST )) inodes=$(( E_DL_COUNT + E_DIRS ))
    [[ $SRC_FORMAT != snapshot ]] && need=$(( need + E_BYTES ))
    disk_guard "$ldir" "$need" "$inodes" "$label" || exit 1

    # 4. working tree: hardlinked copy of the previous snapshot, or the archive staging mirror
    if [[ $SRC_FORMAT == snapshot ]]; then
        prepare_snapshot_part "$ldir" "$prev" "$ts"
        data="$PART/data"; mode=snapshot
        [[ -n $prev ]] && prevdata="$prev/data"
    else
        rm -rf "$ldir"/*.part
        PART="$ldir/$ts.part"; mkdir -p "$PART"
        data="$CFG_BACKUP_DIR/.cache/$label/data"; mkdir -p "$data"; mode=cache
    fi
    cfg_eval reconcile "$mode" "$work/listing.json" "$prevman" "$prevdata" "$data" "$work" "$ldir/.redownload"

    # 5. download exactly what is missing (unlinked first, so older snapshots are never written)
    if (( R_DL_COUNT > 0 )); then
        log "$label: downloading $R_DL_COUNT object(s), $(human "$R_DL_BYTES")"
        s3_download SRC "$bucket" "$SRC_PREFIX" "$data" "$work/delta.txt" "$work" \
            || warn "$label: some transfers failed ($(rclone_err)) — checking what arrived"
    fi

    # 6. completeness gate: exactly the expected (key, size) set
    cfg_eval gate "$work" "$data" ""
    if (( G_MISMATCH > 0 )); then
        log "$label: $G_MISMATCH object(s) incomplete — retrying"
        s3_download SRC "$bucket" "$SRC_PREFIX" "$data" "$work/mismatch.txt" "$work" || true
        cfg_eval gate "$work" "$data" ""
    fi
    if (( G_MISMATCH > 0 )); then
        s3_list SRC "$bucket" "$SRC_PREFIX" "$work/relist.json" filtered \
            || die "$label: cannot re-list incomplete objects: $(rclone_err)"
        cfg_eval gate "$work" "$data" "$work/relist.json"
        (( G_DROPPED > 0 )) && warn "$label: $G_DROPPED object(s) changed or vanished on the source during the backup (see skipped.jsonl)"
        (( G_FAILED > 0 )) && die "$label: $G_FAILED object(s) could not be downloaded ($(head -3 "$work/failed.txt" | tr '\n' ' ')) — run kept and resumed next time"
    fi

    # 7. hashes + manifest
    cfg_eval finalize "$work" "$data" "$PART" "$CFG_HASH_WORKERS" "$mode"
    local archive_bytes=0 archive=""
    if [[ $mode == cache ]]; then
        log "$label: packing $SRC_FORMAT${SRC_ENCRYPT/none/} archive"
        pack_archive "$data" "$PART" "$label" || die "$label: packing the archive failed"
        archive="$(find_archive "$PART")"
        archive_bytes="$(stat -c %s "$archive")"
    fi
    (
        cd "$PART"
        local -a f=(manifest.jsonl.gz)
        [[ -f skipped.jsonl ]] && f+=(skipped.jsonl)
        [[ -n $archive ]] && f+=("$(basename "$archive")")
        sha256sum -- "${f[@]}" >SHA256SUMS
    )

    # 8. commit: durable before the rename, meta.json last
    sync -f "$PART" 2>/dev/null || sync
    mv "$PART" "$ldir/$ts"
    local b="$ldir/$ts"
    cfgpy meta-set "$b/meta.json" "tool=bucketool" "version=$BUCKETOOL_VERSION" "label=$label" "source=$name" \
        "endpoint=$SEP_URL" "endpoint_id=$SEP_ID" "bucket=$bucket" "prefix=$SRC_PREFIX" "format=$SRC_FORMAT" \
        "encrypted=$([[ $SRC_ENCRYPT == age ]] && echo true || echo false)" "created=$ts" "started=$started" \
        "finished=$(now_utc)" "finished_epoch=$(date +%s)" "duration_s=$(( SECONDS - t0 ))" \
        "objects=$F_OBJECTS" "bytes=$F_BYTES" "markers=$F_MARKERS" "new=$F_NEW" "changed=$F_CHANGED" \
        "deleted=$F_DELETED" "unchanged=$F_UNCHANGED" "skipped=$F_SKIPPED" "unique_bytes=$F_UNIQUE" \
        "archive_bytes=$archive_bytes" "engine=$(engine_version SRC)" "verify=pending" "offsite="
    sync -f "$b" 2>/dev/null || true
    rm -f "$ldir/.redownload"
    [[ $mode == cache && $SRC_CACHE == drop ]] && rm -rf "$CFG_BACKUP_DIR/.cache/$label"

    # 9. verify what was written
    if ! verify_backup "$b" "$SRC_VERIFY" "$CFG_BACKUP_DIR/reports/verify_${label}_$ts.txt"; then
        err "$label: verification of $ts FAILED"; exit 1
    fi

    # 10. off-site copy
    local st=0
    if [[ $OFFSITE_ENABLED == true ]] && ! $NO_OFFSITE; then
        offsite_push "$label" "$b" "$prev" || { warn "$label: off-site copy failed: $(rclone_err)"; st=3; }
    fi
    (( F_SKIPPED > 0 || F_WARNINGS > 0 )) && st=3
    local extra=""
    [[ $mode == snapshot ]] && extra=", $(human "$F_UNIQUE") new on disk"
    [[ $mode == cache ]] && extra=", archive $(human "$archive_bytes")"
    ok "$label: backup $ts — $F_OBJECTS objects, $(human "$F_BYTES")$extra, $(( SECONDS - t0 ))s"
    exit $st
}

backup_source() {  # backup_source <source-name>   (one subshell per label)
    local name="$1" st b
    cfg_eval source "$CONFIG" "$name" SRC_
    use_endpoint "$SRC_ENDPOINT" SRC SEP_
    local -a buckets=()
    if [[ $SRC_ALL_BUCKETS == true ]]; then
        s3_buckets SRC "$RUNDIR/buckets.json" \
            || { err "$name: cannot list buckets: $(rclone_err)"; printf '%s\t1\n' "$name" >>"$RUNDIR/results.tsv"; return 0; }
        mapfile -t buckets < <(cfgpy buckets "$RUNDIR/buckets.json" \
            "$(python3 -c 'import json,sys;print(json.dumps({"include":sys.argv[1:sys.argv.index("--")],"exclude":sys.argv[sys.argv.index("--")+1:]}))' \
               ${SRC_INCLUDE_BUCKETS[@]+"${SRC_INCLUDE_BUCKETS[@]}"} -- ${SRC_EXCLUDE_BUCKETS[@]+"${SRC_EXCLUDE_BUCKETS[@]}"})")
        (( ${#buckets[@]} )) || { warn "$name: no buckets matched"; printf '%s\t3\n' "$name" >>"$RUNDIR/results.tsv"; return 0; }
    else
        buckets=("$SRC_BUCKET")
    fi
    for b in "${buckets[@]}"; do
        local label="$name"
        [[ $SRC_ALL_BUCKETS == true ]] && label="${name}_$b"
        set +e
        ( trap kill_container EXIT; set -e; backup_label "$name" "$b" "$label" )
        st=$?
        set -e
        (( st == 0 || st == 3 )) || err "$label: backup FAILED"
        printf '%s\t%s\n' "$label" "$st" >>"$RUNDIR/results.tsv"
    done
}

cmd_backup() {
    local sel="${1:-all}" n
    local -a names=()
    if [[ $sel == all ]]; then mapfile -t names < <(cfgpy names "$CONFIG" sources)
    else IFS=',' read -r -a names <<<"$sel"; fi
    (( ${#names[@]} )) || die "no enabled sources in $CONFIG"
    lock global shared
    resolve_engines
    hc_start
    : >"$RUNDIR/results.tsv"
    for n in "${names[@]}"; do
        set +e
        ( set -e; backup_source "$n" )
        local st=$?
        set -e
        if (( st != 0 )) && ! awk -F"\t" -v n="$n" '$1 == n || index($1, n "_") == 1 {f=1} END {exit !f}' "$RUNDIR/results.tsv"; then
            err "$n: source could not be set up"
            printf '%s\t1\n' "$n" >>"$RUNDIR/results.tsv"
        fi
    done
    # the run status is the worst per-label status (subshells cannot set WORST)
    local lst
    while IFS=$'\t' read -r _ lst; do worst "$lst"; done <"$RUNDIR/results.tsv"
    if ! $DRY_RUN && ! $NO_PRUNE; then
        if lock global exclusive try; then
            set +e; ( set -e; prune_all ); local pst=$?; set -e
            (( pst == 0 )) || { warn "prune failed"; worst 3; }
        else warn "prune skipped: another bucketool run is active"; fi
    fi
    write_metrics
    local summary
    summary="$(awk -F'\t' '{s=($2==0?"ok":($2==3?"warning":"FAILED")); printf "%s%s=%s", (NR>1?", ":""), $1, s}' "$RUNDIR/results.tsv")"
    $JSON_OUT && python3 -c 'import json,sys
rows=[l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
print(json.dumps({"status":int(sys.argv[2]),"results":[{"label":a,"status":int(b)} for a,b in rows]}))' "$RUNDIR/results.tsv" "$WORST"
    $DRY_RUN || notify "$WORST" "backup: ${summary:-nothing to do}"
    return "$WORST"
}

# ===========================================================================
#  OFFSITE
# ===========================================================================
offsite_base() { printf '%s%s' "${OFFSITE_PREFIX:+$OFFSITE_PREFIX/}" "$1"; }   # key prefix inside OFFSITE_BUCKET

offsite_push() {  # offsite_push <label> <backup-dir> <previous-backup-dir>
    local label="$1" b="$2" prev="$3" ts fmt base state last=""
    use_endpoint "$OFFSITE_ENDPOINT" OFF OEP_
    ts="$(basename "$b")"; fmt="$(cfgpy meta-get "$b" format)"; base="$(offsite_base "$label")"
    state="$CFG_BACKUP_DIR/$label/.offsite"
    [[ -f $state ]] && last="$(<"$state")"
    if ! s3_bucket_exists OFF "$OFFSITE_BUCKET"; then
        s3_mkbucket OFF "$OFFSITE_BUCKET" || return 1
        log "created off-site bucket $OFFSITE_BUCKET"
    fi
    if [[ $fmt == snapshot ]]; then
        local work="$RUNDIR/$label" cur
        cur="$(rpath OFF "$OFFSITE_BUCKET" "$base/current")"
        if [[ $(eng OFF) == aws ]]; then
            log "$label: off-site: syncing current/ (aws)"
            aws_s3 OFF sync "$b/data" "$(s3url "$OFFSITE_BUCKET" "$base/current")" --delete || return 1
        elif [[ -n $prev && $last == "$(basename "$prev")" && -f $work/changed.txt ]]; then
            log "$label: off-site: $(wc -l <"$work/changed.txt") changed, $(wc -l <"$work/deleted.txt") deleted"
            if [[ -s $work/changed.txt ]]; then
                rclone_run copy --files-from-raw "$work/changed.txt" --no-check-dest "$b/data" "$cur" || return 1
            fi
            if [[ -s $work/deleted.txt ]]; then
                rclone_run delete --files-from-raw "$work/deleted.txt" "$cur" || return 1
            fi
        else
            log "$label: off-site: full sync of current/ (first run, or off-site out of step)"
            rclone_run sync "$b/data" "$cur" || return 1
        fi
        s3_put_dir OFF "$b" "$OFFSITE_BUCKET" "$base/manifests/$ts" exclude-data || return 1
        printf '%s\n' "$ts" >"$state"
    else
        s3_put_dir OFF "$b" "$OFFSITE_BUCKET" "$base/$ts" || return 1
    fi
    cfgpy meta-set "$b/meta.json" "offsite=$(now_utc)"
    ok "$label: off-site copy done"
}

offsite_prune() {  # offsite_prune <label>   (archives and manifests older than offsite.retention_days)
    local label="$1" base d cutoff
    (( OFFSITE_RETENTION_DAYS > 0 )) || return 0
    use_endpoint "$OFFSITE_ENDPOINT" OFF OEP_
    base="$(offsite_base "$label")"
    cutoff="$(date -u -d "-${OFFSITE_RETENTION_DAYS} days" +%Y%m%dT%H%M%SZ)"
    local sub
    for sub in "" "manifests/"; do
        local -a dirs=()
        mapfile -t dirs < <(s3_subdirs OFF "$OFFSITE_BUCKET" "$base${sub:+/${sub%/}}" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort)
        local n=${#dirs[@]} i
        for (( i = 0; i < n - 1; i++ )); do       # never the newest
            d="${dirs[$i]}"
            [[ $d < $cutoff ]] || continue
            if $DRY_RUN; then log "would delete off-site $OFFSITE_BUCKET/$base/$sub$d"; continue; fi
            if s3_purge OFF "$OFFSITE_BUCKET" "$base/$sub$d"; then log "$label: off-site: removed $sub$d"
            else warn "$label: off-site: cannot remove $sub$d"; fi
        done
    done
}

# ===========================================================================
#  PRUNE
# ===========================================================================
prune_all() {
    local lab ldir ts why freed total=0 removed=0 now="${BUCKETOOL_NOW:-$(date +%s)}"
    local -a labs=()
    mapfile -t labs < <(find "$CFG_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name reports -printf '%f\n' | sort)
    for lab in ${labs[@]+"${labs[@]}"}; do
        ldir="$CFG_BACKUP_DIR/$lab"
        cfg_eval label-policy "$CONFIG" "$lab" P_
        if [[ $P_KNOWN != true ]]; then
            warn "$lab: no source in the config owns these backups — retention skipped (delete $ldir by hand when done)"
            continue
        fi
        while IFS=$'\t' read -r ts why; do
            [[ -n $ts ]] || continue
            if [[ $OFFSITE_ENABLED == true && -z $(cfgpy meta-get "$ldir/$ts" offsite) ]]; then
                warn "$lab: pruning $ts, which was never copied off-site"
            fi
            if $DRY_RUN; then log "would prune $lab/$ts ($why)"; continue; fi
            freed="$(cfgpy freeable "$ldir/$ts")"
            rm -rf "${ldir:?}/$ts"
            total=$(( total + freed )); removed=$(( removed + 1 ))
            log "pruned $lab/$ts ($why) — freed $(human "$freed")"
        done < <(cfgpy retention "$ldir" "$P_RETENTION_DAYS" "$P_RETENTION_MIN_KEEP" "$P_KEEP_DAILY" \
                     "$P_KEEP_WEEKLY" "$P_KEEP_MONTHLY" "$P_KEEP_YEARLY" "$now")
        # interrupted runs nobody will resume
        local p
        for p in "$ldir"/*.part; do
            [[ -d $p && -n $(find "$p" -maxdepth 0 -mtime +"$CFG_PART_MAX_AGE_DAYS") ]] || continue
            if $DRY_RUN; then log "would remove stale $(basename "$p")"; else rm -rf "$p"; log "removed stale $lab/$(basename "$p")"; fi
        done
        if [[ $OFFSITE_ENABLED == true ]] && ! $NO_OFFSITE; then
            offsite_prune "$lab" || warn "$lab: off-site prune failed"
        fi
    done
    # leftovers of killed runs; safe because the exclusive lock is held
    for p in "$CFG_BACKUP_DIR"/.tmp/run.*; do
        [[ -d $p && $p != "$RUNDIR" ]] && rm -rf "$p"
    done
    (( removed > 0 )) && ok "pruned $removed backup(s), freed $(human "$total")"
    return 0
}

cmd_prune() {
    lock global exclusive
    prune_all
    write_metrics
}

# ===========================================================================
#  VERIFY
# ===========================================================================
resolve_labels() {  # NAME|all -> labels on disk
    if [[ $1 == all ]]; then
        find "$CFG_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name reports -printf '%f\n' | sort
    else
        cfgpy resolve "$CFG_BACKUP_DIR" "$1"
    fi
}

cmd_verify() {
    local latest="" level=quick target="" path="" rc=0 lab b
    while (( $# )); do
        case "$1" in
            --latest) latest="$2"; shift 2 ;;
            --full)   level=full; shift ;;
            --quick)  level=quick; shift ;;
            --target|-t) target="$2"; shift 2 ;;
            -f)       path="$2"; shift 2 ;;
            -*)       die "verify: unknown option $1" ;;
            *)        path="$1"; shift ;;
        esac
    done
    lock global shared
    local -a dirs=()
    if [[ -n $path ]]; then
        [[ -f $path/meta.json ]] || die "$path is not an bucketool backup (no meta.json)"
        dirs=("$(cd "$path" && pwd)")
    else
        [[ -n $latest ]] || die "verify: give --latest NAME|all or a backup directory"
        local -a labs=()
        mapfile -t labs < <(resolve_labels "$latest")
        (( ${#labs[@]} )) || die "no backups found for '$latest'"
        for lab in "${labs[@]}"; do
            b="$(cfgpy pick "$CFG_BACKUP_DIR/$lab" any)"
            if [[ -n $b ]]; then dirs+=("$b"); else err "$lab: no completed backup"; rc=1; fi
        done
    fi
    for b in ${dirs[@]+"${dirs[@]}"}; do
        local lab; lab="$(basename "$(dirname "$b")")"
        lock "label-$lab" exclusive
        local rep; rep="$CFG_BACKUP_DIR/reports/verify_${lab}_$(basename "$b")_$(date -u +%Y%m%dT%H%M%SZ).txt"
        log "verifying $lab/$(basename "$b") ($level)"
        if verify_backup "$b" "$level" "$rep"; then ok "$lab/$(basename "$b"): $level verification passed"
        else err "$lab/$(basename "$b"): verification FAILED (report: $rep)"; rc=1; fi
        if [[ -n $target ]]; then
            local sel="$RUNDIR/sel.txt"
            cfg_eval select "$b/manifest.jsonl.gz" "" "$sel"
            verify_target "$b" "$target" "$sel" "$level" "$b/data" || rc=1
        fi
    done
    write_metrics
    return $rc
}

# ===========================================================================
#  RESTORE / DRILL
# ===========================================================================
target_root() { printf '%s/%s%s' "$DEP_URL" "$TGT_BUCKET" "${TGT_PREFIX:+/$TGT_PREFIX}"; }   # for messages

load_target() {  # load_target <name> -> TGT_*, DST remote, DEP_*
    cfg_eval target "$CONFIG" "$1" TGT_
    use_endpoint "$TGT_ENDPOINT" DST DEP_
}

verify_target() {  # verify_target <backup-dir> <target> <sel-file> <quick|full> <local-copy-dir>
    local b="$1" sel="$3" level="$4" local_dir="$5" rep
    load_target "$2"
    rep="$CFG_BACKUP_DIR/reports/target_${2}_$(date -u +%Y%m%dT%H%M%SZ).txt"
    s3_list DST "$TGT_BUCKET" "$TGT_PREFIX" "$RUNDIR/target.json" \
        || { err "cannot list target $2: $(rclone_err)"; return 1; }
    cfgpy verify-target "$sel" "$b/manifest.jsonl.gz" "$RUNDIR/target.json" "$rep" || return 1
    if [[ $level == full ]]; then
        [[ -d $local_dir || $(eng DST) == aws ]] || { err "full target check needs the backup's files on disk"; return 1; }
        log "comparing every restored object byte for byte"
        s3_check_full DST "$TGT_BUCKET" "$TGT_PREFIX" "$local_dir" "$sel" "$b" \
            || { err "target $2 differs from the backup: $(rclone_err)"; return 1; }
        ok "target $2: every restored object matches byte for byte"
    fi
}

is_source_bucket() {  # endpoint-id bucket -> name of a source that reads it (status 1 if none)
    local out rc=0
    out="$(cfgpy bucket-owner "$CONFIG" "$1" "$2")" || rc=$?
    case $rc in
        0) printf '%s' "$out"; return 0 ;;
        3) return 1 ;;
        *) die "cannot decide whether bucket '$2' is backed up by a source — refusing to write to it" ;;
    esac
}

pick_backup() {  # pick_backup <latest-name> <at> <file> -> R_BACKUP
    local latest="$1" at="$2" file="$3"
    if [[ -n $file ]]; then
        [[ -f $file/meta.json ]] || die "$file is not an bucketool backup (no meta.json)"
        R_BACKUP="$(cd "$file" && pwd)"; return
    fi
    [[ -n $latest ]] || die "give --latest NAME (optionally with --at DATE) or -f BACKUP_DIR"
    local -a labs=()
    mapfile -t labs < <(resolve_labels "$latest")
    (( ${#labs[@]} == 1 )) || die "'$latest' matches ${#labs[@]} label(s): ${labs[*]:-none} — name one label"
    if [[ -n $at ]]; then R_BACKUP="$(cfgpy pick "$CFG_BACKUP_DIR/${labs[0]}" at "$at")"
    else R_BACKUP="$(cfgpy pick "$CFG_BACKUP_DIR/${labs[0]}" good)"; fi
    [[ -n $R_BACKUP ]] || die "no good backup of ${labs[0]}${at:+ at or before $at}"
}

# restore_core: R_BACKUP + options -> objects in a target bucket or a directory.
# Sets R_SEL (selected keys) and R_SRCDIR (local copy of the selection).
restore_core() {
    local target="$1" todir="$2" prefix="$3" mode="$4" create="$5" vlevel="$6" force_src="$7"; shift 7
    local -a globs=("$@")
    local b="$R_BACKUP" fmt label
    fmt="$(cfgpy meta-get "$b" format)"; label="$(basename "$(dirname "$b")")"
    R_SEL="$RUNDIR/restore.sel"
    cfg_eval select "$b/manifest.jsonl.gz" "$prefix" "$R_SEL" ${globs[@]+"${globs[@]}"}
    (( S_COUNT + S_MARKERS > 0 )) || die "nothing in $label/$(basename "$b") matches the selection"
    log "restoring $label/$(basename "$b") ($fmt): $S_COUNT object(s), $(human "$S_BYTES")${prefix:+, prefix $prefix}"
    local vstate; vstate="$(cfgpy meta-get "$b" verify)"
    if [[ $vstate == failed || $vstate == pending ]] && ! $FORCE; then
        die "$label/$(basename "$b") is marked verify=$vstate — pick another backup, or pass --force"
    fi

    local dest=""
    if [[ -n $target ]]; then
        load_target "$target"
        dest="$(target_root)"
        local owner
        if owner="$(is_source_bucket "$DEP_ID" "$TGT_BUCKET")"; then
            [[ $force_src == true ]] \
                || die "target $target writes into bucket '$TGT_BUCKET' that source '$owner' backs up — pass --force-source if that is really intended"
            # back into a source bucket: put the objects back under the prefix they came from
            local mpre; mpre="$(cfgpy meta-get "$b" prefix)"
            if [[ -z $TGT_PREFIX && -n $mpre ]]; then TGT_PREFIX="$mpre"; dest="$(target_root)"; fi
        fi
        if $DRY_RUN; then
            ok "dry run: would $mode-restore $S_COUNT object(s) ($(human "$S_BYTES")) into $DEP_URL $dest"
            return 0
        fi
        if ! s3_bucket_exists DST "$TGT_BUCKET"; then
            if [[ $create == true || $TGT_CREATE == true ]]; then
                s3_mkbucket DST "$TGT_BUCKET" || die "cannot create bucket $TGT_BUCKET: $(rclone_err)"
                log "created bucket $TGT_BUCKET"
            else
                die "bucket $TGT_BUCKET does not exist on $DEP_URL (use --create or create: true)"
            fi
        fi
        if [[ $mode == mirror ]]; then
            (( ${#globs[@]} == 0 )) || die "--mode mirror cannot be combined with --include"
            confirm "mirror mode DELETES every object under $dest${prefix:+/$prefix} that is not in the backup. Continue?" \
                || die "aborted"
        fi
    else
        if $DRY_RUN; then ok "dry run: would restore $S_COUNT object(s) ($(human "$S_BYTES")) into $todir"; return 0; fi
        mkdir -p "$todir"; todir="$(cd "$todir" && pwd)"
        [[ -z $(find "$todir" -mindepth 1 -maxdepth 1 -print -quit) ]] || die "$todir is not empty"
    fi

    # the selection as plain files
    if [[ $fmt == snapshot ]]; then
        R_SRCDIR="$b/data"
    else
        if [[ -n $todir ]]; then R_SRCDIR="$todir"
        else
            R_SRCDIR="$RUNDIR/restore/data"; mkdir -p "$R_SRCDIR"
            disk_guard "$CFG_BACKUP_DIR" "$S_BYTES" "$S_COUNT" "extracting the archive" || exit 1
        fi
        local archive; archive="$(find_archive "$b")" || die "no archive in $b"
        log "extracting from $(basename "$archive")"
        if [[ $fmt == zip ]]; then cfg_eval zip-extract "$archive" "$R_SRCDIR" "$R_SEL"
        else
            local out; out="$(archive_stream "$archive" | cfgpy tar-extract "$R_SRCDIR" "$R_SEL")" || die "extracting $archive failed"
            eval "$out"
        fi
        (( X_COUNT == S_COUNT )) || die "archive gave $X_COUNT object(s), expected $S_COUNT"
    fi

    if [[ $fmt == snapshot ]]; then
        # the files must be intact before anything is written (mirror deletes on the target)
        cfgpy verify-tree "$b" "$R_SRCDIR" 0 "$CFG_HASH_WORKERS" "" "$R_SEL" "" >/dev/null \
            || die "$label/$(basename "$b"): files on disk do not match the manifest — run: bucketool verify $b"
    fi
    : >"$RUNDIR/restore.started"
    if [[ -n $todir ]]; then
        if [[ $fmt == snapshot ]]; then
            cfg_eval stage-sel "$R_SRCDIR" "$R_SEL" "$todir" copy   # real copies: the backup must stay untouched
        fi
        cfgpy verify-tree "$b" "$todir" "$([[ $vlevel == full ]] && echo 1 || echo 0)" "$CFG_HASH_WORKERS" "" "$R_SEL" "" \
            || die "restored files do not match the backup"
        ok "restored $S_COUNT object(s) into $todir"
        return 0
    fi

    s3_upload DST "$R_SRCDIR" "$R_SEL" "$TGT_BUCKET" "$TGT_PREFIX" "$mode" "$prefix" \
        || die "restore failed: $(rclone_err)"
    local m
    while IFS= read -r m; do
        [[ -n $m ]] && { s3_marker DST "$TGT_BUCKET" "$TGT_PREFIX" "$m" || warn "cannot recreate folder marker $m"; }
    done <"$R_SEL.markers"
    ok "restored $S_COUNT object(s) into $DEP_URL $dest"
    [[ $vlevel == none ]] && return 0
    verify_target "$b" "$target" "$R_SEL" "$vlevel" "$R_SRCDIR" || die "restored objects do not match the backup"
    ok "target $target verified ($vlevel)"
}

cmd_restore() {
    local latest="" at="" file="" target="" todir="" prefix="" mode=merge create=false vlevel="" force=false
    local -a globs=()
    while (( $# )); do
        case "$1" in
            --latest)  latest="$2"; shift 2 ;;
            --at)      at="$2"; shift 2 ;;
            -f|--from) file="$2"; shift 2 ;;
            -t|--target) target="$2"; shift 2 ;;
            --to-dir)  todir="$2"; shift 2 ;;
            --prefix)  prefix="$2"; shift 2 ;;
            --include) globs+=("$2"); shift 2 ;;
            --mode)    mode="$2"; shift 2 ;;
            --create)  create=true; shift ;;
            --verify)  vlevel="$2"; shift 2 ;;
            --force-source) force=true; shift ;;
            *) die "restore: unknown option $1" ;;
        esac
    done
    [[ -n $target || -n $todir ]] || die "restore: give -t TARGET or --to-dir DIR"
    [[ -n $target && -n $todir ]] && die "restore: -t and --to-dir are exclusive"
    [[ $mode =~ ^(merge|mirror|skip-existing)$ ]] || die "restore: --mode must be merge, mirror or skip-existing"
    [[ -n $at && -z $latest ]] && die "restore: --at needs --latest NAME"
    lock global shared
    resolve_engines
    pick_backup "$latest" "$at" "$file"
    if [[ -z $vlevel ]]; then
        vlevel=quick
        if [[ -n $target ]]; then cfg_eval target "$CONFIG" "$target" TGT_; [[ -n $TGT_VERIFY ]] && vlevel="$TGT_VERIFY"; fi
    fi
    [[ $vlevel =~ ^(none|quick|full)$ ]] || die "restore: --verify must be none, quick or full"
    local t0=$SECONDS
    restore_core "$target" "$todir" "$prefix" "$mode" "$create" "$vlevel" "$force" ${globs[@]+"${globs[@]}"}
    $DRY_RUN || log "restore took $(( SECONDS - t0 ))s"
}

cmd_drill() {
    local name="" target="" rc=0
    while (( $# )); do
        case "$1" in
            -t|--target) target="$2"; shift 2 ;;
            -*) die "drill: unknown option $1" ;;
            *) name="$1"; shift ;;
        esac
    done
    [[ -n $target ]] || target="$DRILL_TARGET"
    if [[ -z $target && -z $name ]]; then
        log "drill: no drill.target configured — nothing to do"; return 0
    fi
    [[ -n $target ]] || die "drill: give -t SCRATCH_TARGET (or drill.target in the config)"
    local -a names=()
    if [[ -n $name ]]; then names=("$name")
    else names=(${DRILL_SOURCES[@]+"${DRILL_SOURCES[@]}"}); fi
    (( ${#names[@]} )) || die "drill: name a source (or set drill.sources)"
    lock global shared
    resolve_engines
    load_target "$target"
    [[ $TGT_SCRATCH == true ]] || die "drill target '$target' must be marked scratch: true — a drill deletes what it restores"
    if $DRY_RUN; then ok "dry run: would restore ${names[*]} into $target, verify fully, and clean up"; return 0; fi
    local n
    for n in "${names[@]}"; do
        local -a labs=()
        mapfile -t labs < <(resolve_labels "$n")
        (( ${#labs[@]} )) || { err "drill: no backups for $n"; rc=1; continue; }
        local lab
        for lab in "${labs[@]}"; do
            load_target "$target"
            if ! s3_is_empty DST "$TGT_BUCKET" "$TGT_PREFIX"; then
                err "drill: scratch target $target ($(target_root)) is not empty — refusing"; rc=1; continue
            fi
            R_BACKUP="$(cfgpy pick "$CFG_BACKUP_DIR/$lab" good)"
            [[ -n $R_BACKUP ]] || { err "drill: no good backup of $lab"; rc=1; continue; }
            local created t0=$SECONDS now drc=0 rep
            created="$(cfgpy meta-get "$R_BACKUP" finished_epoch)"
            rep="$CFG_BACKUP_DIR/reports/drill_${lab}_$(date -u +%Y%m%dT%H%M%SZ).txt"
            log "drill: $lab/$(basename "$R_BACKUP") -> $target"
            rm -f "$RUNDIR/restore.started"
            set +e
            ( set -e; trap kill_container EXIT; restore_core "$target" "" "" merge false full false )
            drc=$?
            set -e
            local rto=$(( SECONDS - t0 )); now=$(date +%s)
            # clean the scratch bucket: only the keys this drill wrote, only if it wrote any
            if [[ -f $RUNDIR/restore.started ]]; then
                cfg_eval select "$R_BACKUP/manifest.jsonl.gz" "" "$RUNDIR/drill.sel"
                load_target "$target"
                s3_delete_sel DST "$TGT_BUCKET" "$TGT_PREFIX" "$RUNDIR/drill.sel" "$RUNDIR/drill.sel.markers" \
                    || warn "drill: cleanup of $target failed: $(rclone_err)"
            fi
            {
                echo "bucketool drill report"
                echo "label:   $lab"
                echo "backup:  $(basename "$R_BACKUP")"
                echo "target:  $target ($DEP_URL $(target_root))"
                echo "objects: $(cfgpy meta-get "$R_BACKUP" objects)  bytes: $(cfgpy meta-get "$R_BACKUP" bytes)"
                echo "RPO:     $(( (now - ${created:-$now}) / 60 )) min (age of the backup)"
                echo "RTO:     ${rto}s (restore + full verification)"
                echo "result:  $([[ $drc == 0 ]] && echo PASS || echo FAIL)"
            } | tee "$rep"
            (( drc == 0 )) && ok "drill $lab passed (RTO ${rto}s)" || { err "drill $lab FAILED"; rc=1; }
        done
    done
    notify "$rc" "drill: $([[ $rc == 0 ]] && echo passed || echo FAILED) (${names[*]})"
    return $rc
}

# ===========================================================================
#  TEST / DISCOVER / LIST
# ===========================================================================
cmd_test() {
    local deep=false rc=0 n
    [[ ${1:-} == --deep ]] && deep=true
    # a preflight must answer in seconds, not retry for an hour
    RC_RETRIES=1; RC_LL_RETRIES=2
    resolve_engines
    [[ -n $RCLONE_MODE ]] && ok "rclone v$RCLONE_VER ($RCLONE_MODE${RCLONE_BIN:+: $RCLONE_BIN})"
    [[ -n $AWS_MODE ]] && ok "aws-cli v$AWS_VER ($AWS_MODE${AWS_BIN:+: $AWS_BIN})"
    local fstype; fstype="$(stat -f -c %T "$CFG_BACKUP_DIR")"
    case "$fstype" in nfs*|cifs|smb*|fuse*) warn "backup_dir is on $fstype: locks and hardlinks may be unreliable" ;; esac
    local probe="$CFG_BACKUP_DIR/.tmp/probe.$$"
    if echo x >"$probe" && ln "$probe" "$probe.l" 2>/dev/null; then ok "backup_dir $CFG_BACKUP_DIR: writable, hardlinks work ($fstype)"
    else err "backup_dir $CFG_BACKUP_DIR: cannot write or hardlink"; rc=1; fi
    rm -f "$probe" "$probe.l"
    log "    free: $(human "$(df -B1 --output=avail "$CFG_BACKUP_DIR" | tail -1)"), inodes free: $(df --output=iavail "$CFG_BACKUP_DIR" | tail -1 | tr -d ' ')"
    for n in flock sha256sum tar; do have "$n" || { err "$n is missing"; rc=1; }; done

    while read -r n; do
        [[ -n $n ]] || continue
        cfg_eval source "$CONFIG" "$n" SRC_
        use_endpoint "$SRC_ENDPOINT" SRC SEP_
        [[ $SRC_FORMAT == tar.zst ]] && ! have zstd && { err "$n: format tar.zst but zstd is not installed"; rc=1; }
        if [[ $SRC_ENCRYPT == age ]]; then
            if ! have age; then err "$n: encrypt: age but age is not installed"; rc=1
            elif [[ -n $CFG_AGE_IDENTITY_FILE ]]; then
                local -a ra=() r
                for r in ${SRC_AGE_RECIPIENTS[@]+"${SRC_AGE_RECIPIENTS[@]}"}; do ra+=(-r "$r"); done
                [[ -n $SRC_AGE_RECIPIENTS_FILE ]] && ra+=(-R "$SRC_AGE_RECIPIENTS_FILE")
                if [[ "$(echo bucketool | age "${ra[@]}" | age -d -i "$CFG_AGE_IDENTITY_FILE" 2>/dev/null)" == bucketool ]]; then
                    ok "$n: age recipients and identity file match"
                else err "$n: age_identity_file cannot decrypt for the configured recipients"; rc=1; fi
            else warn "$n: no age_identity_file — restores and full verifies of encrypted archives will need one"; fi
        fi
        if [[ $SRC_ALL_BUCKETS == true ]]; then
            if s3_buckets SRC "$RUNDIR/t-buckets.json"; then ok "$n: $SEP_URL reachable ($(eng SRC)), $(cfgpy count "$RUNDIR/t-buckets.json") bucket(s) visible"
            else err "$n: cannot list buckets on $SEP_URL: $(rclone_err)"; rc=1; fi
            continue
        fi
        if ! s3_peek SRC "$SRC_BUCKET" "$SRC_PREFIX"; then
            err "$n: cannot list $(src_path "$SRC_BUCKET"): $(rclone_err)"; rc=1; continue
        fi
        ok "$n: $(src_path "$SRC_BUCKET") readable ($(eng SRC))"
        if $deep; then
            filter_flags
            s3_list SRC "$SRC_BUCKET" "$SRC_PREFIX" "$RUNDIR/t.json" filtered || { err "$n: full listing failed: $(rclone_err)"; rc=1; continue; }
            cfg_eval estimate "$RUNDIR/t.json" ""
            log "    $E_FILES objects, $(human "$E_BYTES"), $E_MARKERS folder marker(s)"
            (( E_SKIPPED > 0 )) && warn "    $E_SKIPPED object(s) cannot be backed up (unrepresentable names or archive storage class)"
            local first; first="$(cfgpy first-key "$RUNDIR/t.json")"
            if [[ -n $first ]]; then
                if s3_read_one SRC "$SRC_BUCKET" "$SRC_PREFIX" "$first"; then ok "    read access OK ($first)"
                else err "    cannot read $first: $(rclone_err)"; rc=1; fi
            fi
        fi
    done < <(cfgpy names "$CONFIG" sources)

    while read -r n; do
        [[ -n $n ]] || continue
        load_target "$n"
        local exists=false owner=""
        if s3_bucket_exists DST "$TGT_BUCKET"; then
            exists=true; ok "target $n: $(target_root) exists ($(eng DST))${TGT_SCRATCH/false/}"
        elif [[ $TGT_CREATE == true ]]; then log "target $n: bucket $TGT_BUCKET missing (created on first restore)"
        else err "target $n: bucket $TGT_BUCKET not reachable on $DEP_URL: $(rclone_err)"; rc=1; continue; fi
        owner="$(is_source_bucket "$DEP_ID" "$TGT_BUCKET")" || owner=""
        if $deep && [[ -n $owner ]]; then
            warn "    target $n is bucket '$TGT_BUCKET' that source '$owner' backs up — write probe skipped"
        elif $deep && $exists; then
            if s3_write_probe DST "$TGT_BUCKET" "$TGT_PREFIX"; then ok "    write + delete probe OK"
            else err "    write probe failed: $(rclone_err)"; rc=1; fi
        fi
    done < <(cfgpy names "$CONFIG" targets)

    if [[ $OFFSITE_ENABLED == true ]]; then
        use_endpoint "$OFFSITE_ENDPOINT" OFF OEP_
        local off_ok=false
        if s3_bucket_exists OFF "$OFFSITE_BUCKET"; then
            ok "offsite: $OEP_URL bucket $OFFSITE_BUCKET reachable ($(eng OFF))"; off_ok=true
        elif s3_buckets OFF "$RUNDIR/t-off.json"; then
            warn "offsite: bucket $OFFSITE_BUCKET does not exist yet — the first copy creates it (needs CreateBucket permission)"
        else err "offsite: $OEP_URL not reachable: $(rclone_err)"; rc=1; fi
        if $deep && $off_ok; then
            local ver; ver="$(s3_versioning OFF "$OFFSITE_BUCKET" || true)"
            if [[ $ver == *Enabled* ]]; then ok "    bucket versioning enabled (point-in-time history for snapshots)"
            else warn "    bucket versioning is ${ver:-off}: off-site snapshots keep only the newest state"; fi
        fi
    fi
    if (( rc == 0 )); then ok "all checks passed"; else err "some checks FAILED"; fi
    return $rc
}

cmd_discover() {
    local url="" only="" sizes=false
    while (( $# )); do
        case "$1" in
            --url) url="$2"; shift 2 ;;
            --endpoint) only="$2"; shift 2 ;;
            --sizes) sizes=true; shift ;;
            *) die "discover: unknown option $1" ;;
        esac
    done
    local -a eps=()
    if [[ -n $url ]]; then eps=("--url")
    elif [[ -n $only ]]; then eps=("$only")
    else mapfile -t eps < <(cfgpy names "$CONFIG" endpoints); fi
    local e v
    for e in "${eps[@]}"; do
        for v in $(compgen -e); do [[ $v == RCLONE_CONFIG_SRC_* ]] && unset "$v"; done
        if [[ $e == --url ]]; then cfg_eval url-endpoint "$CONFIG" "$url" SRC SEP_
        else cfg_eval endpoint "$CONFIG" "$e" SRC SEP_; fi
        printf '\n%s%s%s  (%s, %s)\n' "$C_B" "$SEP_URL" "$C_0" "${e/--url/url}" "$(eng SRC)"
        s3_buckets SRC "$RUNDIR/d.json" || { err "cannot list buckets: $(rclone_err)"; continue; }
        printf '  %-40s %12s  %s\n' BUCKET "$($sizes && echo SIZE)" 'BACKED UP BY'
        local b who size
        while IFS=$'\t' read -r b who; do
            size=""
            if $sizes && s3_list SRC "$b" "" "$RUNDIR/d-size.json" 2>/dev/null; then
                size="$(human "$(cfgpy listing-bytes "$RUNDIR/d-size.json")")"
            fi
            printf '  %-40s %12s  %s\n' "$b" "$size" "${who:-${C_Y}-- NOT BACKED UP${C_0}}"
        done < <(cfgpy discover "$CONFIG" "$SEP_ID" "$RUNDIR/d.json")
    done
}

cmd_list() {
    local n
    printf '%sSources%s\n' "$C_B" "$C_0"
    while read -r n; do [[ -n $n ]] && printf '  %s\n' "$n"; done < <(cfgpy names "$CONFIG" sources)
    printf '%sTargets%s\n' "$C_B" "$C_0"
    while read -r n; do [[ -n $n ]] && printf '  %s\n' "$n"; done < <(cfgpy names "$CONFIG" targets)
    printf '%sBackups in %s%s' "$C_B" "$CFG_BACKUP_DIR" "$C_0"
    cfgpy list "$CFG_BACKUP_DIR" "${1:-}"
}

# ===========================================================================
#  SELF-UPDATE / PARSE-URL
# ===========================================================================
cmd_self_update() {
    local check_only=false force=false
    while (( $# )); do
        case "$1" in
            --check) check_only=true; shift ;;
            --force) force=true; shift ;;
            --main)  BUCKETOOL_UPDATE_CHANNEL=main; shift ;;
            --release) BUCKETOOL_UPDATE_CHANNEL=release; shift ;;
            *) die "self-update: unknown option $1 (--check, --force, --main, --release)" ;;
        esac
    done
    have curl || die "self-update needs curl (or update with: git pull && sudo ./install.sh)"
    local tmp="$BOOT_DIR/bucketool.new" url="$BUCKETOOL_UPDATE_URL" ref=""
    if [[ -z $url ]]; then
        if [[ $BUCKETOOL_UPDATE_CHANNEL == release ]]; then
            ref="$(curl -fsSL --max-time 20 "https://api.github.com/repos/${BUCKETOOL_REPO}/releases/latest" 2>/dev/null \
                   | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
            [[ -n $ref ]] || die "no published release found for ${BUCKETOOL_REPO} (use --main to follow the development branch)"
        else
            ref=main
        fi
        url="https://raw.githubusercontent.com/${BUCKETOOL_REPO}/${ref}/bucketool.sh"
    fi
    log "fetching ${ref:+$ref — }$url"
    curl -fsSL --max-time 60 "$url" -o "$tmp" || die "cannot download $url"
    if [[ -z $BUCKETOOL_UPDATE_URL && $ref != main ]]; then
        # releases publish SHA256SUMS next to the script
        local sums="$BOOT_DIR/SHA256SUMS" want
        curl -fsSL --max-time 30 "https://github.com/${BUCKETOOL_REPO}/releases/download/${ref}/SHA256SUMS" -o "$sums" \
            || die "release $ref has no SHA256SUMS — refusing an unverifiable update"
        want="$(awk '$2 == "bucketool.sh" || $2 == "*bucketool.sh" {print $1}' "$sums")"
        [[ -n $want && "$(sha256sum "$tmp" | awk '{print $1}')" == "$want" ]] || die "checksum mismatch for $url — refusing"
        ok "checksum verified against the release's SHA256SUMS"
    fi
    head -1 "$tmp" | grep -q '^#!/usr/bin/env bash' || die "downloaded file is not a shell script"
    local newv
    newv="$(sed -n 's/^readonly BUCKETOOL_VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -1)"
    [[ -n $newv ]] || die "downloaded file carries no BUCKETOOL_VERSION — refusing"
    bash -n "$tmp" || die "downloaded file has a syntax error — refusing"
    if ! $force; then
        if [[ $newv == "$BUCKETOOL_VERSION" ]]; then ok "already up to date (v$BUCKETOOL_VERSION)"; return 0; fi
        if [[ "$(printf '%s\n%s\n' "$newv" "$BUCKETOOL_VERSION" | sort -V | tail -1)" == "$BUCKETOOL_VERSION" ]]; then
            ok "installed v$BUCKETOOL_VERSION is newer than v$newv — nothing to do (--force to install it anyway)"; return 0
        fi
    fi
    log "installed v$BUCKETOOL_VERSION — available v$newv"
    $check_only && { warn "update available: v$BUCKETOOL_VERSION -> v$newv (run: $SCRIPT_NAME self-update)"; return 10; }
    $DRY_RUN && { ok "dry run: would replace $SCRIPT_PATH with v$newv"; return 0; }
    [[ -w $SCRIPT_PATH ]] || die "$SCRIPT_PATH is not writable — re-run with sudo"
    local bak="${SCRIPT_PATH}.v${BUCKETOOL_VERSION}.bak"
    cp -p "$SCRIPT_PATH" "$bak" || die "cannot keep a backup at $bak"
    cp "$tmp" "${SCRIPT_PATH}.new" && chmod 0755 "${SCRIPT_PATH}.new" && mv -f "${SCRIPT_PATH}.new" "$SCRIPT_PATH" \
        || die "could not install the new version (old one untouched at $SCRIPT_PATH)"
    ok "updated $SCRIPT_PATH: v$BUCKETOOL_VERSION -> v$newv  (previous kept at $(basename "$bak"))"
}

cmd_parse_url() {
    [[ -n ${1:-} ]] || die "parse-url: give an s3:// / https:// URL"
    cfgpy url "$1"
}

usage() {
cat <<EOF
${SCRIPT_NAME} v${BUCKETOOL_VERSION} — S3 / MinIO bucket backup, restore and verify

USAGE
  ${SCRIPT_NAME} <command> [options]

COMMANDS
  backup [all|NAME[,NAME]]       Back up sources: list -> diff -> download changes -> verify
                                 -> off-site copy -> prune -> notify
  verify --latest NAME|all       Check the newest backup (quick: presence, sizes, checksums)
         [--full] [-t TARGET]    --full re-hashes every object; -t also checks a restored bucket
  verify DIR                     Check one backup directory
  restore --latest NAME | -f DIR Restore into a target bucket or a local directory
          -t TARGET | --to-dir DIR
          [--at DATE] [--prefix P] [--include GLOB]... [--mode merge|mirror|skip-existing]
          [--create] [--verify none|quick|full] [--force-source]
  drill [NAME] [-t SCRATCH]      Restore the newest backup into a scratch target, verify it fully,
                                 clean up, report RPO/RTO
  list [LABEL]                   Sources, targets, backups and what hardlinks save on disk
  prune                          Apply retention now (local and off-site)
  test [--deep]                  Check rclone, disk, endpoints, buckets, targets, keys
  discover [--endpoint E | --url URL] [--sizes]
                                 Buckets on a server and which the config does not cover
  parse-url URL                  Show how an s3:// endpoint URL is read (secret masked)
  self-update [--check]          Install the newest release of bucketool

GLOBAL OPTIONS
  -c, --config FILE   config file (default: ./bucketool.yml, then /etc/bucketool/bucketool.yml)
  -n, --dry-run       show what would happen, change nothing
  -y, --yes           no prompts (needed for cron/systemd and --mode mirror)
  -q, --quiet         only warnings and errors
  -v, --verbose       show rclone's own output
  --json              machine-readable summary (backup)
  --no-offsite        skip the off-site copy
  --no-prune          skip retention after a backup
  --allow-shrink      accept a backup where most objects vanished (see max_delete_percent)
  --force             restore from a backup that failed verification
  -V, --version       print the version

EXIT STATUS
  0 ok   1 failure   2 usage error   3 finished with warnings   10 update available

Config: ${SCRIPT_NAME%.sh}.example.yml.  Docs: README.md, SOP.md, TROUBLESHOOTING.md.
EOF
}

main() {
    local -a rest=()
    local cmd=""
    while (( $# )); do
        case "$1" in
            -c|--config)  CONFIG="$2"; shift 2 ;;
            -n|--dry-run) DRY_RUN=true; shift ;;
            -y|--yes)     ASSUME_YES=true; shift ;;
            -q|--quiet)   QUIET=true; shift ;;
            -v|--verbose) VERBOSE=true; shift ;;
            --json)       JSON_OUT=true; QUIET=true; shift ;;
            --no-offsite) NO_OFFSITE=true; shift ;;
            --no-prune)   NO_PRUNE=true; shift ;;
            --allow-shrink) ALLOW_SHRINK=true; shift ;;
            --force)      FORCE=true; shift ;;
            -h|--help)    usage; exit 0 ;;
            -V|--version) echo "$BUCKETOOL_VERSION"; exit 0 ;;
            -*)           if [[ -n $cmd ]]; then rest+=("$1"); shift
                          else echo "unknown option: $1 (see -h)" >&2; exit 2; fi ;;
            *)            if [[ -z $cmd ]]; then cmd="$1"; else rest+=("$1"); fi; shift ;;
        esac
    done
    [[ -n $cmd ]] || { usage; exit 2; }
    printf '%s\n' "$BUCKETOOL_PY" >"$PY"
    case "$cmd" in
        parse-url) cmd_parse_url ${rest[@]+"${rest[@]}"}; exit $? ;;
        self-update|update) cmd_self_update ${rest[@]+"${rest[@]}"}; exit $? ;;
        _py) python3 "$PY" ${rest[@]+"${rest[@]}"}; exit $? ;;   # internal: tests call the helper directly
    esac
    load_config
    # Commands are called plainly, never as `cmd || rc=$?`: bash suspends set -e
    # for everything below a command in an ||/&& list, including the guarded
    # per-source subshells. A command's non-zero return ends the run with that status.
    case "$cmd" in
        backup)   cmd_backup ${rest[@]+"${rest[@]}"} ;;
        verify)   cmd_verify ${rest[@]+"${rest[@]}"} ;;
        restore)  cmd_restore ${rest[@]+"${rest[@]}"} ;;
        drill)    cmd_drill ${rest[@]+"${rest[@]}"} ;;
        list)     cmd_list ${rest[@]+"${rest[@]}"} ;;
        prune)    cmd_prune ;;
        test)     cmd_test ${rest[@]+"${rest[@]}"} ;;
        discover) cmd_discover ${rest[@]+"${rest[@]}"} ;;
        *) echo "unknown command: $cmd (see -h)" >&2; exit 2 ;;
    esac
    exit 0
}

main "$@"
