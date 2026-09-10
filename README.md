# debian-repo

A static, GPG-signed **APT repository** for the [candy-tools](https://github.com/candy-tools),
served over HTTPS from **GitHub Pages** — the Debian/Ubuntu counterpart to the
[`homebrew-tap`](https://github.com/candy-tools/homebrew-tap). Add it once and
install the candy-tools with `apt` like any other package.

- **URL:** https://candy-tools.github.io/debian-repo
- **Suite / component:** `stable` / `main` · **Architectures:** `amd64`, `arm64`

## Install

Trust the repository's signing key and add the source:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL https://candy-tools.github.io/debian-repo/candy-tools-archive-keyring.gpg \
  -o /etc/apt/keyrings/candy-tools-archive-keyring.gpg
sudo curl -fsSL https://candy-tools.github.io/debian-repo/candy-tools.sources \
  -o /etc/apt/sources.list.d/candy-tools.sources
sudo apt update
```

Then install any candy-tool by name, for example:

```bash
sudo apt install go-deps-view
```

## Update

The tools update through `apt` along with the rest of your system:

```bash
sudo apt update && sudo apt upgrade
```

## Remove the repository

```bash
sudo rm -f /etc/apt/sources.list.d/candy-tools.sources \
           /etc/apt/keyrings/candy-tools-archive-keyring.gpg
sudo apt update
```
