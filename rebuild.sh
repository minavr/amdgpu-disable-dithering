#!/usr/bin/env bash
#
# rebuild.sh [--build-only] [--force] [--vanilla] [KERNELRELEASE]
#
# Builds a patched amdgpu.ko with ALL output bit-depth dithering disabled
# (truncation + spatial + temporal/FRC), signs it with the local MOK and
# installs it for the given kernel (default: the running one).
#
# Method: build amdgpu as an EXTERNAL module against the installed kernel build
# tree  /lib/modules/$KVER/build  (KDIR). That tree carries Ubuntu's exact
# .config, mitigation flags (CALL_PADDING/RETHUNK/…), objtool, Module.symvers
# and kernel.release, so vermagic AND module relocations match the running
# kernel exactly.
#
# Source: Ubuntu's own kernel tree from the linux-source-X.Y.Z package, in the
# EXACT version of the installed kernel package (fetched with `apt-get
# download`, never installed). Do NOT use the kernel.org tarball named by
# KDIR/Makefile: Ubuntu stops bumping SUBLEVEL and keeps backporting fixes, so
# a vanilla build silently drops them (2026-10: vanilla 7.0.14 lacked Ubuntu's
# "fix check in amdgpu_hmm_invalidate_gfx" -> NULL deref oops -> frozen PC).
#
# Safe to run unattended from /etc/kernel/postinst.d/:
#   - never installs/removes packages (apt-get download needs no dpkg lock),
#   - idempotent, soft-fails (exit 0) on missing inputs,
#   - verifies vermagic + patch/source markers before installing, backs up
#     the stock module.
#
# --build-only : compile + verify only; no signing, no install, no root needed.
# --force      : rebuild even if the installed module already looks patched.
# --vanilla    : last resort: build from the kernel.org tarball instead
#                (misses Ubuntu's backported fixes — NOT recommended).
#
# Verification before install: vermagic, patch marker AND the
# .gnu.linkonce.this_module relocation offsets vs the stock module (catches a
# struct-module layout mismatch, which makes the kernel refuse the module).
#
set -uo pipefail

log()  { echo "[amdgpu-nodither] $*"; }
die()  { echo "[amdgpu-nodither] ERROR: $*" >&2; exit 1; }
softfail() { echo "[amdgpu-nodither] SOFT-FAIL: $*" >&2; exit 0; }

# Fingerprint of .gnu.linkonce.this_module relocations (offset + symbol).
# These offsets ARE the struct-module layout the module was compiled against.
# If they differ from the stock module's, the running kernel refuses the
# relocation ("Invalid relocation target, existing value is nonzero") and the
# module never loads -> no GPU driver.  Accepts .ko or (any-named) zstd file.
this_module_relocs() {
  local f="$1" tmp out
  [ -f "$f" ] || return 1
  tmp="$(mktemp)" || return 1
  if [ "$(head -c4 "$f" | od -An -tx1 | tr -d ' \n')" = "28b52ffd" ]; then
    zstd -dqc "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  else
    cat "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  out="$(readelf -r -W "$tmp" 2>/dev/null | awk '
      /\.rela\.gnu\.linkonce\.this_module/ {p=1; next}
      p && /^$/ {exit}
      p && /R_X86_64/ {print $1, $5}' | sort | tr '\n' ';')"
  rm -f "$tmp"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

BUILD_ONLY=0; FORCE=0; VANILLA=0; KVER=""
for a in "$@"; do case "$a" in
  --build-only) BUILD_ONLY=1 ;; --force) FORCE=1 ;; --vanilla) VANILLA=1 ;;
  -*) die "unknown option $a" ;; *) KVER="$a" ;;
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

