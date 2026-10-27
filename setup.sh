#!/usr/bin/env bash
#
# setup.sh — one-time installer for the "amdgpu dithering disabled" fix.
# Run as root:   sudo bash setup.sh
#
# Installs:
#   * build deps
#   * a local MOK signing key (+ enrolls it via mokutil — needs a reboot)
#   * /usr/local/sbin/amdgpu-nodither-rebuild.sh   (build+sign+install)
#   * /usr/local/sbin/amdgpu-nodither-check.sh     (pojistka)
#   * /etc/kernel/postinst.d/zz-amdgpu-nodither     (auto-rebuild on kernel update)
#   * amdgpu-nodither-rebuild.service               (boot-time fallback/retry)
#   * /etc/xdg/autostart/…                          (desktop warning if unpatched)
# Then builds+installs the patched module for the CURRENT kernel.
#
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE=/usr/local/share/amdgpu-nodither
SBIN=/usr/local/sbin
MOK_DIR=/var/lib/amdgpu-nodither
BUILD=1
[ "${1:-}" = "--no-build" ] && BUILD=0

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash setup.sh"; exit 1; }

echo "== 1/6 build dependencies =="
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends \
  build-essential flex bison libssl-dev libelf-dev libdw-dev bc zstd curl xz-utils bzip2 \
  mokutil libnotify-bin

echo "== 2/6 install scripts & assets =="
install -d "$SHARE" "$SBIN" "$MOK_DIR"
install -m 0755 "$KIT/rebuild.sh"                  "$SBIN/amdgpu-nodither-rebuild.sh"
install -m 0755 "$KIT/files/amdgpu-nodither-check.sh" "$SBIN/amdgpu-nodither-check.sh"
install -m 0644 "$KIT/amdgpu-nodither.patch"       "$SHARE/amdgpu-nodither.patch"
[ -f "$KIT/README.md" ] && install -m 0644 "$KIT/README.md" "$SHARE/README.md" || true

echo "== 3/6 MOK signing key =="
if [ ! -f "$MOK_DIR/MOK.priv" ] || [ ! -f "$MOK_DIR/MOK.der" ]; then
  openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 \
    -keyout "$MOK_DIR/MOK.priv" -outform DER -out "$MOK_DIR/MOK.der" \
    -subj "/CN=amdgpu-nodither local module signing/"
  chmod 600 "$MOK_DIR/MOK.priv"
  echo "   generated $MOK_DIR/MOK.{priv,der}"
fi
ENROLL_NEEDED=0
if mokutil --test-key "$MOK_DIR/MOK.der" 2>/dev/null | grep -qi 'is already enrolled'; then
  echo "   MOK already enrolled."
else
  echo "   >>> Enrolling MOK. You'll set a ONE-TIME password now, then confirm it"
  echo "   >>> in the blue 'MOK Manager' screen right after the next reboot."
  mokutil --import "$MOK_DIR/MOK.der"
  ENROLL_NEEDED=1
fi

echo "== 4/6 kernel-update hook =="
install -m 0755 "$KIT/files/zz-amdgpu-nodither" /etc/kernel/postinst.d/zz-amdgpu-nodither

echo "== 5/6 boot-fallback service + desktop pojistka =="
install -m 0644 "$KIT/files/amdgpu-nodither-rebuild.service" /etc/systemd/system/amdgpu-nodither-rebuild.service
install -m 0644 "$KIT/files/amdgpu-nodither-check.desktop"   /etc/xdg/autostart/amdgpu-nodither-check.desktop
systemctl daemon-reload
systemctl enable amdgpu-nodither-rebuild.service

echo "== 6/6 patched module =="
BUILT_NOW=0
if [ "$ENROLL_NEEDED" -eq 0 ] && [ "$BUILD" -eq 1 ]; then
  echo "   MOK is already enrolled -> building + installing patched module now"
  "$SBIN/amdgpu-nodither-rebuild.sh" "$(uname -r)"
  BUILT_NOW=1
else
  echo "   Skipping module build for now (stock amdgpu stays in place as a safe"
  echo "   fallback until the MOK is trusted). It gets built after you enroll."
fi

echo
echo "=================== DONE (setup) ==================="
if [ "$ENROLL_NEEDED" -eq 1 ]; then
  cat <<'EOF'
NEXT STEPS:
  1) Reboot. A blue "MOK Manager" screen appears -> Enroll MOK -> Continue
     -> enter the one-time password you set above -> reboot.
  2) After reboot, install the patched module:
         sudo amdgpu-nodither-rebuild.sh
     (or just wait a few minutes — the boot service builds it automatically)
  3) Reboot once more to load it, then verify:
         modinfo -F frc_dither amdgpu        # must print:  disabled
EOF
elif [ "$BUILT_NOW" -eq 1 ]; then
  echo "Patched module installed. Reboot, then verify:"
  echo "    modinfo -F frc_dither amdgpu        # must print:  disabled"
else
  echo "MOK enrolled but build skipped (--no-build). Run: sudo amdgpu-nodither-rebuild.sh"
fi
echo "===================================================="
