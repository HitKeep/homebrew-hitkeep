# HitKeep Homebrew tap

```sh
brew install HitKeep/hitkeep/hitkeep
```

Use `brew upgrade hitkeep` to update and `brew uninstall hitkeep` to remove it.

Existing installations can keep the `PascaleBeier/hitkeep` tap name and use the
organization repository directly, without reinstalling HitKeep:

```sh
brew tap --custom-remote PascaleBeier/hitkeep https://github.com/HitKeep/homebrew-hitkeep
brew update
brew upgrade PascaleBeier/hitkeep/hitkeep
```

The old GitHub repository URL also redirects after the transfer. Keep the old tap
while it owns an installed formula; `brew untap --force` can uninstall it.

Formula updates use the app's public stable release and signed
`release-candidate.json`, including its exact producer run/attempt, source commit,
and source archive digest. The archive keeps the complete source tree and exact
Go source, with only verified browser assets overlaid under `public/`. The source URL is
`https://github.com/HitKeep/hitkeep/releases/download/vX.Y.Z/hitkeep-source-X.Y.Z.tar.gz`.
A read-only job checks the candidate and installs the source on macOS before a
separate repository-scoped writer can fast-forward `Formula/hitkeep.rb` on main.
The receiver refuses changed main protection or branch rules; it never forces a
push or bypasses reviews.

For recovery, rerun the failed native **Update formula** job or dispatch that
workflow on main with all three exact inputs: `release_tag`, `source_sha`, and
`archive_sha256`. Leave all three empty for the same latest-release reconciliation
used by the schedule. Matching URL/digest retries are no-ops, older releases cannot
downgrade the formula, and conflicting bytes for the same version stop the run.
If another update wins a race, rerun against current main to revalidate its state.
After a push that lost its completion response, a native rerun keeps its original
workflow tooling and reads current main’s formula as data. A matching formula
creates no new commit; a newer version is preserved. Updates preserve unrelated
main changes and refuse changed formula build logic until a fresh reviewed
workflow is dispatched.

The app's existing `channel` recovery handles candidate run/attempt selection and
reruns dependent delivery jobs. For a receiver-only failure, rerun this workflow;
expired candidate evidence or an authorization/protection failure requires an
operator to resolve that explicit blocker before retrying. A successful app
release does not by itself prove a successful tap update. Backports leave a newer
tap version unchanged. No checksum is derived afresh from a mutable tag archive.

Run `./tests/test-update-formula.sh` for executable rejection, fast-forward race,
and retry fixtures. The workflow also checks Ruby syntax, audits the generated
formula, and builds/tests the verified source with Homebrew; these checks require
the public candidate assets to exist.
