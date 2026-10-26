#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import hashlib, io, json, os, pathlib, re, shutil, subprocess, tarfile, tempfile

root = pathlib.Path.cwd()
# Keep fixtures independent of whichever stable release the tap currently installs.
template = re.sub(r'^  url ".*"$', '  url "https://github.com/HitKeep/hitkeep/archive/refs/tags/v2.15.0.tar.gz"',
                  (root / 'Formula/hitkeep.rb').read_text(), flags=re.MULTILINE)
template = re.sub(r'^  sha256 ".*"$', '  sha256 "' + '0'*64 + '"', template, flags=re.MULTILINE)
sha = 'a' * 40
workflow_sha = 'b' * 40
base = 'c' * 40
count = 0
with tempfile.TemporaryDirectory() as temporary:
    temp = pathlib.Path(temporary)
    archive = temp / 'source.tar.gz'
    tree = []
    with tarfile.open(archive, 'w:gz') as tar:
        for name, content in {'go.mod': 'module hitkeep\n', 'go.sum': '', 'LICENSE': 'MIT\n', 'cmd/hitkeep/main.go': 'package main\n',
                              'frontend/dashboard/package.json': '{"version":"2.15.1"}',
                              'public/index.html': '<html></html>', 'public/hk.js': '/* tracker */', 'public/hk-vitals.js': '/* vitals */', 'public/embed.go': 'package public\n'}.items():
            data = content.encode()
            info = tarfile.TarInfo('hitkeep-2.15.1/' + name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
            if not name.startswith('public/') or name == 'public/embed.go':
                tree.append({'path': name, 'type': 'blob', 'mode': '100644', 'sha': hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()})
    (temp / 'tree.json').write_text(json.dumps({'truncated': False, 'tree': tree}))
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    manifest = {'schema_version': 1, 'tag': 'v2.15.1', 'source_commit': sha,
                'checks': {name: 'success' for name in ('native', 'archives', 'tracker', 'chart', 'docker', 'compose', 'helm', 'docs', 'assistant-package', 'source-archive')},
                'producer_run_id': 42, 'producer_run_attempt': 2, 'producer_workflow_sha': workflow_sha,
                'artifacts': [{'name': 'hitkeep-source-2.15.1.tar.gz', 'type': 'source-archive', 'sha256': digest}]}
    (temp / 'manifest.json').write_text(json.dumps(manifest))
    fake = temp / 'bin'
    fake.mkdir()
    (fake / 'gh').write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
case = os.environ['CASE']
def out(value): print(json.dumps(value))
if case in ('network', 'auth'): sys.exit(1)
if args[:2] == ['attestation', 'verify']:
    required = ['--repo', 'HitKeep/hitkeep', '--signer-workflow', 'HitKeep/hitkeep/.github/workflows/release.yml', '--source-ref', 'refs/heads/main', '--source-digest', 'b'*40, '--format', 'json']
    assert all(value in args for value in required), args
    if case == 'wrong-signer': sys.exit(1)
    invocation = 'https://github.com/HitKeep/hitkeep/actions/runs/42/attempts/' + ('1' if case == 'wrong-attempt' else '2')
    out([{'verificationResult': {'statement': {'predicate': {'runDetails': {'metadata': {'invocationId': invocation}}}}}}])
    sys.exit()
if args[:2] == ['auth', 'setup-git']: sys.exit()
assert args[0] == 'api', args
endpoint = args[1]
if endpoint == 'repos/HitKeep/hitkeep':
    out({'private': case == 'private'})
elif '/git/trees/' in endpoint:
    sys.stdout.write(pathlib.Path(os.environ['FIXTURES'], 'tree.json').read_text())
elif '/collaborators/' in endpoint:
    out({'permission': 'read' if case == 'unauthorized-actor' else 'write'})
elif endpoint.endswith('releases/latest'):
    print('v2.15.1')
elif '/releases/tags/' in endpoint:
    out({'tag_name': 'v2.15.1', 'draft': case == 'draft', 'prerelease': case == 'prerelease',
         'assets': [{'id': 1, 'name': 'release-candidate.json'}, {'id': 2, 'name': 'hitkeep-source-2.15.1.tar.gz', 'digest': 'sha256:' + os.environ['DIGEST']}]})
elif endpoint.endswith('releases/assets/1'):
    sys.stdout.write(pathlib.Path(os.environ['FIXTURES'], 'manifest.json').read_text())
elif '/actions/runs/' in endpoint:
    out({'id': 43 if case == 'wrong-run' else 42, 'run_attempt': 1 if case == 'wrong-run-attempt' else 2, 'path': '.github/workflows/' + ('other.yml' if case == 'wrong-workflow' else 'release.yml'), 'event': 'pull_request' if case == 'wrong-event' else ('workflow_dispatch' if case == 'manual-producer' else 'push'), 'head_branch': 'main',
         'head_sha': ('d' if case == 'wrong-workflow-sha' else 'b')*40, 'status': 'completed', 'conclusion': 'failure' if case == 'failed-producer' else 'success', 'repository': {'full_name': 'HitKeep/hitkeep'}})
elif endpoint.endswith('git/ref/tags/v2.15.1'):
    out({'object': {'type': 'commit', 'sha': ('d' if case == 'moved-tag' else 'a')*40}})
elif '/branches/main' in endpoint and '/rules/' not in endpoint:
    out({'protected': case == 'protected', 'commit': {'sha': os.environ.get('HEAD_SHA', 'c'*40)}})
elif '/rules/branches/main' in endpoint:
    out([{'type': 'pull_request'}] if case == 'rules' else [])
else:
    raise AssertionError(endpoint)
''')
    (fake / 'curl').write_text('''#!/usr/bin/env python3
import os, pathlib, shutil, sys
assert '--fail' in sys.argv and '--location' in sys.argv
assert sys.argv[-1] in ('https://github.com/HitKeep/hitkeep/releases/download/v2.15.1/hitkeep-source-2.15.1.tar.gz', 'https://github.com/HitKeep/hitkeep/archive/refs/tags/v2.15.1.tar.gz')
if os.environ['CASE'] == 'curl-failure': sys.exit(1)
if '--output' not in sys.argv:
    sys.stdout.buffer.write(pathlib.Path(os.environ['FIXTURES'], 'source.tar.gz').read_bytes())
    sys.exit()
out = pathlib.Path(sys.argv[sys.argv.index('--output') + 1])
shutil.copyfile(pathlib.Path(os.environ['FIXTURES']) / 'source.tar.gz', out)
if os.environ['CASE'] == 'tampered': out.write_bytes(b'bad archive')
''')
    (fake / 'git').write_text('''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
if args[:2] == ['rev-parse', 'HEAD']:
    print('c'*40)
elif args[:2] == ['status', '--porcelain']:
    pass
elif args[:2] == ['ls-remote', 'origin']:
    written = pathlib.Path(os.environ['WRITES'])
    pushed = written.exists() and 'push origin' in written.read_text()
    print(('e' if pushed else ('d' if os.environ['CASE'] == 'race' else 'c'))*40 + '\\trefs/heads/main')
elif args[0] == 'show':
    sys.stdout.write(pathlib.Path(os.environ['FORMULA_INPUT']).read_text())
elif args[0] == 'hash-object':
    formula = pathlib.Path(args[-1]).read_text()
    assert os.environ['DIGEST'] in formula and '/releases/download/v2.15.1/hitkeep-source-2.15.1.tar.gz' in formula
    print('f'*40)
elif args[0] == 'write-tree':
    print('e'*40)
elif args[0] == 'diff-tree':
    if '--name-only' in args: print('Formula/hitkeep.rb')
elif 'commit-tree' in args:
    with open(os.environ['WRITES'], 'a') as file: file.write(' '.join(args) + '\\n')
    print('e'*40)
elif args[0] in ('read-tree', 'update-index'):
    pass
elif args[:3] == ['diff', '--name-only', '--cached']:
    print('Formula/hitkeep.rb')
elif args[:2] == ['diff', '--quiet']:
    sys.exit(1)
elif args[0] in ('config', 'add', 'commit', 'push'):
    with open(os.environ['WRITES'], 'a') as file: file.write(' '.join(args) + '\\n')
    if args[0] == 'push' and os.environ['CASE'] == 'rejected-push': sys.exit(1)
elif args[:2] == ['diff', '--name-only']:
    print('Formula/hitkeep.rb')
elif args[0] in ('diff', 'fetch'):
    pass
else:
    raise AssertionError(args)
''')
    for path in fake.iterdir(): path.chmod(0o755)

    def run(case, *, publish=False, current='2.15.0', checksum=None, success=False, explicit=True):
        global count
        work = temp / ('work-' + str(count))
        count += 1
        (work / 'scripts').mkdir(parents=True)
        (work / 'Formula').mkdir()
        shutil.copy(root / 'scripts/update-formula.sh', work / 'scripts/update-formula.sh')
        formula = template.replace('v2.15.0.tar.gz', 'v' + current + '.tar.gz')
        if checksum is not None:
            formula = re.sub(r'  url ".*"', '  url "https://github.com/HitKeep/hitkeep/releases/download/v2.15.1/hitkeep-source-2.15.1.tar.gz"', formula)
            formula = re.sub(r'  sha256 ".*"', '  sha256 "' + checksum + '"', formula)
        if case == 'malformed-invalid': formula += '\n  sha256 "not-a-digest"\n'
        if case == 'malformed': formula += '\n  sha256 "' + '0'*64 + '"\n'
        path = work / 'Formula/hitkeep.rb'
        path.write_text(formula)
        writes = work / 'writes'
        remote_formula = work / 'main.rb'
        remote_formula.write_text(formula + ('\n# changed tooling\n' if case == 'tooling-drift' else ''))
        fixtures = work / 'fixtures'
        fixtures.mkdir()
        shutil.copy(temp / 'tree.json', fixtures / 'tree.json')
        shutil.copy(archive, fixtures / 'source.tar.gz')
        candidate_manifest = json.loads(json.dumps(manifest))
        if case in ('traversal', 'extra-member', 'symlink', 'wrong-source', 'missing-source', 'wrong-version', 'duplicate-member', 'malformed-archive', 'wrong-git-pax', 'changed-embed-source', 'extra-go-source'):
            with tarfile.open(archive) as tar:
                members = [(entry, tar.extractfile(entry).read()) for entry in tar.getmembers()]
            with tarfile.open(fixtures / 'source.tar.gz', 'w:gz') as tar:
                for entry, data in members:
                    if case == 'missing-source' and entry.name.endswith('/go.sum'): continue
                    if case == 'changed-embed-source' and entry.name.endswith('/public/embed.go'): data += b'// changed code'
                    if case == 'wrong-source' and entry.name.endswith('/go.mod'): data += b'// wrong source'
                    if case == 'wrong-version' and entry.name.endswith('/package.json'):
                        data = b'{"version":"2.15.2"}'
                        changed_tree = json.loads((fixtures / 'tree.json').read_text())
                        for blob in changed_tree['tree']:
                            if blob['path'] == 'frontend/dashboard/package.json':
                                blob['sha'] = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
                        (fixtures / 'tree.json').write_text(json.dumps(changed_tree))
                    entry.size = len(data)
                    tar.addfile(entry, io.BytesIO(data))
                if case in ('traversal', 'extra-member', 'symlink', 'duplicate-member', 'extra-go-source'):
                    name = {'traversal': 'hitkeep-2.15.1/../escape', 'extra-member': 'hitkeep-2.15.1/private.txt',
                            'extra-go-source': 'hitkeep-2.15.1/public/evil.go', 'symlink': 'hitkeep-2.15.1/link', 'duplicate-member': 'hitkeep-2.15.1/go.mod'}[case]
                    info = tarfile.TarInfo(name)
                    if case == 'symlink': info.type, info.linkname = tarfile.SYMTYPE, '/etc/passwd'
                    tar.addfile(info)
            if case == 'malformed-archive': (fixtures / 'source.tar.gz').write_bytes(b'not a gzip archive')
            candidate_manifest['artifacts'][0]['sha256'] = hashlib.sha256((fixtures / 'source.tar.gz').read_bytes()).hexdigest()
        if case == 'long-source-path':
            name = 'frontend/dashboard/src/' + 'long-component-path/'*6 + 'component.ts'
            data = b'export const fixture = true;'
            with tarfile.open(archive) as tar:
                members = [(entry, tar.extractfile(entry).read()) for entry in tar.getmembers()]
            with tarfile.open(fixtures / 'source.tar.gz', 'w:gz') as tar:
                for entry, content in members: tar.addfile(entry, io.BytesIO(content))
                info = tarfile.TarInfo('hitkeep-2.15.1/' + name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
            changed_tree = json.loads((fixtures / 'tree.json').read_text())
            changed_tree['tree'].append({'path': name, 'type': 'blob', 'mode': '100644',
                                        'sha': hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()})
            (fixtures / 'tree.json').write_text(json.dumps(changed_tree))
            candidate_manifest['artifacts'][0]['sha256'] = hashlib.sha256((fixtures / 'source.tar.gz').read_bytes()).hexdigest()
        if case in ('git-pax', 'wrong-git-pax'):
            with tarfile.open(archive) as tar:
                members = [(entry, tar.extractfile(entry).read()) for entry in tar.getmembers()]
            with tarfile.open(fixtures / 'source.tar.gz', 'w:gz', format=tarfile.PAX_FORMAT,
                              pax_headers={'comment': ('d' if case == 'wrong-git-pax' else 'a')*40}) as tar:
                for entry, data in members: tar.addfile(entry, io.BytesIO(data))
            candidate_manifest['artifacts'][0]['sha256'] = hashlib.sha256((fixtures / 'source.tar.gz').read_bytes()).hexdigest()
        if case == 'extra-check': candidate_manifest['checks']['unrecognized'] = 'success'
        if case == 'missing-check': del candidate_manifest['checks']['source-archive']
        if case == 'failed-check': candidate_manifest['checks']['native'] = 'failure'
        if case == 'wrong-schema': candidate_manifest['schema_version'] = 2
        if case == 'wrong-artifact-type': candidate_manifest['artifacts'][0]['type'] = 'untrusted'
        if case == 'duplicate-artifact': candidate_manifest['artifacts'] *= 2
        if case == 'wrong-source-sha': candidate_manifest['source_commit'] = 'd'*40
        candidate_digest = candidate_manifest['artifacts'][0]['sha256']
        (fixtures / 'manifest.json').write_text(json.dumps(candidate_manifest))
        env = dict(os.environ, PATH=str(fake) + ':' + os.environ['PATH'], CASE=case, FIXTURES=str(fixtures),
                   WRITES=str(writes), FORMULA_INPUT=str(remote_formula), DIGEST=candidate_digest, GITHUB_REPOSITORY='HitKeep/homebrew-hitkeep',
                   GITHUB_REF='refs/heads/main', GITHUB_ACTOR='release-operator')
        if case == 'unauthorized-event': env['GITHUB_EVENT_NAME'] = 'pull_request'
        if case == 'unauthorized-ref': env['GITHUB_REF'] = 'refs/heads/topic'
        if case == 'unauthorized-repository': env['GITHUB_REPOSITORY'] = 'elsewhere/tap'
        args = ['bash', str(work / 'scripts/update-formula.sh')]
        if publish: args += ['--publish']
        if explicit: args += ['v2.15.1', sha, '0'*64 if case == 'digest-conflict' else candidate_digest]
        result = subprocess.run(args, env=env, text=True, capture_output=True)
        assert (result.returncode == 0) == success, (case, result.returncode, result.stdout, result.stderr)
        if not success:
            assert path.read_text() == formula, (case, 'changed formula on rejection')
            assert not writes.exists(), (case, 'writer called on rejection')
        if success and current in ('2.15.0', '2.9.9'):
            if publish:
                assert 'push origin ' + 'e'*40 + ':refs/heads/main' in writes.read_text()
                assert path.read_text() == formula, 'writer must preserve original workflow checkout'
            else:
                assert 'releases/download/v2.15.1/hitkeep-source-2.15.1.tar.gz' in path.read_text(), case
                assert candidate_digest in path.read_text(), case
        if success and current not in ('2.15.0', '2.9.9'):
            assert path.read_text() == formula and not writes.exists(), case
        print('PASS', case)
        return work

    for case in ('malformed', 'malformed-invalid', 'network', 'auth', 'curl-failure', 'moved-tag', 'wrong-signer', 'wrong-attempt',
                 'digest-conflict', 'tampered', 'private', 'draft', 'prerelease', 'unauthorized-event', 'unauthorized-ref', 'unauthorized-repository',
                 'wrong-run', 'wrong-workflow', 'wrong-event', 'wrong-workflow-sha', 'failed-producer', 'wrong-run-attempt',
                 'extra-check', 'missing-check', 'failed-check', 'wrong-schema', 'wrong-artifact-type', 'duplicate-artifact', 'wrong-source-sha',
                 'traversal', 'extra-member', 'symlink', 'wrong-source', 'missing-source', 'wrong-version', 'duplicate-member', 'malformed-archive', 'wrong-git-pax', 'changed-embed-source', 'extra-go-source'):
        run(case)
    for case in ('protected', 'rules', 'race', 'tooling-drift'):
        run(case, publish=True)
    run('valid', success=True)
    run('git-pax', success=True)
    run('manual-producer', success=True)
    run('long-source-path', success=True)
    run('reconcile', success=True, explicit=False)
    run('publish', publish=True, success=True)
    run('duplicate', current='2.15.1', checksum=digest, success=True)
    run('immutable-conflict', current='2.15.1', checksum='0'*64)
    run('stale-retry', current='2.16.0', success=True)
    run('numeric-order', current='2.9.9', success=True)

    # A real local bare remote proves fast-forward concurrency and retry recovery.
    real_git = shutil.which('git')
    writer = temp / 'real-writer'
    writer.mkdir()
    remote = temp / 'remote.git'
    def git(*args, cwd=writer):
        return subprocess.check_output([real_git, *args], cwd=cwd, text=True, stderr=subprocess.DEVNULL).strip()
    git('init', '--bare', str(remote))
    git('init', '-b', 'main')
    git('config', 'user.name', 'Fixture')
    git('config', 'user.email', 'fixture@example.test')
    (writer / 'scripts').mkdir()
    (writer / 'Formula').mkdir()
    shutil.copy(root / 'scripts/update-formula.sh', writer / 'scripts/update-formula.sh')
    (writer / 'Formula/hitkeep.rb').write_text(template)
    git('add', '.')
    git('commit', '-m', 'fixture base')
    git('remote', 'add', 'origin', str(remote))
    git('push', 'origin', 'HEAD:main')
    initial = git('rev-parse', 'HEAD')
    second = temp / 'second-writer'
    git('clone', '--branch', 'main', str(remote), str(second))
    upstream = temp / 'advanced-main'
    git('clone', '--branch', 'main', str(remote), str(upstream))
    git('config', 'user.name', 'Fixture', cwd=upstream)
    git('config', 'user.email', 'fixture@example.test', cwd=upstream)
    (upstream / 'editorial.txt').write_text('preserve this concurrent change')
    (upstream / 'scripts/update-formula.sh').write_text('#!/usr/bin/env bash\nexit 94\n')
    git('add', '.', cwd=upstream)
    git('commit', '-m', 'advance main without changing formula', cwd=upstream)
    git('push', 'origin', 'HEAD:main', cwd=upstream)
    dispatch_head = git('rev-parse', 'HEAD', cwd=upstream)
    # Leave the rest of the fakes in place while testing Git's actual writer.
    (fake / 'git').rename(fake / 'git-disabled')
    env = dict(os.environ, PATH=str(fake) + ':' + os.environ['PATH'], CASE='real-writer', FIXTURES=str(temp),
               WRITES=str(temp / 'real-writes'), DIGEST=digest, HEAD_SHA=dispatch_head,
               GITHUB_REPOSITORY='HitKeep/homebrew-hitkeep', GITHUB_REF='refs/heads/main', GITHUB_ACTOR='release-operator')
    args = ['bash', 'scripts/update-formula.sh', '--publish', 'v2.15.1', sha, digest]
    first = subprocess.Popen(args, cwd=writer, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    other = subprocess.Popen(args, cwd=second, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    results = [(*process.communicate(), process.returncode) for process in (first, other)]
    assert sum(code == 0 for _, _, code in results) == 1, results
    after = git('rev-parse', 'refs/heads/main', cwd=remote)
    assert git('rev-list', '--count', dispatch_head + '..' + after, cwd=remote) == '1'
    assert git('show', 'main:editorial.txt', cwd=remote) == 'preserve this concurrent change'
    assert git('show', 'main:scripts/update-formula.sh', cwd=remote) == '#!/usr/bin/env bash\nexit 94'
    formula_readback = git('show', 'main:Formula/hitkeep.rb', cwd=remote)
    assert digest in formula_readback and '/releases/download/v2.15.1/hitkeep-source-2.15.1.tar.gz' in formula_readback
    recovered = temp / 'recovered'
    git('clone', '--branch', 'main', str(remote), str(recovered))
    git('checkout', '--detach', initial, cwd=recovered)
    env['HEAD_SHA'] = after
    retry = subprocess.run(args, cwd=recovered, env=env, capture_output=True, text=True)
    assert retry.returncode == 0 and 'matching release:' in retry.stdout, (retry.stdout, retry.stderr)
    assert git('rev-parse', 'refs/heads/main', cwd=remote) == after
    assert git('rev-parse', 'HEAD', cwd=recovered) == initial
    assert (recovered / 'scripts/update-formula.sh').read_bytes() == (root / 'scripts/update-formula.sh').read_bytes()
    newer = temp / 'newer-main'
    git('clone', '--branch', 'main', str(remote), str(newer))
    git('config', 'user.name', 'Fixture', cwd=newer)
    git('config', 'user.email', 'fixture@example.test', cwd=newer)
    next_formula = (newer / 'Formula/hitkeep.rb')
    next_formula.write_text(next_formula.read_text().replace('2.15.1', '2.16.0').replace(digest, '9'*64))
    git('add', 'Formula/hitkeep.rb', cwd=newer)
    git('commit', '-m', 'newer release', cwd=newer)
    git('push', 'origin', 'HEAD:main', cwd=newer)
    newest = git('rev-parse', 'HEAD', cwd=newer)
    env['HEAD_SHA'] = newest
    old_retry = subprocess.run(args, cwd=recovered, env=env, capture_output=True, text=True)
    assert old_retry.returncode == 0 and 'older release skipped:' in old_retry.stdout, (old_retry.stdout, old_retry.stderr)
    assert git('rev-parse', 'refs/heads/main', cwd=remote) == newest
    assert '2.16.0' in git('show', 'main:Formula/hitkeep.rb', cwd=remote)
    print('PASS concurrent fast-forward and original-workflow-SHA matching/newer-main recovery')
print('all formula receiver fixtures passed')
PY
