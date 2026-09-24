# Packaging & releases

How a release is cut and how the package managers are updated from it.

## 1. Cut a release

Tag and push:

```sh
git tag v0.1.0
git push origin v0.1.0
```

`.github/workflows/release.yml` then builds and attaches to the GitHub Release:

| Artifact | Contents |
| --- | --- |
| `mediastacks-macos-arm64.tar.gz` | `medias` + `biblio` (Apple Silicon) |
| `mediastacks-macos-x86_64.tar.gz` | `medias` + `biblio` (Intel) |
| `mediastacks-linux-x86_64.tar.gz` | `medias` + `biblio` |
| `mediastacks-windows-x86_64.zip` | `medias.exe` (biblio is POSIX-only) |

Each ships a matching `.sha256`. These are what `scripts/install.sh`, the
Homebrew formula, and the Chocolatey package consume.

## 2. Homebrew (macOS / Linux)

One-time setup — create a **tap** repo named `homebrew-mediastacks` under your
GitHub account and add the formula:

```sh
# in the homebrew-mediastacks repo
mkdir -p Formula
cp path/to/mediastacks/packaging/homebrew/mediastacks.rb Formula/
```

After each release, fill the version + checksums and copy the formula into the tap:

```sh
# from this repo, with the release artifacts downloaded to ./dist
packaging/homebrew/update-formula.sh 0.1.0 ./dist
cp packaging/homebrew/mediastacks.rb ../homebrew-mediastacks/Formula/mediastacks.rb
( cd ../homebrew-mediastacks && git commit -am "mediastacks 0.1.0" && git push )
```

Users then:

```sh
brew install markussagen/mediastacks/mediastacks
```

> Note: `brew audit --strict` wants a `license` stanza — add one once the repo
> has a LICENSE file.

## 3. Chocolatey (Windows)

One-time: create a [chocolatey.org](https://community.chocolatey.org) account and
get an API key.

After each release (needs the `mediastacks-windows-x86_64.zip.sha256` in `./dist`):

```sh
packaging/chocolatey/update-package.sh 0.1.0 ./dist   # fills version + checksum
```

Then on a Windows machine with Chocolatey installed:

```powershell
choco pack packaging\chocolatey\mediastacks.nuspec
choco push mediastacks.0.1.0.nupkg --source https://push.chocolatey.org/ --api-key $env:CHOCO_API_KEY
```

Users then:

```powershell
choco install mediastacks
```

## Automating this in CI (optional)

The release build already produces every artifact. To auto-publish, add jobs
that run the two `update-*` scripts against the release artifacts and push:

- **Homebrew** — clone your `homebrew-mediastacks` tap with a
  `HOMEBREW_TAP_TOKEN` secret, run `update-formula.sh`, copy the formula in, and
  commit.
- **Chocolatey** — on a `windows-latest` runner, run `update-package.sh`,
  `choco pack`, then `choco push` with a `CHOCO_API_KEY` secret.

These are left out of `release.yml` by default because they require external
repos/accounts and secrets; wire them once those exist.
