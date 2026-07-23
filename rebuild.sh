#!/usr/bin/env bash
#
# rebuild.sh [--build-only] [KERNELRELEASE]
#
# Builds a patched amdgpu.ko with ALL output bit-depth dithering disabled
# (truncation + spatial + temporal/FRC), signs it with the local MOK and
# installs it for the given kernel (default: the running one).
#
# Method: build amdgpu as an EXTERNAL module against the installed kernel build
# tree  /lib/modules/$KVER/build  (KDIR). That tree carries Ubuntu's exact
# .config, mitigation flags (CALL_PADDING/RETHUNK/…), objtool, Module.symvers
# and kernel.release, so vermagic AND module relocations match the running
# kernel exactly. The amdgpu source comes from the matching upstream stable
# tarball (kernel.org); Ubuntu's HWE kernel tracks that base.
#
# Safe to run unattended from /etc/kernel/postinst.d/:
#   - never touches apt/dpkg, idempotent, soft-fails (exit 0) on missing inputs,
#   - verifies vermagic + patch marker before installing, backs up stock module.
#
# --build-only : compile + verify only; no signing, no install, no root needed.
#
set -uo pipefail

log()  { echo "[amdgpu-nodither] $*"; }
die()  { echo "[amdgpu-nodither] ERROR: $*" >&2; exit 1; }
softfail() { echo "[amdgpu-nodither] SOFT-FAIL: $*" >&2; exit 0; }

BUILD_ONLY=0; KVER=""
for a in "$@"; do case "$a" in
  --build-only) BUILD_ONLY=1 ;; *) KVER="$a" ;;
esac; done
[ -n "$KVER" ] || KVER="$(uname -r)"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH=""
for p in "$SELF_DIR/amdgpu-nodither.patch" /usr/local/share/amdgpu-nodither/amdgpu-nodither.patch; do
  [ -f "$p" ] && PATCH="$p" && break
done
[ -n "$PATCH" ] || die "patch file not found"

KDIR="/lib/modules/$KVER/build"
MODREL="/lib/modules/$KVER/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.zst"
SIGN_FILE="$KDIR/scripts/sign-file"
WORK="${AMDGPU_ND_WORK:-/var/cache/amdgpu-nodither}"
MOK_DIR="${AMDGPU_ND_MOK:-/var/lib/amdgpu-nodither}"
MOK_PRIV="$MOK_DIR/MOK.priv"; MOK_DER="$MOK_DIR/MOK.der"
DC=drivers/gpu/drm/amd/display/dc/core/dc_resource.c
TRACE=drivers/gpu/drm/amd/amdgpu/amdgpu_trace.h

# --- sanity ---------------------------------------------------------------
[ -d "$KDIR" ] && [ -f "$KDIR/Makefile" ] || softfail "missing kernel build tree $KDIR (install linux-headers-$KVER)"
[ -f "$KDIR/Module.symvers" ] || softfail "missing $KDIR/Module.symvers"
if grep -q '^CONFIG_GCC_PLUGIN_RANDSTRUCT=y\|^CONFIG_RANDSTRUCT_FULL=y' "$KDIR/.config" 2>/dev/null; then
  die "kernel uses RANDSTRUCT; out-of-tree amdgpu rebuild is unsafe."
fi

# --- already patched? -----------------------------------------------------
if [ -f "$MODREL" ] && [ "$(modinfo -F frc_dither "$MODREL" 2>/dev/null)" = "disabled" ]; then
  log "amdgpu for $KVER is already patched — nothing to do."; exit 0
fi

# --- upstream base version from the kernel's own Makefile -----------------
V=$(awk -F' *= *' '/^VERSION/{print $2}'    "$KDIR/Makefile")
P=$(awk -F' *= *' '/^PATCHLEVEL/{print $2}' "$KDIR/Makefile")
S=$(awk -F' *= *' '/^SUBLEVEL/{print $2}'   "$KDIR/Makefile")
BASE="$V.$P.$S"
log "target kernel = $KVER | upstream base = $BASE | KDIR = $KDIR"

# --- fetch source ---------------------------------------------------------
mkdir -p "$WORK/src" "$WORK/build" || die "cannot create $WORK"
TB="$WORK/src/linux-$BASE.tar.xz"
if [ ! -s "$TB" ]; then
  URL="https://cdn.kernel.org/pub/linux/kernel/v${V}.x/linux-$BASE.tar.xz"
  log "downloading $URL"
  curl -fL --retry 3 -o "$TB.part" "$URL" || softfail "source download failed"
  mv "$TB.part" "$TB"
fi

