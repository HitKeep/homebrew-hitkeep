class Hitkeep < Formula
  desc "Privacy-friendly, self-hosted web analytics"
  homepage "https://hitkeep.com"
  url "https://github.com/HitKeep/hitkeep/releases/download/v2.15.1/hitkeep-source-2.15.1.tar.gz"
  sha256 "559fdc157078391df453fa980d5328d92f41c608e7ff11f894bd401f937268b1"
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
      healthy = false
      30.times do
        if quiet_system((bin/"hitkeep").to_s, "-healthcheck")
          healthy = true
          break
        end
        sleep 1
      end
      assert healthy, "installed HitKeep did not become healthy"
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
        Process.kill("TERM", pid)
        Timeout.timeout(10) { Process.wait(pid) }
      rescue Timeout::Error
        Process.kill("KILL", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end
end
