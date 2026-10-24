class Hitkeep < Formula
  desc "Privacy-friendly, self-hosted web analytics"
  homepage "https://hitkeep.com"
  url "https://github.com/HitKeep/hitkeep/archive/refs/tags/v2.14.2.tar.gz"
  sha256 "7d53bc410845063d60e733e00bfde19b2e629c4b742171d46b63b9d067a7b469"
  license "MIT"

  depends_on "go" => :build

  def install
    ENV["CGO_ENABLED"] = "1"
    ENV["GOTOOLCHAIN"] = "auto"
    ldflags = "-X hitkeep/cmd.Version=#{version}"
    system "go", "build", *std_go_args(ldflags:),
           "-tags", "hashicorpmetrics,timetzdata", "./cmd/hitkeep/main.go"
  end

  test do
    output = shell_output("#{bin}/hitkeep -healthcheck -http-addr=127.0.0.1:0 2>&1", 1)
    assert_match "Healthcheck failed", output
  end
end
