"""Offline repository checks. These do NOT execute PostgreSQL or prove RLS."""
from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
failures: list[str] = []


def check(condition: bool, label: str) -> None:
    print(f"{'PASS' if condition else 'FAIL'}: {label}")
    if not condition:
        failures.append(label)


spec = (ROOT / 'API_SPEC.md').read_text(encoding='utf-8-sig')
migrations = sorted((ROOT / 'supabase/migrations').glob('*.sql'))
schema = migrations[0].read_text(encoding='utf-8')
integrity = migrations[1].read_text(encoding='utf-8')
security = migrations[2].read_text(encoding='utf-8')
tests = (ROOT / 'supabase/tests/database/001_foundation_test.sql').read_text(encoding='utf-8')
seed = (ROOT / 'supabase/seed.sql').read_text(encoding='utf-8')
section = spec.split('## 11. Database table reference')[1].split('### 11.1')[0]
contract_tables = set(re.findall(r'^\| `([a-z_]+)` \|', section, re.M))
actual_tables = set(re.findall(r'create table public\.([a-z_]+)', schema))
check(actual_tables == contract_tables and len(actual_tables) == 22, 'All 22 API-contract tables exist')
check(all(re.fullmatch(r'\d{14}_[a-z_]+\.sql', p.name) for p in migrations), 'Versioned migration filenames')
check('enable row level security' in security and 'force row level security' in security
      and all(f"'{t}'" in security for t in actual_tables), 'RLS migration names every application table')
check(all(f"('{t}', " in tests for t in actual_tables), 'Security test matrix covers every application table')
check('set local role anon' in tests and 'set local role authenticated' in tests
      and 'set local role service_role' in tests and 'allowlisted browser admin' in tests,
      'Database suite includes anonymous, candidate, admin-browser, service contexts')
check('grant update (display_name, timezone)' in security
      and 'grant update on' not in security, 'Browser UPDATE grant limited to safe profile fields')
check('new.raw_user_meta_data' not in integrity and "values (new.id, 'candidate')" in integrity,
      'Auth profile trigger ignores editable metadata')
for statement in re.findall(r'create function .*?\$\$;', integrity + security, re.S):
    if 'security definer' in statement:
        check("set search_path = ''" in statement, 'Security-definer function has fixed empty search path')

api_sql = '\n'.join(p.read_text(encoding='utf-8') for p in migrations[3:])
api_functions = re.findall(r'create function .*?\$\$;', api_sql, re.S)
check(len(api_functions) >= 20 and all("set search_path = ''" in f for f in api_functions),
      'Every new API function has a fixed empty search path')
privileged_api = re.findall(r'create(?: or replace)? function .*?\$\$;', api_sql, re.S)
check(all('security definer' not in f.lower() or
          ((f.startswith('create or replace function private.validate_session()')
            or f.startswith('create function public.qiyadat_admin_payments('))
           and "set search_path = ''" in f) for f in privileged_api),
      'API operations use invoker privileges except the guarded admin email projection and existing session trigger')
check('revoke all on function public.qiyadat_mutate' in api_sql
      and 'from public,anon,authenticated' in api_sql
      and 'grant execute on function public.qiyadat_mutate' in api_sql,
      'Trusted dispatcher has explicit revocation and service-only grant')
check('force row level security' in api_sql and 'private.api_rate_windows' in api_sql,
      'Private rate counters use forced RLS')
payment_admin = (ROOT / 'supabase/migrations/20261019000200_payment_admin.sql').read_text(encoding='utf-8')
check('perform private.api_actor(p_actor);perform private.payment_admin(p_actor)' in payment_admin
      and 'from public,anon,authenticated' in payment_admin
      and 'to service_role' in payment_admin,
      'Admin payment projection checks service actor and allowlist with no browser execution')
check('left join auth.users' in payment_admin and 'grant select' not in payment_admin,
      'Admin email projection adds no general Auth table grant')
check('order by id for update' in payment_admin and 'insert into public.admin_audit_log' in payment_admin,
      'Payment decisions serialize profile access and insert audit transactionally')
check('revoke truncate on public.admin_audit_log from service_role' in api_sql
      and 'private.payment_text_has_reference' in api_sql,
      'Payment decision text excludes references and service audit truncate is revoked')
check((ROOT / 'supabase/tests/database/002_api_test.sql').exists()
      and (ROOT / 'supabase/functions/tests/api_http_test.ts').exists(),
      'New database and real HTTP test suites exist')

cfg = tomllib.loads((ROOT / 'supabase/config.toml').read_text(encoding='utf-8'))
check(cfg['project_id'] == 'qiyadat-local' and cfg['db']['seed']['sql_paths'] == ['./seed.sql'],
      'Local config parses and enables seed.sql')
check('private' not in cfg['api']['schemas'] and cfg['edge_runtime']['enabled']
      and cfg['functions']['api']['verify_jwt'] is False,
      'Private schema unexposed; API validates user JWTs internally')
check('local_smtp' in cfg and 'inbucket' not in cfg,
      'Current local SMTP configuration avoids the deprecated section')
check((cfg['api']['port'], cfg['db']['port'], cfg['db']['shadow_port'],
       cfg['studio']['port'], cfg['local_smtp']['port']) == (55321, 55322, 55320, 55323, 55324),
      'Local ports match the documented Windows port workaround')
check(all('storage.allow_delete_query' not in p.read_text(encoding='utf-8') for p in migrations)
      and all('storage.allow_delete_query' not in p.read_text(encoding='utf-8')
              for p in (ROOT / 'supabase/functions').rglob('*.ts')),
      'Storage SQL deletion opt-in is confined to tests')

