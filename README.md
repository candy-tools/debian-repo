# debian-repo

A static, GPG-signed **APT repository** for the [candy-tools](https://github.com/candy-tools),
served over HTTPS from **GitHub Pages** — the Debian/Ubuntu counterpart to the
[`homebrew-tap`](https://github.com/candy-tools/homebrew-tap).

- **URL:** https://candy-tools.github.io/debian-repo
- **Suite / component:** `stable` / `main` · **Architectures:** `amd64`, `arm64`

## Install (users)

```bash
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL https://candy-tools.github.io/debian-repo/candy-tools-archive-keyring.gpg \
  -o /etc/apt/keyrings/candy-tools-archive-keyring.gpg
sudo curl -fsSL https://candy-tools.github.io/debian-repo/candy-tools.sources \
  -o /etc/apt/sources.list.d/candy-tools.sources
sudo apt update && sudo apt install go-deps-view
```

## How it works

The repo's **git tree never stores binaries**. It stores *references*; the binaries
are downloaded and the index is built + signed **in CI**, then published to Pages.
Two ways a package enters the repo:

1. **Automated (per-app JSON).** Each app owns one file, `packages/<app>.json`,
   holding its current version and a checksummed URL per architecture. The app's
   own release CI writes/commits that file (see below). Because every app owns a
   separate file, two releases never conflict.
2. **Manual (committed binary).** `make add DEB=foo.deb` stages a `.deb` into the
   git-tracked `debs/` folder; you commit it and it's hosted directly.

On every push to `main`, `.github/workflows/publish.yml` **rebuilds the whole repo**
— validate → download+verify all `packages/*.json` and merge `debs/` → sign → deploy.
The full set is reconstructed each run, so nothing clobbers anything.

### Package reference schema

`packages/*.json` must validate against [`schema/package.schema.json`](schema/package.schema.json):

```json
{
  "name": "go-deps-view",
  "version": "1.3.0",
  "homepage": "https://github.com/candy-tools/go-deps-view",
  "description": "Browser viewer for a Go module's dependency graph",
  "artifacts": [
    { "arch": "amd64", "url": "https://github.com/candy-tools/go-deps-view/releases/download/v1.3.0/go-deps-view_1.3.0_amd64.deb", "sha256": "<64 hex>" },
    { "arch": "arm64", "url": "https://github.com/candy-tools/go-deps-view/releases/download/v1.3.0/go-deps-view_1.3.0_arm64.deb", "sha256": "<64 hex>" }
  ]
}
```

At publish time the download is checked against `sha256`, and the `.deb`'s own
`Package`/`Version`/`Architecture` must match `name`/`version`/`arch` — otherwise
the build fails and the previous deployment stays live.

## Maintainer commands

`make help` lists everything. Local dry-run of the exact CI publish:

```bash
make key         # one-time: create the signing key + export the public key
make publish     # validate -> hydrate (download+verify) -> build + sign  ->  _site/
make serve       # serve _site/ at http://localhost:8000 to test with apt
make verify      # check the built signature + that pooled debs parse
```

| Target | Description |
| --- | --- |
| `make publish` | full local rebuild: `validate` + `hydrate` + `build` |
| `make validate` | check every `packages/*.json` against the schema |
| `make hydrate` | download + verify referenced debs and merge `debs/` into `_site/pool` |
| `make build` | generate + sign the index in `_site/` |
| `make add DEB=…` | stage a local `.deb` into `debs/` for manual hosting |
| `make serve` / `make verify` / `make clean` | test locally / sanity-check / clean |
| `make key` / `make export-key` / `make key-info` | signing-key management |

## CI setup

**This repo — `APT_SIGNING_KEY` secret.** Signing happens in CI, so store the
private key (export it without printing it to your terminal):

```bash
GNUPGHOME=.gnupg-repo gpg --export-secret-keys --armor contact@andresbott.com \
  | gh secret set APT_SIGNING_KEY --repo candy-tools/debian-repo
```

**GitHub Pages.** Settings → Pages → Source = **GitHub Actions**.

**Each tool repo — `DEBIAN_REPO_TOKEN` secret** (a fine-grained PAT scoped to
`candy-tools/debian-repo` with **Contents: read and write**). Add one step to the
tool's release workflow, after goreleaser has produced `dist/*.deb`:

```yaml
      - uses: candy-tools/debian-repo/.github/actions/register@main
        with:
          name: go-deps-view          # must match the .deb's Package field
          dist-dir: dist              # where goreleaser wrote the .deb files
          token: ${{ secrets.DEBIAN_REPO_TOKEN }}
```

That [composite action](.github/actions/register/action.yml) runs this repo's own
[`scripts/register.sh`](scripts/register.sh): it builds `packages/go-deps-view.json`
(per-arch URL + sha256 from the built debs), validates it against the schema, and
commits + pushes it (rebase-retry). Keeping the logic here means a schema change is
made once, not in every app. Inputs: `name` and `token` (required); `dist-dir`
(default `dist`), `tag` (default the release ref), `source-repo` (default the
calling repo), `repo` (default `candy-tools/debian-repo`). Pin `@v1` instead of
`@main` to insulate apps from format changes.

To generate a reference by hand (testing), `scripts/register.sh` is also wired to
`make register NAME=… REPO=owner/app TAG=vX.Y.Z [DIST=dist]`.

## Signing

The private signing key lives only in the git-ignored `.gnupg-repo/` locally and
in the `APT_SIGNING_KEY` CI secret — never in the tree. Only the public
`candy-tools-archive-keyring.gpg` is committed and published. It has no passphrase
(for unattended signing); its sole capability is signing this public repo's index.
If lost/compromised, regenerate with `make key` and republish the public key.

## Layout

```
packages/<app>.json   # per-app reference (machine-modifiable; app owns its file)
debs/                 # manually-added, committed .deb binaries
schema/               # JSON Schema for packages/*.json
conf/                 # apt-ftparchive Release settings
scripts/              # register (app -> JSON) + hydrate + index-generation
.github/actions/register/  # composite action apps call to register a release
_site/                # built site (git-ignored) — what CI uploads to Pages
```
