#!/usr/bin/env bash
set -euo pipefail

publish=false
if [[ "${1:-}" == --publish ]]; then publish=true; shift; fi
if [[ $# != 0 && $# != 3 ]]; then
  echo "usage: $0 [--publish] [vMAJOR.MINOR.PATCH SOURCE_SHA ARCHIVE_SHA256]" >&2
  exit 2
fi
repo=HitKeep/homebrew-hitkeep
source_repo=HitKeep/hitkeep
workflow=.github/workflows/release.yml
fail() { echo "$*" >&2; exit 1; }
[[ "${GITHUB_REPOSITORY:-$repo}" == "$repo" ]] || fail 'unexpected receiver repository'
[[ "${GITHUB_REF:-refs/heads/main}" == refs/heads/main ]] || fail 'receiver must run from main'
# GitHub authorizes dispatch with Actions write; schedule uses the reviewed main workflow.
[[ "${GITHUB_EVENT_NAME:-workflow_dispatch}" == workflow_dispatch || "${GITHUB_EVENT_NAME:-workflow_dispatch}" == schedule ]] || fail 'unexpected receiver event'
root="$(cd "$(dirname "$0")/.." && pwd)"
formula="$root/Formula/hitkeep.rb"
cd "$root"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$formula" "$tmp/original.rb"

# A malformed formula must never become a partial update.
ruby - "$formula" > "$tmp/current" <<'RUBY'
text = File.read(ARGV.fetch(0))
urls = text.scan(/^  url "([^"]+)"$/).flatten
checksums = text.scan(/^  sha256 "([0-9a-f]{64})"$/).flatten
abort 'formula must have exactly one source URL and SHA256' unless urls.size == 1 && checksums.size == 1 && text.scan(/^  url /).size == 1 && text.scan(/^  sha256 /).size == 1
match = urls[0].match(%r{\Ahttps://github\.com/HitKeep/hitkeep/(?:archive/refs/tags/v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\.tar\.gz|releases/download/v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)/hitkeep-source-\4\.\5\.\6\.tar\.gz)\z})
abort 'unrecognized formula source URL' unless match
puts match.captures.compact.join('.'), urls[0], checksums[0]
RUBY

if [[ $# == 0 ]]; then
  tag="$(gh api "repos/$source_repo/releases/latest" --jq .tag_name)"
  source_sha=
  expected_digest=
else
  tag="$1"; source_sha="$2"; expected_digest="$3"
fi
[[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'invalid stable release tag'
if [[ $# == 3 ]]; then
  [[ "$source_sha" =~ ^[0-9a-f]{40}$ && "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || fail 'invalid source SHA or archive digest'
fi
version="${tag#v}"
asset="hitkeep-source-$version.tar.gz"
url="https://github.com/$source_repo/releases/download/$tag/$asset"
gh api "repos/$source_repo" | jq -e '.private == false' >/dev/null
gh api "repos/$source_repo/releases/tags/$tag" > "$tmp/release.json"
jq -e --arg tag "$tag" '.tag_name == $tag and .draft == false and .prerelease == false' "$tmp/release.json" >/dev/null
manifest_id="$(jq -er '[.assets[] | select(.name == "release-candidate.json")] | if length == 1 then .[0].id else error("candidate manifest must be unique") end' "$tmp/release.json")"
gh api "repos/$source_repo/releases/assets/$manifest_id" -H 'Accept: application/octet-stream' > "$tmp/release-candidate.json"
manifest="$tmp/release-candidate.json"
jq -e --arg tag "$tag" '
  . as $manifest |
  (["native", "archives", "tracker", "chart", "docker", "compose", "helm", "docs", "assistant-package", "source-archive"] | all(.[]; $manifest.checks[.] == "success")) and
  .schema_version == 1 and .tag == $tag and (.source_commit | test("^[0-9a-f]{40}$")) and
  (.producer_workflow_sha | test("^[0-9a-f]{40}$")) and
  (.producer_run_id | type == "number" and . > 0 and . == floor) and
  (.producer_run_attempt | type == "number" and . > 0 and . == floor)
' "$manifest" >/dev/null
manifest_source="$(jq -r .source_commit "$manifest")"
[[ -z "$source_sha" || "$source_sha" == "$manifest_source" ]] || fail 'candidate source SHA mismatch'
source_sha="$manifest_source"
digest="$(jq -er --arg name "$asset" '[.artifacts[] | select(.name == $name)] | if length == 1 and .[0].type == "source-archive" and (.[0].sha256 | test("^[0-9a-f]{64}$")) then .[0].sha256 else error("source artifact must have one digest") end' "$manifest")"
[[ -z "$expected_digest" || "$expected_digest" == "$digest" ]] || fail 'candidate archive digest mismatch'
jq -e --arg name "$asset" --arg digest "sha256:$digest" '[.assets[] | select(.name == $name)] | length == 1 and (.[0].digest == $digest)' "$tmp/release.json" >/dev/null
run_id="$(jq -r .producer_run_id "$manifest")"
attempt="$(jq -r .producer_run_attempt "$manifest")"
workflow_sha="$(jq -r .producer_workflow_sha "$manifest")"
gh api "repos/$source_repo/actions/runs/$run_id/attempts/$attempt" > "$tmp/run.json"
jq -e --arg repo "$source_repo" --arg workflow "$workflow" --arg sha "$workflow_sha" --argjson id "$run_id" --argjson attempt "$attempt" '
  .repository.full_name == $repo and .path == $workflow and .id == $id and .run_attempt == $attempt and
  .head_sha == $sha and .head_branch == "main" and (.event == "push" or .event == "workflow_dispatch") and .status == "completed" and .conclusion == "success"
' "$tmp/run.json" >/dev/null
gh attestation verify "$manifest" --repo "$source_repo" --signer-workflow "$source_repo/$workflow" \
  --source-ref refs/heads/main --source-digest "$workflow_sha" --deny-self-hosted-runners --format json > "$tmp/attestation.json"
jq -e --arg invocation "https://github.com/$source_repo/actions/runs/$run_id/attempts/$attempt" \
  'any(.[]; .verificationResult.statement.predicate.runDetails.metadata.invocationId == $invocation)' "$tmp/attestation.json" >/dev/null
check_tag() {
  gh api "repos/$source_repo/git/ref/tags/$tag" > "$tmp/tag.json"
  if [[ "$(jq -r .object.type "$tmp/tag.json")" == tag ]]; then
    gh api "repos/$source_repo/git/tags/$(jq -r .object.sha "$tmp/tag.json")" > "$tmp/tag.json"
  fi
  jq -e --arg sha "$source_sha" '.object.type == "commit" and .object.sha == $sha' "$tmp/tag.json" >/dev/null
}
check_tag
curl --fail --silent --show-error --location --proto '=https' --output "$tmp/source.tar.gz" "$url"
[[ "$(shasum -a 256 "$tmp/source.tar.gz" | awk '{print $1}')" == "$digest" ]] || fail 'downloaded source digest mismatch'
# Inspect archive paths and version without extracting or executing its code.
gh api "repos/$source_repo/git/trees/$source_sha?recursive=1" > "$tmp/tree.json"
ruby - "$tmp/source.tar.gz" "$version" "$tmp/tree.json" "$source_sha" <<'RUBY'
require 'rubygems/package'
require 'zlib'
require 'json'
require 'digest'
tree = JSON.parse(File.read(ARGV.fetch(2)))
abort 'incomplete source tree' unless tree['truncated'] == false
blobs = tree.fetch('tree').select { |entry| entry['type'] == 'blob' }.to_h { |entry| [entry.fetch('path'), entry] }
abort 'unsupported source tree member' if tree.fetch('tree').any? { |entry| !%w[blob tree].include?(entry['type']) || entry['mode'] == '120000' }
version = ARGV.fetch(1)
seen = {}
pax_path = nil
Zlib::GzipReader.open(ARGV.fetch(0)) do |gzip|
  Gem::Package::TarReader.new(gzip) do |tar|
    tar.each do |entry|
      if entry.header.typeflag == 'x'
        abort 'conflicting archive path metadata' if pax_path
        metadata = entry.read
        until metadata.empty?
          length = metadata[/\A[1-9]\d*(?= )/].to_i
          abort 'invalid archive metadata length' unless length.positive? && length <= metadata.bytesize
          record = metadata.slice!(0, length)
          key, value = record[/\A\d+ (.*)\n\z/m, 1]&.split('=', 2)
          if key == 'path' && !pax_path && value
            pax_path = value
          elsif key == 'mtime' && value&.match?(/\A-?\d+(?:\.\d+)?\z/)
            next
          else
            abort 'unsupported archive metadata'
          end
        end
        next
      end
      if entry.header.typeflag == 'g'
        metadata = entry.read
        abort 'invalid source archive commit metadata' unless metadata.match?(%r{\A\d+ comment=#{Regexp.escape(ARGV.fetch(3))}\n\z})
        next
      end
      name = (pax_path || entry.full_name).dup.force_encoding(Encoding::UTF_8)
      abort 'invalid source path encoding' unless name.valid_encoding?
      pax_path = nil
      abort 'unsafe source archive path' unless name.start_with?("hitkeep-#{version}/") && !name.split('/').include?('..') && !name.include?('\\')
      abort 'duplicate or linked source member' if seen.key?(name) || !(entry.file? || entry.directory?)
      seen[name] = entry.file?
      relative = name.delete_prefix("hitkeep-#{version}/")
      overlay = relative.start_with?('public/') && relative.match?(%r{\Apublic/(?:[A-Za-z0-9_@+-][A-Za-z0-9_.@+-]*/)*[A-Za-z0-9_@+-][A-Za-z0-9_.@+-]*/?\z})
      if entry.directory? && !relative.empty?
        directory = relative.delete_suffix('/')
        abort 'unexpected source directory' unless tree.fetch('tree').any? { |item| item['type'] == 'tree' && item['path'] == directory } ||
          directory == 'public' || overlay
      end
      if entry.file?
        data = entry.read || ''
        if blobs.key?(relative) && !overlay
          abort 'source member differs from source commit' unless Digest::SHA1.hexdigest("blob #{data.bytesize}\0" + data) == blobs[relative].fetch('sha')
        else
          abort 'unexpected source member' unless overlay
        end
      end
      if name == "hitkeep-#{version}/frontend/dashboard/package.json"
        abort 'source package version mismatch' unless JSON.parse(data).fetch('version') == version
      end
    end
  end
end
abort 'dangling archive path metadata' if pax_path
(blobs.keys + %w[go.mod go.sum LICENSE cmd/hitkeep/main.go frontend/dashboard/package.json public/index.html]).uniq.each do |name|
  abort "missing source member #{name}" unless seen["hitkeep-#{version}/#{name}"]
end
RUBY

policy() {
  gh api "repos/$repo/branches/main" > "$tmp/branch.json"
  jq -e '.protected == false' "$tmp/branch.json" >/dev/null || fail 'main protection changed; operator action required'
  gh api "repos/$repo/rules/branches/main" > "$tmp/rules.json"
  jq -e 'type == "array" and length == 0' "$tmp/rules.json" >/dev/null || fail 'main rules changed; operator action required'
}
policy
head="$(git rev-parse HEAD)"
[[ "$(jq -r .commit.sha "$tmp/branch.json")" == "$head" ]] || fail 'main changed; rerun against current main'
[[ "$(git ls-remote origin refs/heads/main | awk '{print $1}')" == "$head" ]] || fail 'main changed; rerun against current main'
if $publish; then
  [[ -z "$(git status --porcelain)" ]] || fail 'writer checkout must be clean'
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'release_tag=%s\nsource_sha=%s\narchive_sha256=%s\n' "$tag" "$source_sha" "$digest" >> "$GITHUB_OUTPUT"
fi
cmp -s "$formula" "$tmp/original.rb" || fail 'formula changed during verification'
current="$(sed -n '1p' "$tmp/current")"
disposition="$(ruby -e 'a,b=ARGV.map { |v| v.split(".").map(&:to_i) }; puts((a <=> b).to_s)' "$version" "$current")"
if [[ "$disposition" == -1 ]]; then
  [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "changed=false" >> "$GITHUB_OUTPUT"
  echo "older release skipped: $tag source=$source_sha sha256=$digest"
  exit 0
fi
if [[ "$disposition" == 0 ]]; then
  [[ "$(sed -n '2p' "$tmp/current")" == "$url" && "$(sed -n '3p' "$tmp/current")" == "$digest" ]] || fail 'same version has conflicting immutable source'
  [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "changed=false" >> "$GITHUB_OUTPUT"
  echo "matching release: $tag source=$source_sha sha256=$digest"
  exit 0
fi
awk -v url="$url" -v checksum="$digest" '
  /^  url "/ { print "  url \"" url "\""; next }
  /^  sha256 "/ { print "  sha256 \"" checksum "\""; next }
  { print }
' "$formula" > "$tmp/hitkeep.rb"
ruby -c "$tmp/hitkeep.rb" >/dev/null
check_tag
if $publish; then
  policy
  [[ "$(jq -r .commit.sha "$tmp/branch.json")" == "$head" ]] || fail 'main changed before write'
fi
cmp -s "$formula" "$tmp/original.rb" || fail 'formula changed before write'
chmod 644 "$tmp/hitkeep.rb"
mv "$tmp/hitkeep.rb" "$formula"
if $publish; then
  git diff --check
  [[ "$(git diff --name-only)" == Formula/hitkeep.rb ]] || fail 'unexpected changed path'
  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  git add -- Formula/hitkeep.rb
  [[ "$(git diff --name-only --cached)" == Formula/hitkeep.rb ]] || fail 'unexpected staged path'
  git commit -m "chore: update HitKeep to $version"
  gh auth setup-git
  git push origin HEAD:refs/heads/main
  written="$(git rev-parse HEAD)"
  [[ "$(git ls-remote origin refs/heads/main | awk '{print $1}')" == "$written" ]] || fail 'formula main readback mismatch'
fi
[[ -z "${GITHUB_OUTPUT:-}" ]] || echo "changed=true" >> "$GITHUB_OUTPUT"
echo "formula updated: $tag source=$source_sha sha256=$digest url=$url output_ref=refs/heads/main output_commit=${written:-verification-only}"
