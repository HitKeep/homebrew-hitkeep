class Hitkeep < Formula
  desc "Privacy-friendly, self-hosted web analytics"
  homepage "https://hitkeep.com"
  url "https://github.com/HitKeep/hitkeep/archive/refs/tags/v2.15.0.tar.gz"
  sha256 "b634119d19a7ce0628326064917c8618262e2edf097b0bdfa0d19212c0a9fa05"
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
    output = shell_output("#{bin}/hitkeep -healthcheck -http-addr=127.0.0.1:0 2>&1", 1)
    assert_match "Healthcheck failed", output
  end
end
