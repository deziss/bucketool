#!/usr/bin/env bash
#
# install.sh — install or update bucketool on this machine.
#
# Safe to re-run: the script, the example configs and the systemd units are
# refreshed, while an existing bucketool.yml / bucketool.env is never touched.
#
#   sudo ./install.sh                  # install or update
#   sudo ./install.sh --systemd        # ...and enable the nightly backup + weekly verify timers
#   sudo ./install.sh --with-rclone    # ...and put a checksum-verified rclone in $PREFIX/bin
#   PREFIX=/opt/bucketool BIN=/usr/local/bin/bucketool CONF=/etc/bucketool ./install.sh
#
set -Eeuo pipefail

PREFIX="${PREFIX:-/opt/bucketool}"
BIN="${BIN:-/usr/local/bin/bucketool}"
CONF="${CONF:-/etc/bucketool}"
RCLONE_VERSION="${RCLONE_VERSION:-1.75.2}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WITH_SYSTEMD=false
WITH_RCLONE=false
for a in "$@"; do
    case "$a" in
        --systemd) WITH_SYSTEMD=true ;;
        --with-rclone) WITH_RCLONE=true ;;
        -h|--help) sed -n '3,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$SRC/bucketool.sh" ]] || die "run this from an bucketool checkout (no bucketool.sh next to install.sh)"
bash -n "$SRC/bucketool.sh" || die "bucketool.sh does not parse — refusing to install it"

OLD=""
[[ -x "$PREFIX/bucketool.sh" ]] && OLD="$("$PREFIX/bucketool.sh" --version 2>/dev/null || true)"
NEW="$(sed -n 's/^readonly BUCKETOOL_VERSION="\([^"]*\)".*/\1/p' "$SRC/bucketool.sh" | head -1)"

install -d -m 0755 "$PREFIX" "$CONF" "$(dirname "$BIN")"
install -m 0755 "$SRC/bucketool.sh" "$PREFIX/bucketool.sh"
for f in README.md SOP.md TROUBLESHOOTING.md CHANGELOG.md; do
    [[ -f "$SRC/$f" ]] && install -m 0644 "$SRC/$f" "$PREFIX/$f"
done
ln -sfn "$PREFIX/bucketool.sh" "$BIN"

# templates are always refreshed; real config and secrets never are
install -m 0644 "$SRC/bucketool.example.yml"  "$CONF/bucketool.example.yml"
install -m 0644 "$SRC/bucketool.example.json" "$CONF/bucketool.example.json"
install -m 0600 "$SRC/bucketool.env.example"  "$CONF/bucketool.env.example"
FRESH=false
if [[ ! -f "$CONF/bucketool.yml" ]]; then install -m 0640 "$SRC/bucketool.example.yml" "$CONF/bucketool.yml"; FRESH=true; fi
if [[ ! -f "$CONF/bucketool.env" ]]; then install -m 0600 "$SRC/bucketool.env.example" "$CONF/bucketool.env"; FRESH=true; fi

if $WITH_RCLONE; then
    command -v curl >/dev/null || die "--with-rclone needs curl"
    command -v unzip >/dev/null || die "--with-rclone needs unzip"
    arch="$(uname -m)"
    case "$arch" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; armv7l) arch=arm-v7 ;; *) die "no rclone build for $arch" ;; esac
    zip="rclone-v${RCLONE_VERSION}-linux-${arch}.zip"
    base="https://downloads.rclone.org/v${RCLONE_VERSION}"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    say "downloading rclone v$RCLONE_VERSION ($arch)"
    curl -fsSL -o "$tmp/$zip" "$base/$zip" || die "cannot download $base/$zip"
    curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || die "cannot download $base/SHA256SUMS"
    want="$(grep " $zip\$" "$tmp/SHA256SUMS" | awk '{print $1}')"
    [[ -n $want && "$(sha256sum "$tmp/$zip" | awk '{print $1}')" == "$want" ]] || die "rclone checksum mismatch — refusing"
    unzip -q "$tmp/$zip" -d "$tmp"
    install -d -m 0755 "$PREFIX/bin"
    install -m 0755 "$tmp/${zip%.zip}/rclone" "$PREFIX/bin/rclone"
    say "rclone $("$PREFIX/bin/rclone" version | head -1) installed in $PREFIX/bin (checksum verified)"
fi

if $WITH_SYSTEMD; then
    for u in bucketool-backup.service bucketool-backup.timer bucketool-verify.service bucketool-verify.timer; do
        install -m 0644 "$SRC/systemd/$u" "/etc/systemd/system/$u"
    done
    systemctl daemon-reload
    systemctl enable --now bucketool-backup.timer bucketool-verify.timer
    say "timers enabled — check: systemctl list-timers 'bucketool-*'"
    say "ReadWritePaths in the units must match defaults.backup_dir in your config"
fi

if [[ -n $OLD && $OLD != "$NEW" ]]; then say "updated bucketool v$OLD -> v$NEW"
elif [[ -n $OLD ]]; then say "reinstalled bucketool v$NEW"
else say "installed bucketool v$NEW"; fi
if $FRESH; then say "edit $CONF/bucketool.yml and $CONF/bucketool.env, then run:  bucketool test --deep"
else say "config left untouched. Check with:  bucketool test --deep"; fi
