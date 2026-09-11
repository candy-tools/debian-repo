#!/usr/bin/env bash
# Generate and GPG-sign the APT index for <site> from its hydrated pool, then
# stage the static site files (public key, sources, .nojekyll) and render the
# landing page with the pool's package listing injected into its Packages tab.
# Usage: gen-index.sh <site> <apt-ftparchive-conf> <key-email> [arch...]
# GNUPGHOME must point at the keyring holding the signing key (set by the Makefile).
set -euo pipefail

SITE="${1:-_site}"
CONF="${2:?apt-ftparchive conf path (relative to repo root)}"
KEY_EMAIL="${3:?signing key email}"
shift 3
ARCHES=("$@")
[ ${#ARCHES[@]} -gt 0 ] || ARCHES=(amd64 arm64)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF_ABS="$ROOT/$CONF"

# render_index <site>: render the landing page into <site>/index.html from the
# index.html template — inject the packages table (built from the generated
# binary-*/Packages indexes), substitute the @@TOKENS@@ from conf/site.conf, and
# apply the selected colour theme (conf/themes/<name>.css). THEME may be
# overridden from the environment (e.g. the Makefile's `make build THEME=teal`).
render_index() {
  local site="$1" rows body content theme_css tf gh arches_html a n i
  # extract one TSV line per stanza, dedup identical artifacts (e.g. arch:all
  # debs listed under every architecture), then format each into a table row.
  rows="$(
    awk '
      function emit(){ if (fn!="") print pkg"\t"ver"\t"arch"\t"size"\t"fn"\t"desc;
                       pkg=ver=arch=size=fn=desc="" }
      /^Package:/      { v=$0; sub(/^Package:[ \t]*/,"",v);      pkg=v }
      /^Version:/      { v=$0; sub(/^Version:[ \t]*/,"",v);      ver=v }
      /^Architecture:/ { v=$0; sub(/^Architecture:[ \t]*/,"",v); arch=v }
      /^Size:/         { v=$0; sub(/^Size:[ \t]*/,"",v);         size=v }
      /^Filename:/     { v=$0; sub(/^Filename:[ \t]*/,"",v);     fn=v }
      /^Description:/  { v=$0; sub(/^Description:[ \t]*/,"",v);  desc=v }
      /^[[:space:]]*$/ { emit() }
      END              { emit() }
    ' "$site"/dists/stable/main/binary-*/Packages | sort -u | awk -F'\t' '
      function esc(s){ gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); return s }
      function hsize(b){ if (b+0>=1048576) return sprintf("%.1f MB",b/1048576);
                         else if (b+0>=1024) return sprintf("%.0f KB",b/1024);
                         else return b" B" }
      { printf "            <tr><td><code>%s</code></td><td>%s</td><td><code>%s</code></td><td class=\"num\">%s</td><td class=\"desc\">%s</td><td><a href=\"%s\">download</a></td></tr>\n", \
               esc($1), esc($2), esc($3), hsize($4), esc($6), esc($5) }
    '
  )"

  if [ -n "$rows" ]; then
    body=$'      <div class="table-wrap">\n        <table>\n          <thead>\n            <tr><th>Package</th><th>Version</th><th>Arch</th><th class="num">Size</th><th>Description</th><th>Download</th></tr>\n          </thead>\n          <tbody>\n'"$rows"$'\n          </tbody>\n        </table>\n      </div>'
  else
    body='      <p class="empty">No packages published yet.</p>'
  fi

  # --- site config (conf/site.conf), with THEME overridable from the env ---
  local theme_env="${THEME:-}"
  [ -f "$ROOT/conf/site.conf" ] && . "$ROOT/conf/site.conf"
  [ -n "$theme_env" ] && THEME="$theme_env"
  : "${SITE_TITLE:=candy-tools}"
  : "${SITE_TAGLINE:=A signed APT repository for Debian and Ubuntu}"
  : "${REPO_URL:=https://candy-tools.github.io/debian-repo}"
  : "${GITHUB_URL:=https://github.com/candy-tools/debian-repo}"
  : "${KEYRING_FILE:=candy-tools-archive-keyring.gpg}"
  : "${SOURCES_FILE:=candy-tools.sources}"
  : "${THEME:=violet}"

  gh="${GITHUB_URL#http://}"; gh="${gh#https://}"   # link label without the scheme

  # architecture list for the tagline: "<code>a</code> and <code>b</code>"
  arches_html=""; n=${#ARCHES[@]}; i=0
  for a in "${ARCHES[@]}"; do
    i=$((i+1))
    if [ "$i" -gt 1 ]; then
      if [ "$i" -eq "$n" ] && [ "$n" -eq 2 ]; then arches_html+=" and "; else arches_html+=", "; fi
    fi
    arches_html+="<code>$a</code>"
  done

  # colour theme: violet is built into the template; alternates are CSS files
  theme_css=""
  if [ "$THEME" != "violet" ]; then
    tf="$ROOT/conf/themes/$THEME.css"
    if [ -f "$tf" ]; then theme_css="$(cat "$tf")"
    else echo "⚠️  unknown theme '$THEME' (no $tf) — using built-in violet" >&2; fi
  fi

  # --- substitute tokens + packages table + theme into the template ---
  content="$(cat "$ROOT/index.html")"
  content=${content//'@@SITE_TITLE@@'/$SITE_TITLE}
  content=${content//'@@SITE_TAGLINE@@'/$SITE_TAGLINE}
  content=${content//'@@REPO_URL@@'/$REPO_URL}
  content=${content//'@@KEYRING_FILE@@'/$KEYRING_FILE}
  content=${content//'@@SOURCES_FILE@@'/$SOURCES_FILE}
  content=${content//'@@GITHUB_URL@@'/$GITHUB_URL}
  content=${content//'@@GITHUB_LABEL@@'/$gh}
  content=${content//'@@ARCHES@@'/$arches_html}
  content=${content//'<!-- PACKAGES_TABLE -->'/$body}
  content=${content//'/* @@THEME@@ */'/$theme_css}
  printf '%s\n' "$content" > "$site/index.html"
}

mkdir -p "$SITE/pool/main"
rm -rf "$SITE/dists"
for arch in "${ARCHES[@]}"; do
  mkdir -p "$SITE/dists/stable/main/binary-$arch"
done

(
  cd "$SITE"
  for arch in "${ARCHES[@]}"; do
    echo ">> indexing $arch"
    apt-ftparchive --arch "$arch" packages pool/main > "dists/stable/main/binary-$arch/Packages"
    gzip -9 -kf "dists/stable/main/binary-$arch/Packages"
  done
  echo ">> generating Release"
  apt-ftparchive -c "$CONF_ABS" release dists/stable > dists/stable/Release
  echo ">> signing (InRelease + Release.gpg)"
  gpg --batch --yes --local-user "$KEY_EMAIL" --clearsign -o dists/stable/InRelease dists/stable/Release
  gpg --batch --yes --local-user "$KEY_EMAIL" -abs -o dists/stable/Release.gpg dists/stable/Release
)

# static files served from the site root
cp "$ROOT/candy-tools-archive-keyring.gpg" \
   "$ROOT/candy-tools-archive-keyring.asc" \
   "$ROOT/candy-tools.sources" \
   "$SITE/"
# landing page, with the package listing injected into the "Packages" tab
render_index "$SITE"
touch "$SITE/.nojekyll"

echo "✅ built + signed $SITE/"
