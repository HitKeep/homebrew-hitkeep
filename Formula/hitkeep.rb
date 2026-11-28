class Hitkeep < Formula
  desc "Privacy-friendly, self-hosted web analytics"
  homepage "https://hitkeep.com"
  url "https://github.com/HitKeep/hitkeep/releases/download/v2.19.0/hitkeep-source-2.19.0.tar.gz"
  sha256 "84f2fbf89a4065f448cb69f50dda326c1dcd49af53957cff29ebef4dd381e031"
  license "MIT"

  depends_on "go" => :build

  def install
    ENV["CGO_ENABLED"] = "1"
    ENV["GOTOOLCHAIN"] = "auto"
    ldflags = "-X hitkeep/cmd.Version=#{version}"
    system "go", "build", *std_go_args(ldflags: ldflags),
           "-tags", "hashicorpmetrics,timetzdata", "./cmd/hitkeep/main.go"
  end

  test do
    require "net/http"
    require "securerandom"
    require "timeout"

    address = "127.0.0.1:#{free_port}"
    ENV["HITKEEP_HTTP_ADDR"] = address
    ENV["HITKEEP_PUBLIC_URL"] = "http://#{address}"
    ENV["HITKEEP_DB_PATH"] = (testpath/"hitkeep.db").to_s
    ENV["HITKEEP_DATA_PATH"] = (testpath/"data").to_s
    ENV["HITKEEP_ARCHIVE_PATH"] = (testpath/"archive").to_s
    ENV["HITKEEP_BIND_ADDR"] = "127.0.0.1:#{free_port}"
    ENV["HITKEEP_NSQ_TCP_ADDRESS"] = "127.0.0.1:#{free_port}"
    ENV["HITKEEP_NSQ_HTTP_ADDRESS"] = "127.0.0.1:#{free_port}"
    ENV["HITKEEP_JWT_SECRET"] = SecureRandom.hex(32)
    ENV["HITKEEP_MAIL_DRIVER"] = "log"
    ENV["HITKEEP_SPAM_FILTER_AUTO_UPDATE"] = "false"

    pid = spawn (bin/"hitkeep").to_s, chdir: testpath.to_s, out: File::NULL, err: File::NULL
    begin
      # A fresh DuckDB can still be migrating after 30 probes on Linux AMD64.
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      loop do
        if (exited = Process.waitpid2(pid, Process::WNOHANG))
          pid = nil
          flunk "installed HitKeep exited before becoming healthy: #{exited.last}"
        end
        healthy = quiet_system((bin/"hitkeep").to_s, "-healthcheck")
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        assert_operator elapsed, :<, 90, "installed HitKeep did not become healthy"
        if healthy
          puts format("HitKeep became healthy after %.1fs", elapsed)
          break
        end
        sleep 1
      end
      %w[/ /hk.js /hk-vitals.js].each do |path|
        response = Net::HTTP.get_response(URI("http://#{address}#{path}"))
        assert_equal "200", response.code
        assert_operator response.body.bytesize, :>, 100
        if path == "/"
          assert_match(/<html/i, response.body)
        else
          refute_match(/<!doctype|<html/i, response.body)
        end
      end
    ensure
      begin
        if pid
          Process.kill("TERM", pid)
          Timeout.timeout(10) { Process.wait(pid) }
        end
      rescue Timeout::Error
        Process.kill("KILL", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end
end