bank_match = re.search(r'const\s+WORD_BANK\s*=\s*\[([^]]+)\]',
                      (ROOT / 'wat-practice.html').read_text(encoding='utf-8'), re.S)
check(bank_match is not None, 'Existing frontend word bank located')
if bank_match:
    words = re.findall(r"'([^']+)'", bank_match.group(1))[:20]
    seed_words_section = seed.split('from unnest(array[')[1].split('])')[0]
    seeded_words = re.findall(r"'([^']+)'", seed_words_section)
    check(words == seeded_words and len(seeded_words) == 20, 'Seed exactly matches first 20 current WAT words')
check(not re.search(r'insert into (?:public\.)?(?:admin_users|payment_offers|profiles|auth\.users)', seed, re.I),
      'Seed contains no accounts, admins, or payment offers')
seed_settings = {key: json.loads(value) for key, value in
                 re.findall(r"\('([A-Za-z_]+)', '([^']+)'\)", seed)}
constants = spec.split('## 3. Configuration constants')[1].split('### 3.1')[0]
for key, value in re.findall(r'^\| `([A-Z_]+)` \| `(\d+)` \|', constants, re.M):
    check(seed_settings.get(key) == int(value), f'Seed {key} matches API_SPEC.md')
check(seed_settings['WAT_ALLOWED_SESSION_SIZES'] == [20], 'Only 20-word sessions in v1')
check(seed_settings['PAPER_ALLOWED_MIME_TYPES'] == ['image/jpeg', 'image/png', 'image/webp'],
      'Seed paper MIME allowlist matches contract')

baseline = {
    'index.html': '90e3ac9bfe2580d44452db849017cc0baedb4492e2bad707b223dffb76f40b30',
    'wat-practice.html': 'ba8f87516b3d26297c8dd3858e25ea03cd339a4384fea556edcfa927a2806317',
    'wat-results.html': 'cf7ca45a0bd3a600c2c0820ea8dd4dd96917d581b59f1c61e65ac12169a7202d',
    'wat-dashboard.html': '99fb1c72877c3972443759bc71335b17a7957463288fd32530ce2b002a5415fc',

}
baseline.update(json.loads((ROOT / 'backend/verification_baseline.json').read_text()))
for name, expected in baseline.items():
    check(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == expected, f'{name} byte-for-byte unchanged')

try:
    result = subprocess.run(['node', str(ROOT / 'backend/scripts/verify_frontend.cjs')],
                            cwd=ROOT, capture_output=True, text=True, timeout=30)
    print(result.stdout.strip())
    check(result.returncode == 0, 'Frontend inline JavaScript parses and local links resolve')
except (OSError, subprocess.TimeoutExpired):
    check(False, 'Node.js available for frontend syntax check')

env_lines = (ROOT / 'backend/.env.example').read_text(encoding='utf-8').splitlines()
check(all(not line.strip() or line.startswith('#') or re.fullmatch(r'[A-Z_]+=', line) for line in env_lines),
      '.env.example has variable names with empty values only')
check(not any(p.name.startswith('.env') and p.name != '.env.example' for p in ROOT.rglob('*') if p.is_file()),
      'No actual environment files in repository')
# Require key material, not a parser's quoted PEM header constant. Cover both
# real line breaks and escaped JSON line breaks without exempting source files.
private_key_pattern = r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----(?:(?:\s|\\r|\\n)*[A-Za-z0-9+/=]){64,}'
header = '-----BEGIN ' + 'PRIVATE KEY-----'
check(bool(re.search(private_key_pattern, header + '\n' + 'A' * 64))
      and bool(re.search(private_key_pattern, header + r'\n' + 'A' * 64))
      and not re.search(private_key_pattern, "startsWith('" + header + "')"),
      'Credential scan detects raw/JSON PEM material without flagging header parsers')
secret_patterns = [private_key_pattern,
                   r'AIza[0-9A-Za-z_-]{35}', r'gh[pousr]_[A-Za-z0-9]{30,}',
                   r'sb_secret_[A-Za-z0-9_-]{15,}',
                   r'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}']
suspect_files = []
for path in ROOT.rglob('*'):
    if not path.is_file() or path.suffix.lower() not in {'.md', '.sql', '.toml', '.html', '.json', '.example', '.ts', '.cjs', '.py'}:
        continue
    if any(part in {'.temp', '.branches', 'node_modules', '.git'} for part in path.parts):
        continue
    data = path.read_text(encoding='utf-8-sig')
    if any(re.search(pattern, data) for pattern in secret_patterns):
        suspect_files.append(str(path.relative_to(ROOT)))
check(not suspect_files, 'No recognizable private-key, provider-key, access-token, or JWT values')
if suspect_files:
    print('Review files: ' + ', '.join(suspect_files))  # Never prints matched secret contents.
ignore_rules = (ROOT / '.gitignore').read_text(encoding='utf-8').splitlines()
check(all(rule in ignore_rules for rule in ['supabase/.temp/', 'supabase/.branches/', '*.bak',
                                         '.env', 'supabase/exports/', 'backend/data/']),
      'Local CLI state, backups, environments and generated data are ignored')
check(not any(p.exists() for p in [ROOT / 'supabase/exports', ROOT / 'backend/data']),
      'No generated exports or application data directories')
print('NOTE: Git tracking cannot be checked: this workspace has no .git metadata.'
      if not (ROOT / '.git').exists() else 'NOTE: Check git status separately before committing.')
print('NOTE: PostgreSQL migration execution and RLS behavior remain unverified by this offline checker.')
sys.exit(bool(failures))