# --- which source? ---------------------------------------------------------
# Ubuntu package version of this exact kernel (e.g. 7.0.0-38.38) and the
# binary package that ships its source tree (e.g. linux-source-7.0.0).
V=$(awk -F' *= *' '/^VERSION/{print $2}'    "$KDIR/Makefile")
P=$(awk -F' *= *' '/^PATCHLEVEL/{print $2}' "$KDIR/Makefile")
S=$(awk -F' *= *' '/^SUBLEVEL/{print $2}'   "$KDIR/Makefile")
BASE="$V.$P.$S"
PKGVER=""
for p in "linux-modules-$KVER" "linux-image-$KVER" "linux-image-unsigned-$KVER"; do
  PKGVER="$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null)" && [ -n "$PKGVER" ] && break
done
SRCPKG="linux-source-${KVER%%-*}"
if [ "$VANILLA" -eq 1 ]; then
  SRC_ID="vanilla-$BASE"
else
  [ -n "$PKGVER" ] || softfail "cannot determine Ubuntu package version of $KVER (dpkg-query)"
  SRC_ID="ubuntu-$PKGVER"
fi

# --- already patched? -----------------------------------------------------
if [ "$FORCE" -eq 0 ] && [ -f "$MODREL" ] \
   && [ "$(modinfo -F frc_dither "$MODREL" 2>/dev/null)" = "disabled" ]; then
  # "patched" is not enough: verify it can actually be relocated by this
  # kernel, otherwise we would keep a dead driver forever (boot fallback
  # included) and the machine falls back to simpledrm @ 1024x768.
  INST_R="$(this_module_relocs "$MODREL")"
  REF_R="$(this_module_relocs "$MODREL.stock-orig")"
  INST_SRC="$(modinfo -F nodither_src "$MODREL" 2>/dev/null)"
  if [ -n "$INST_R" ] && [ -n "$REF_R" ] && [ "$INST_R" != "$REF_R" ]; then
    log "installed patched module has a MISMATCHED struct-module layout"
    log "  installed: $INST_R"
    log "  stock    : $REF_R"
    log "-> it cannot load on this kernel; rebuilding."
  elif [ "$INST_SRC" != "$SRC_ID" ]; then
    # Also catches modules from before the marker existed (= vanilla builds).
    log "installed patched module was built from '${INST_SRC:-unknown (vanilla)}', want '$SRC_ID' -> rebuilding."
  else
    log "amdgpu for $KVER is already patched ($SRC_ID) — nothing to do."; exit 0
  fi
fi

log "target kernel = $KVER | source = $SRC_ID | KDIR = $KDIR"

# --- fetch source ---------------------------------------------------------
mkdir -p "$WORK/src" "$WORK/build" || die "cannot create $WORK"
if [ "$VANILLA" -eq 1 ]; then
  log "WARNING: vanilla kernel.org source lacks Ubuntu's backported fixes."
  TB="$WORK/src/linux-$BASE.tar.xz"
  if [ ! -s "$TB" ]; then
    URL="https://cdn.kernel.org/pub/linux/kernel/v${V}.x/linux-$BASE.tar.xz"
    log "downloading $URL"
    curl -fL --retry 3 -o "$TB.part" "$URL" || softfail "source download failed"
    mv "$TB.part" "$TB"
  fi
else
  TB="$WORK/src/$SRCPKG-$PKGVER.tar.bz2"
  SYS_TB="/usr/src/$SRCPKG/$SRCPKG.tar.bz2"
  if [ -s "$TB" ]; then
    :
  elif [ "$(dpkg-query -W -f='${Version}' "$SRCPKG" 2>/dev/null)" = "$PKGVER" ] && [ -s "$SYS_TB" ]; then
    log "using installed $SRCPKG $PKGVER"
    cp "$SYS_TB" "$TB.part" && mv "$TB.part" "$TB" || die "cannot copy $SYS_TB"
  else
    # Only downloads the .deb (no install, no dpkg lock) -> fine inside an
    # apt transaction. A not-yet-synced mirror just soft-fails; the boot
    # service retries later.
    DL="$(mktemp -d "$WORK/src/dl.XXXXXX")" || die "mktemp failed"
    [ "$(id -u)" -eq 0 ] && chown _apt "$DL" 2>/dev/null   # lets apt download sandboxed
    log "downloading $SRCPKG=$PKGVER (~200 MB) ..."
    ( cd "$DL" && apt-get download -q "$SRCPKG=$PKGVER" ) \
      || { rm -rf "$DL"; softfail "apt-get download $SRCPKG=$PKGVER failed"; }
    DEB="$(ls "$DL"/*.deb 2>/dev/null | head -n1)"
    dpkg-deb --fsys-tarfile "$DEB" | tar -xO "./usr/src/$SRCPKG/$SRCPKG.tar.bz2" > "$TB.part" \
      && [ -s "$TB.part" ] || { rm -rf "$DL" "$TB.part"; die "cannot unpack $SRCPKG.tar.bz2 from $DEB"; }
    rm -rf "$DL"; mv "$TB.part" "$TB"
  fi
