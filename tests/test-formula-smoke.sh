#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import os, pathlib, subprocess, tempfile
root = pathlib.Path.cwd()
with tempfile.TemporaryDirectory() as temporary:
    temp = pathlib.Path(temporary)
    binary = temp / 'bin'
    binary.mkdir()
    (binary / 'hitkeep').write_text('''#!/usr/bin/env python3
import http.server, os, pathlib, sys, urllib.request
address = os.environ['HITKEEP_HTTP_ADDR']
if '-healthcheck' in sys.argv:
    try:
        with urllib.request.urlopen('http://' + address + '/healthz', timeout=1) as response:
            sys.exit(0 if response.status == 200 else 1)
    except Exception: sys.exit(1)
pathlib.Path(os.environ['PID_MARKER']).write_text(str(os.getpid()))
assert pathlib.Path.cwd().resolve() == pathlib.Path(os.environ['HITKEEP_DB_PATH']).parent.resolve()
for key in ('HITKEEP_DATA_PATH', 'HITKEEP_ARCHIVE_PATH'):
    assert pathlib.Path(os.environ[key]).parent.resolve() == pathlib.Path.cwd().resolve()
assert len(os.environ['HITKEEP_JWT_SECRET']) >= 32
assert os.environ['HITKEEP_SPAM_FILTER_AUTO_UPDATE'] == 'false'
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/healthz':
            self.send_response(503 if os.environ['CASE'] == 'unhealthy' else 200)
            body = b'healthy'
        else:
            self.send_response(200)
            body = (b'<html>' + b'x'*150 + b'</html>') if self.path == '/' or os.environ['CASE'] == 'placeholder' else b'/* actual tracker */' + b'x'*150
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass
host, port = address.split(':')
http.server.HTTPServer((host, int(port)), Handler).serve_forever()
''')
    (binary / 'hitkeep').chmod(0o755)
    harness = temp / 'formula-test.rb'
    harness.write_text('''require 'pathname'
require 'socket'
class Formula
  def self.method_missing(*); end
  def self.test(&block); define_method(:smoke, &block); end
  def testpath; Pathname.new(ENV.fetch('SCRATCH')); end
  def bin; Pathname.new(ENV.fetch('FAKE_BIN')); end
  def free_port
    socket = TCPServer.new('127.0.0.1', 0)
    port = socket.addr[1]
    socket.close
    port
  end
  def assert(value, message = 'assertion failed'); raise message unless value; end
  def assert_equal(expected, actual); assert(expected == actual); end
  def assert_operator(value, operator, expected); assert(value.public_send(operator, expected)); end
  def assert_match(expected, actual); assert(expected.match?(actual)); end
  def refute_match(expected, actual); assert(!expected.match?(actual)); end
  def sleep(_); Kernel.sleep(0.02); end
  def spawn(*args, **options); super(*args, **options.merge(err: ENV.fetch('SMOKE_LOG'))); end
end
load ARGV.fetch(0)
Hitkeep.new.smoke
''')
    for case in ('healthy', 'placeholder', 'unhealthy'):
        scratch = temp / case
        scratch.mkdir()
        marker = scratch / 'pid'
        env = dict(os.environ, CASE=case, PID_MARKER=str(marker), SCRATCH=str(scratch), FAKE_BIN=str(binary), SMOKE_LOG=str(scratch / 'fake.log'))
        result = subprocess.run(['ruby', str(harness), os.environ.get('FORMULA_PATH', str(root / 'Formula/hitkeep.rb'))], env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == (case == 'healthy'), (case, result.stdout, result.stderr, (scratch / 'fake.log').read_text() if (scratch / 'fake.log').exists() else '')
        assert marker.exists(), (case, 'server never started')
        try: os.kill(int(marker.read_text()), 0)
        except ProcessLookupError: pass
        else: raise AssertionError((case, 'child process leaked'))
        print('PASS installed formula smoke:', case, flush=True)
PY
