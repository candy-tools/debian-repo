# debian-repo — developer manual

How this APT repository works, how to set it up from scratch, and how to operate
it as a maintainer. For end-user install instructions see `README.md`.

- **URL:** https://candy-tools.github.io/debian-repo
- **Suite / component:** `stable` / `main` · **Architectures:** `amd64`, `arm64`

## How it works

This repository holds no build code. It is an **instance** of the
[gh-action-debian-repo](https://github.com/andresbott/gh-action-debian-repo)
engine in *collection mode*: the tools are its clients and push their package
references here, and this repository builds, signs and deploys itself. The
engine's docs cover the details: [collection mode](https://github.com/andresbott/gh-action-debian-repo/blob/main/docs/collection-mode.md)
and the [reference](https://github.com/andresbott/gh-action-debian-repo/blob/main/docs/reference.md).

The git tree **never stores release binaries**, only *references*. A package
enters the repo in one of two ways:

1. **Automated (per-app JSON).** Each app owns one file, `packages/<app>.json`,
   holding its current version and a checksummed URL per architecture. The app's
   release workflow writes and pushes that file by calling the engine's reusable
   workflow, authenticated as the `candy-tools-apt` GitHub App. Because every app
   owns a separate file, two releases never conflict.
2. **Manual (committed binary).** `make add DEB=foo.deb` stages a `.deb` into the
   git-tracked `debs/` folder; you commit it and it's hosted directly.

On every push to `main` that touches `packages/`, `debs/` or `conf/`,
`.github/workflows/publish.yml` makes a publish-only call to the engine, which
**rebuilds the whole repo**: validate → download + verify every `packages/*.json`
and merge `debs/` → sign → deploy to Pages. The full set is reconstructed each
run, so nothing clobbers anything, and a failed download aborts the publish (the
previous deployment stays live) rather than shipping a partial index.

## Setup

First-time setup, from a fresh clone to a live repository. Steps 1–5 are one-time
for this repo; the next section is repeated per tool you want to publish.

**Prerequisites:** `gpg`, `make`, `git`, and the `gh` CLI authenticated with
admin rights on `candy-tools/debian-repo` (`gh auth status`). Local builds also
need `apt-utils` (provides `apt-ftparchive`), `jq`, `curl`, and `check-jsonschema`
or `uvx`. The Makefile fetches the engine by itself.

**1 — Generate the repository signing key** (one-time):

```bash
make key KEY_NAME="candy-tools APT repository" KEY_EMAIL=contact@andresbott.com
make backup-key
```

Creates an RSA-4096 signing key without a passphrase in the git-ignored
`.gnupg-repo/`, and writes a private-key backup, `.gnupg-repo/signing-key.secret.asc`,
for you to move into your vault (see [Backup and recovery](#backup-and-recovery)).

**2 — Enable GitHub Pages** and limit the `github-pages` environment to
deployments from `main` (`TAGS=`: this repository never deploys from a tag):

```bash
make setup-repo REPO=candy-tools/debian-repo TAGS=
```

**3 — Store the private key as a CI secret.** Signing runs in CI, so it needs the
private key as the `APT_SIGNING_KEY` secret of the `github-pages` environment,
where only the deploying job can read it. This prints the fingerprint and uid of
every key it is about to upload:

```bash
make key-to-repo REPO=candy-tools/debian-repo
```

**4 — Create the GitHub App** the tools push with:

- Create it **under the org**: https://github.com/organizations/candy-tools/settings/apps/new
  (a personal account's *Developer settings* would create it under that account).
  Name it `candy-tools-apt`; any homepage URL; untick **Webhook → Active**.
- **Repository permissions → Contents: Read and write** (Metadata: read-only is
  added automatically). **Where can this GitHub App be installed → Only on this
  account.**
- Create it, note its **App ID**, then **Generate a private key** (a `.pem` downloads).
- **Install App** → `candy-tools` → **Only select repositories** → `debian-repo`.
- Store the ID and key for the tools, then move the `.pem` into your vault and
  shred it:

```bash
REPOS=dibs,go-deps-view,govi,linux-candy-scripts,todo
gh variable set APT_APP_ID --org candy-tools --visibility selected --repos "$REPOS" --body <APP_ID>
gh secret set APT_APP_PRIVATE_KEY --org candy-tools --visibility selected --repos "$REPOS" < key.pem
shred -u key.pem
```

Each release mints a short-lived token from it, scoped to `debian-repo` only.

**5 — First publish.** Trigger the workflow by hand:

```bash
gh workflow run publish.yml --repo candy-tools/debian-repo
gh run watch --repo candy-tools/debian-repo
```

On success the repo is live at the URL above. With no packages yet it publishes a
valid, empty, signed index — users can already add the repo.

## Wiring a tool to publish itself

Per app:

1. **Allow it here.** Add its package to [`conf/owners.conf`](conf/owners.conf)
   (`<package>  candy-tools/<app>`) and push. Until then, its register step is
   rejected.
2. **Give it the App credentials.** Add the app's repository to the *Repository
   access* list of both the `APT_APP_ID` variable and the `APT_APP_PRIVATE_KEY`
   secret: `candy-tools` org → **Settings → Secrets and variables → Actions**.
3. **Call the engine from its release workflow.** Upload the built `.deb` files
   as an artifact at the end of the job that builds them and creates the release
   (goreleaser, nfpm, …), then add a job that registers them here:

```yaml
      # last step of the release job, after the release and its assets exist
      - uses: actions/upload-artifact@v4
        with:
          name: debs
          path: dist/*.deb          # only the .debs: flat = every release
          if-no-files-found: error

  apt:
    needs: release
    permissions:
      contents: read
    uses: andresbott/gh-action-debian-repo/.github/workflows/publish.yml@v1.0.0-rc.2
    with:
      name: go-deps-view            # must match the .deb's Package field
      artifact: debs
      collection: candy-tools/debian-repo
      app-id: ${{ vars.APT_APP_ID }}
    secrets:
      app-private-key: ${{ secrets.APT_APP_PRIVATE_KEY }}
```

On the tool's next release that job writes `packages/<name>.json` here and pushes
it, which triggers a publish. Before pushing, it checks the reference against
`conf/` (releases, architectures, `owners.conf`, no duplicate package) and
downloads every release asset to compare its sha256, so a broken reference never
reaches this repository.

## Adding packages manually

For a one-off or a tool without a public release, add the `.deb` directly:

```bash
make add DEB=path/to/foo_1.0.0_amd64.deb   # copies it into debs/
git add debs/ && git commit -m "add foo 1.0.0" && git push
```

The binary is committed to git and merged into the pool alongside the
JSON-hydrated ones on the next publish. Manually committed `.deb`s are not
subject to `owners.conf`.

To write a reference by hand instead (e.g. to register a release whose own
workflow failed to), download its `.deb`s and run `make register`:

```bash
gh release download v1.3.0 -R candy-tools/go-deps-view -p '*.deb' -D /tmp/dist
make register NAME=go-deps-view REPO=candy-tools/go-deps-view TAG=v1.3.0 DIST=/tmp/dist
git add packages/go-deps-view.json && git commit -m "go-deps-view 1.3.0" && git push
```

## Configuration

| File | Holds |
| --- | --- |
| [`conf/dists.conf`](conf/dists.conf) | the suites and architectures: a single `stable` suite, `amd64 arm64` |
| [`conf/site.conf`](conf/site.conf) | the identity (`REPO_NAME`, pinned) and the landing page theme |
| [`conf/owners.conf`](conf/owners.conf) | which repository may publish which package |

`REPO_NAME` and `DISTS` are pinned to what the repository was first published
with: changing the Release file's `Origin`, `Label`, `Suite` or `Codename` makes
every client's `apt update` refuse the repository until it is run with
`--allow-releaseinfo-change`.

`packages/*.json` must validate against the engine's
[schema](https://github.com/andresbott/gh-action-debian-repo/blob/main/schema/package.schema.json):

```json
{
  "name": "go-deps-view",
  "version": "1.3.0",
  "artifacts": [
    { "release": "any", "arch": "amd64", "url": "https://github.com/candy-tools/go-deps-view/releases/download/v1.3.0/go-deps-view_1.3.0_linux_amd64.deb", "sha256": "<64 hex>" },
    { "release": "any", "arch": "arm64", "url": "https://github.com/candy-tools/go-deps-view/releases/download/v1.3.0/go-deps-view_1.3.0_linux_arm64.deb", "sha256": "<64 hex>" }
  ]
}
```

At publish time each download is checked against `sha256`, and the `.deb`'s own
`Package`/`Version`/`Architecture` must match `name`/`version`/`arch` — otherwise
the build fails and the previous deployment stays live.

## Local development

`make help` lists every target. The Makefile clones the engine at `ENGINE_REF`
into the git-ignored `.engine/` on first use, so local builds run the version CI
does. When bumping the engine, change `ENGINE_REF` in the Makefile and the
`uses:` ref in `.github/workflows/publish.yml` together. To run your own engine
checkout instead, pass `ENGINE_DIR=../gh-action-debian-repo`.

To reproduce the exact CI publish locally (signs with the key in `.gnupg-repo/`):

```bash
make publish       # validate -> hydrate (download+verify) -> build + sign  ->  _site/
make verify-site   # check every suite as apt would, and that pooled debs parse
make serve         # serve _site/ at http://localhost:8000 to test with apt
```

| Target | Description |
| --- | --- |
| `make publish` | full local rebuild: `validate` + `hydrate` + `build` |
| `make validate` | check the config and every `packages/*.json` against the schema |
| `make hydrate` | download + verify referenced debs and merge `debs/` into `_site/pool` |
| `make build` | generate + sign the index in `_site/` |
| `make add DEB=…` | stage a local `.deb` into `debs/` for manual hosting |
| `make register NAME=… REPO=… TAG=…` | write a `packages/<name>.json` locally |
| `make serve` / `make verify-site` / `make clean` | test locally / sanity-check / clean |
| `make key` / `make backup-key` / `make key-info` / `make key-to-repo` | signing-key management |

## Signing

The private signing key lives only in the git-ignored `.gnupg-repo/` locally and in
the `APT_SIGNING_KEY` secret of the `github-pages` environment — never in the
tree. The public keyring users download (`candy-tools-archive-keyring.gpg`, plus
an armored `.asc`) is exported from the signing key at every publish. The key has
no passphrase (for unattended signing); its sole capability is signing this
public repo's index. To replace it without breaking clients, follow the engine's
[key rotation](https://github.com/andresbott/gh-action-debian-repo/blob/main/docs/reference.md#rotating-a-key).

### Backup and recovery

The private key is the only irreplaceable secret in this repo, so keep an offline
copy. `make backup-key` writes **`.gnupg-repo/signing-key.secret.asc`**, an
armored export of the passphrase-less private key, inside the git-ignored keyring
directory. Move that file into your password vault and shred the local copy —
anyone holding it can sign as this repo:

```bash
make backup-key      # (re)writes .gnupg-repo/signing-key.secret.asc
shred -u .gnupg-repo/signing-key.secret.asc   # once it is in the vault
```

`.gnupg-repo/` itself holds the key in GnuPG's database format under
`private-keys-v1.d/` — there is no `.asc` inside it, which is why the export exists.
To restore onto a fresh machine, recreate the home dir, import the key, and
refresh the CI secret:

```bash
mkdir -p .gnupg-repo && chmod 700 .gnupg-repo
GNUPGHOME=.gnupg-repo gpg --import signing-key.secret.asc
make key-to-repo REPO=candy-tools/debian-repo
```

Backing up the whole `.gnupg-repo/` directory works too and additionally preserves
the revocation certificate (`openpgp-revocs.d/`). Nothing else needs backing up:
the App's private key is regenerable from its settings page.

## Layout

```
packages/<app>.json        # per-app reference (machine-modifiable; app owns its file)
debs/                      # manually-added, committed .deb binaries
conf/                      # dists.conf, site.conf, owners.conf (engine config)
.github/workflows/         # publish.yml — publish-only call to the engine on push to main
Makefile                   # local builds: fetches the engine into .engine/ and includes it
_site/                     # built site (git-ignored) — what CI uploads to Pages
```