fi

# Extract into a path with NO 'linux' token: the C token `linux` is a
# predefined GCC macro (=1) and would corrupt the absolute TRACE_INCLUDE_PATH.
BDIR="$WORK/build/$KVER"; SRC="$BDIR/ksrc"
rm -rf "$BDIR"; mkdir -p "$BDIR"
log "extracting $(basename "$TB") ..."
tar -C "$BDIR" -xf "$TB" || die "extract failed"
TOP="$(find "$BDIR" -mindepth 1 -maxdepth 1 -type d)"
[ -n "$TOP" ] && [ "$(printf '%s\n' "$TOP" | wc -l)" -eq 1 ] || die "unexpected tarball layout in $BDIR"
mv "$TOP" "$SRC"
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
printf 'MODULE_INFO(nodither_src, "%s");\n' "$SRC_ID" >> "$DC"

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
[ "$(modinfo -F nodither_src "$MODOUT")" = "$SRC_ID" ] || die "source marker missing in built module"

strip --strip-debug "$MODOUT" || die "strip failed"
[ "$(modinfo -F frc_dither "$MODOUT")" = "disabled" ] || die "marker lost after strip"

# struct-module layout must match the stock module bit for bit, else the
# kernel rejects the relocation at load time and we end up with no driver.
REF=""
for r in "$MODREL.stock-orig" "$MODREL"; do
  [ -f "$r" ] && [ "$(modinfo -F frc_dither "$r" 2>/dev/null)" != "disabled" ] && REF="$r" && break
done
if [ -n "$REF" ]; then
  BUILT_R="$(this_module_relocs "$MODOUT")"; REF_R="$(this_module_relocs "$REF")"
  [ -n "$BUILT_R" ] && [ -n "$REF_R" ] || die "cannot read this_module relocations (readelf/zstd missing?)"
  if [ "$BUILT_R" != "$REF_R" ]; then
    log "built  : $BUILT_R"
    log "stock  : $REF_R"
    die "struct-module layout differs from stock ($REF) — the kernel would refuse to load this module; NOT installing."
  fi
  log "struct-module relocation layout matches stock: $BUILT_R"
else
  log "WARNING: no unpatched reference module found — layout check skipped."
fi
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

# (Re)take the backup whenever the installed module is a stock one — a
# package re-install of the same KVER must refresh a stale backup.
if [ -f "$MODREL" ] && [ "$(modinfo -F frc_dither "$MODREL" 2>/dev/null)" != "disabled" ]; then
  cp -a "$MODREL" "$MODREL.stock-orig"; log "backed up stock -> $MODREL.stock-orig"
fi
install -m 0644 "$AMD/amdgpu.ko.zst" "$MODREL" || die "install failed (need root)"
depmod "$KVER" || die "depmod failed"
update-initramfs -u -k "$KVER" >/dev/null 2>&1 || log "update-initramfs warning (non-fatal)"

rm -rf "$BDIR"   # free the build tree; source tarball stays cached
# Keep only the tarball just used (each is ~200 MB).
find "$WORK/src" -maxdepth 1 -type f ! -name "$(basename "$TB")" -delete 2>/dev/null
log "DONE: patched amdgpu ($SRC_ID) installed for $KVER."