# Extract into a path with NO 'linux' token: the C token `linux` is a
# predefined GCC macro (=1) and would corrupt the absolute TRACE_INCLUDE_PATH.
BDIR="$WORK/build/$KVER"; SRC="$BDIR/ksrc"
rm -rf "$BDIR"; mkdir -p "$BDIR"
log "extracting ..."
tar -C "$BDIR" -xf "$TB" || die "extract failed"
mv "$BDIR/linux-$BASE" "$SRC"
cd "$SRC" || die "cannot cd $SRC"
AMD="$SRC/drivers/gpu/drm/amd/amdgpu"

# --- apply dither-disable patch + verification marker ---------------------
log "patching ..."
if ! patch -p1 --fuzz=3 --no-backup-if-mismatch < "$PATCH" 2>/dev/null; then
  python3 - "$DC" <<'PY' || die "patch insertion failed"
import sys
f=sys.argv[1]; s=open(f).read()
if "LOCAL PATCH: disable all output bit-depth reduction" not in s:
    a="memset(fmt_bit_depth, 0, sizeof(*fmt_bit_depth));"
    i=s.find(a)
    if i<0: sys.exit("anchor not found")
    j=s.find("\n",i)+1
    ins=("\n\t/*\n\t * LOCAL PATCH: disable all output bit-depth reduction, i.e.\n"
         "\t * truncation + spatial dithering + temporal dithering (FRC).\n"
         "\t * Identical to the driver's built-in DITHER_OPTION_DISABLE path.\n"
         "\t */\n\treturn;\n")
    open(f,"w").write(s[:j]+ins+s[j:])
PY
fi
grep -q 'LOCAL PATCH: disable all output bit-depth reduction' "$DC" || die "dither patch did NOT apply"
grep -q 'MODULE_INFO(frc_dither' "$DC" || printf '\n#include <linux/module.h>\nMODULE_INFO(frc_dither, "disabled");\n' >> "$DC"

# Make the one absolute-path-hostile tracepoint include resolve for an
# out-of-tree build (its default is relative to the kernel srctree).
sed -i "s|^#define TRACE_INCLUDE_PATH .*|#define TRACE_INCLUDE_PATH $AMD|" "$TRACE"

# --- build external module against KDIR -----------------------------------
JOBS="$(nproc)"
log "building amdgpu.ko against $KDIR (~5-10 min on $JOBS cores) ..."
make -C "$KDIR" M="$AMD" modules -j"$JOBS" || die "amdgpu.ko build failed"
MODOUT="$AMD/amdgpu.ko"
[ -f "$MODOUT" ] || die "built module not found"

# --- verify vermagic + marker BEFORE trusting it --------------------------
BUILT_VM="$(modinfo -F vermagic "$MODOUT")"
STOCK_VM=""; [ -f "$MODREL" ] && STOCK_VM="$(modinfo -F vermagic "$MODREL" 2>/dev/null)"
log "built vermagic: '$BUILT_VM'"
[ "${BUILT_VM%% *}" = "$KVER" ] || die "vermagic release '${BUILT_VM%% *}' != '$KVER'"
echo "$BUILT_VM" | grep -q modversions || die "vermagic missing modversions"
[ -z "$STOCK_VM" ] || [ "$BUILT_VM" = "$STOCK_VM" ] || die "vermagic != stock ('$STOCK_VM')"
[ "$(modinfo -F frc_dither "$MODOUT")" = "disabled" ] || die "marker missing in built module"

strip --strip-debug "$MODOUT" || die "strip failed"
[ "$(modinfo -F frc_dither "$MODOUT")" = "disabled" ] || die "marker lost after strip"
log "vermagic + marker OK, stripped -> $(du -h "$MODOUT" | cut -f1)."

if [ "$BUILD_ONLY" -eq 1 ]; then
  log "BUILD-ONLY done: $MODOUT"; exit 0
fi

# --- sign with MOK, install -----------------------------------------------
[ -f "$MOK_PRIV" ] && [ -f "$MOK_DER" ] || die "MOK key missing in $MOK_DIR"
[ -x "$SIGN_FILE" ] || die "sign-file not found at $SIGN_FILE"
log "signing with MOK ..."
"$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$MODOUT" || die "signing failed"
zstd -q -f -19 "$MODOUT" -o "$AMD/amdgpu.ko.zst" || die "zstd failed"

if [ -f "$MODREL" ] && [ ! -f "$MODREL.stock-orig" ]; then
  cp -a "$MODREL" "$MODREL.stock-orig"; log "backed up stock -> $MODREL.stock-orig"
fi
install -m 0644 "$AMD/amdgpu.ko.zst" "$MODREL" || die "install failed (need root)"
depmod "$KVER" || die "depmod failed"
update-initramfs -u -k "$KVER" >/dev/null 2>&1 || log "update-initramfs warning (non-fatal)"

rm -rf "$BDIR"   # free the build tree; source tarball stays cached
log "DONE: patched amdgpu installed for $KVER."
