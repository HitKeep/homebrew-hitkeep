#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import os, pathlib, signal, subprocess, tempfile
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
            if response.status == 200 and os.environ['CASE'] == 'late':
                pathlib.Path(os.environ['SCRATCH'], 'late-response').touch()
            sys.exit(0 if response.status == 200 else 1)
    except Exception: sys.exit(1)
pathlib.Path(os.environ['PID_MARKER']).write_text(str(os.getpid()))
if os.environ['CASE'] == 'exited': sys.exit(17)
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
# Advance the clock inside the last successful probe to exercise the cutoff.
module FixtureClock
  def clock_gettime(clock, *units)
    value = super
    return value unless clock == Process::CLOCK_MONOTONIC && units.empty?
    return value * 20 if ENV['CASE'] == 'unhealthy'
    return value + 91 if ENV['CASE'] == 'late' && File.exist?(File.join(ENV.fetch('SCRATCH'), 'late-response'))
    value
  end
end
Process.singleton_class.prepend(FixtureClock)
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
  def system(*args)
    raise TypeError, 'Formula#system does not accept redirection options' if args.any? { |arg| arg.is_a?(Hash) }
    raise 'Formula#system command failed' unless Kernel.system(*args)
  end
  def quiet_system(*args)
    # The delayed fixture needs 32 failed probes, independent of interpreter startup time.
    if ENV['CASE'] == 'delayed'
      @probes = @probes.to_i + 1
      return false if @probes <= 32
    end
    Kernel.system(*args, out: File::NULL, err: File::NULL)
  end
  def assert(value, message = 'assertion failed'); raise message unless value; end
  def flunk(message); raise message; end
  def assert_equal(expected, actual); assert(expected == actual); end
  def assert_operator(value, operator, expected, *message); assert(value.public_send(operator, expected), *message); end
  def assert_match(expected, actual); assert(expected.match?(actual)); end
  def refute_match(expected, actual); assert(!expected.match?(actual)); end
  def sleep(_); Kernel.sleep(0.02); end
  def spawn(*args, **options); super(*args, **options.merge(err: ENV.fetch('SMOKE_LOG'))); end
end
load ARGV.fetch(0)
Hitkeep.new.smoke
''')
    for case in ('healthy', 'delayed', 'late', 'placeholder', 'unhealthy', 'exited'):
        scratch = temp / case
        scratch.mkdir()
        marker = scratch / 'pid'
        env = dict(os.environ, CASE=case, PID_MARKER=str(marker), SCRATCH=str(scratch), FAKE_BIN=str(binary), SMOKE_LOG=str(scratch / 'fake.log'))
        cmd = ['ruby', str(harness), os.environ.get('FORMULA_PATH', str(root / 'Formula/hitkeep.rb'))]
        with subprocess.Popen(cmd, env=env, start_new_session=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as proc:
            try:
                stdout, stderr = proc.communicate(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()
                raise
        assert (proc.returncode == 0) == (case in ('healthy', 'delayed')), (case, stdout, stderr, (scratch / 'fake.log').read_text() if (scratch / 'fake.log').exists() else '')
        if case == 'late': assert (scratch / 'late-response').exists()
        if case in ('late', 'unhealthy'): assert 'did not become healthy' in stderr
        if case == 'exited': assert 'exit 17' in stderr
        assert marker.exists(), (case, 'server never started')
        try: os.kill(int(marker.read_text()), 0)
        except ProcessLookupError: pass
        else: raise AssertionError((case, 'child process leaked'))
        print('PASS installed formula smoke:', case, flush=True)
PY
