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
