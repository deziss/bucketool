#!/usr/bin/env bash
#
# install.sh — install or update s3sync on this machine.
#
# Safe to re-run: the script, the example configs and the systemd units are
# refreshed, while an existing s3sync.yml / s3sync.env is never touched.
#
#   sudo ./install.sh                  # install or update
#   sudo ./install.sh --systemd        # ...and enable the nightly backup + weekly verify timers
#   sudo ./install.sh --with-rclone    # ...and put a checksum-verified rclone in $PREFIX/bin
#   PREFIX=/opt/s3sync BIN=/usr/local/bin/s3sync CONF=/etc/s3sync ./install.sh
#
set -Eeuo pipefail

PREFIX="${PREFIX:-/opt/s3sync}"
BIN="${BIN:-/usr/local/bin/s3sync}"
CONF="${CONF:-/etc/s3sync}"
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

[[ -f "$SRC/s3sync.sh" ]] || die "run this from an s3sync checkout (no s3sync.sh next to install.sh)"
bash -n "$SRC/s3sync.sh" || die "s3sync.sh does not parse — refusing to install it"

OLD=""
[[ -x "$PREFIX/s3sync.sh" ]] && OLD="$("$PREFIX/s3sync.sh" --version 2>/dev/null || true)"
NEW="$(sed -n 's/^readonly S3SYNC_VERSION="\([^"]*\)".*/\1/p' "$SRC/s3sync.sh" | head -1)"

install -d -m 0755 "$PREFIX" "$CONF" "$(dirname "$BIN")"
install -m 0755 "$SRC/s3sync.sh" "$PREFIX/s3sync.sh"
for f in README.md SOP.md TROUBLESHOOTING.md CHANGELOG.md; do
    [[ -f "$SRC/$f" ]] && install -m 0644 "$SRC/$f" "$PREFIX/$f"
done
ln -sfn "$PREFIX/s3sync.sh" "$BIN"

# templates are always refreshed; real config and secrets never are
install -m 0644 "$SRC/s3sync.example.yml"  "$CONF/s3sync.example.yml"
install -m 0644 "$SRC/s3sync.example.json" "$CONF/s3sync.example.json"
install -m 0600 "$SRC/s3sync.env.example"  "$CONF/s3sync.env.example"
FRESH=false
if [[ ! -f "$CONF/s3sync.yml" ]]; then install -m 0640 "$SRC/s3sync.example.yml" "$CONF/s3sync.yml"; FRESH=true; fi
if [[ ! -f "$CONF/s3sync.env" ]]; then install -m 0600 "$SRC/s3sync.env.example" "$CONF/s3sync.env"; FRESH=true; fi

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
    for u in s3sync-backup.service s3sync-backup.timer s3sync-verify.service s3sync-verify.timer; do
        install -m 0644 "$SRC/systemd/$u" "/etc/systemd/system/$u"
    done
    systemctl daemon-reload
    systemctl enable --now s3sync-backup.timer s3sync-verify.timer
    say "timers enabled — check: systemctl list-timers 's3sync-*'"
    say "ReadWritePaths in the units must match defaults.backup_dir in your config"
fi

if [[ -n $OLD && $OLD != "$NEW" ]]; then say "updated s3sync v$OLD -> v$NEW"
elif [[ -n $OLD ]]; then say "reinstalled s3sync v$NEW"
else say "installed s3sync v$NEW"; fi
if $FRESH; then say "edit $CONF/s3sync.yml and $CONF/s3sync.env, then run:  s3sync test --deep"
else say "config left untouched. Check with:  s3sync test --deep"; fi
