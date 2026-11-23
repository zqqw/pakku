#!/usr/bin/env bash
# Generate the pakku-bin PKGBUILD from a published GitHub release.
#
# Usage: packaging/aur/generate.sh <tag> [owner/repo | base URL]
#
# Requires AUR_MAINTAINER ("Name <mail>") for the PKGBUILD header, so no
# maintainer identity is baked into the tree.
#
# The second argument defaults to $GITHUB_REPOSITORY, then to zqqw/pakku. A
# value containing "://" is used as the base URL verbatim, which is how the
# script is tested against a local release mirror.
set -euo pipefail

tag="${1:?usage: $0 <tag> [owner/repo | base URL]}"
repo="${2:-${GITHUB_REPOSITORY:-zqqw/pakku}}"

if [[ "$tag" != v* ]]; then
  echo "error: release tag must start with 'v': $tag" >&2
  exit 2
fi

pkgver="${tag#v}"
# Must match the asset the release workflow builds; see .github/workflows/release.yml.
arch='x86_64'
maintainer="${AUR_MAINTAINER:?set AUR_MAINTAINER to the AUR maintainer line, e.g. 'Name <mail>'}"
base="$repo"
[[ "$base" == *://* ]] || base="https://github.com/${repo}"
asset="pakku-${pkgver}-${arch}.tar.gz"
url="${base}/releases/download/${tag}/${asset}"

# The script writes into the current directory. pakku itself keeps reference
# PKGBUILDs in the repository root, so refuse to overwrite one.
if [[ -e PKGBUILD ]]; then
  echo "error: PKGBUILD already exists in $PWD; run this in an empty directory" >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --retry 3 -o "${tmp}/${asset}" "$url"
curl -fsSL --retry 3 -o "${tmp}/COPYING" "${base}/raw/${tag}/COPYING"

asset_sha="$(sha256sum "${tmp}/${asset}" | cut -d' ' -f1)"
license_sha="$(sha256sum "${tmp}/COPYING" | cut -d' ' -f1)"

cat >PKGBUILD <<EOF
# Maintainer: ${maintainer}

pkgname=pakku-bin
pkgver=${pkgver}
pkgrel=1
pkgdesc='Pacman wrapper and AUR helper with a pacman-like user interface'
arch=('${arch}')
url='${base}'
license=('GPL-3.0-only')
depends=('pacman' 'libcurl.so' 'git')
provides=('pakku')
conflicts=('pakku')
backup=('etc/pakku.conf')
# The prebuilt binary is already stripped; never touch it.
options=('!strip' '!debug')
source=(
  "${asset}::${url}"
  "COPYING-\${pkgver}::${base}/raw/${tag}/COPYING"
)
sha256sums=('${asset_sha}' '${license_sha}')

package() {
  cp -a --no-preserve=ownership "\${srcdir}/pakku-\${pkgver}-${arch}/." "\${pkgdir}/"
  install -Dm644 "\${srcdir}/COPYING-\${pkgver}" \\
    "\${pkgdir}/usr/share/licenses/\${pkgname}/COPYING"
}

check() {
  local version
  version="\$("\${srcdir}/pakku-\${pkgver}-${arch}/usr/bin/pakku" -V |
    awk '/Pakku v/ { sub(/.*Pakku v/, ""); print \$1; exit }')"
  [[ "\$version" == "\${pkgver}" ]] || {
    echo "version mismatch: binary \$version != pkgver \${pkgver}" >&2
    return 1
  }
}
EOF

if command -v makepkg >/dev/null 2>&1; then
  makepkg --printsrcinfo >.SRCINFO
fi
