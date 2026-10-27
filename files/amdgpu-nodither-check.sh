#!/bin/sh
# Safety net: raise a desktop notification when the dither-disabled amdgpu is
# not actually in charge. It covers two distinct failure modes:
#   1) amdgpu did not load at all (e.g. the kernel refused the module's
#      relocations) -> the display falls back to simpledrm @ 1024x768;
#   2) the loaded module is not the patched build (an update reverted it)
#      -> FRC is back;
#   3) the patched build was made from vanilla kernel.org source instead of
#      the distro's own source -> it lacks the distro's backported fixes
#      (this once caused a NULL deref oops and a frozen machine).
# Installed as an XDG autostart entry (runs in the user session).
#
# NOTE: checking `modinfo -F frc_dither amdgpu` alone is NOT enough — modinfo
# reads the module FILE on disk, so it happily reports "disabled" while no
# driver is loaded at all. That exact blind spot once kept a dead driver
# unnoticed for three days; hence check 1 below comes first.

warn() {   # $1 = message, $2 = title
  logger -t amdgpu-nodither "WARNING: $1"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical -i dialog-warning "amdgpu: $2" "$1"
  fi
  exit 1
}

# --- 1) is amdgpu bound to a DRM card at all? ---
bound=0
for d in /sys/class/drm/card*/device/driver; do
  [ -e "$d" ] || continue
  case "$(readlink -f "$d")" in */amdgpu) bound=1 ;; esac
done
if [ "$bound" -eq 0 ]; then
  warn "amdgpu did NOT load — the display is running on a fallback driver \
(simpledrm, 1024x768). Fix:  sudo amdgpu-nodither-rebuild.sh --force  and reboot. \
For the cause see:  journalctl -k -b | grep -iE 'amdgpu|relocation'" \
       "driver did NOT load"
fi

# --- 2) is the installed module the patched build? ---
if [ "$(modinfo -F frc_dither amdgpu 2>/dev/null)" != "disabled" ]; then
  warn "The running amdgpu driver is NOT the dither-disabled build — temporal \
dithering (FRC) is back. Fix:  sudo amdgpu-nodither-rebuild.sh  then reboot." \
       "dithering is NOT disabled"
fi

# --- 3) was it built from the distro's kernel source? ---
case "$(modinfo -F nodither_src amdgpu 2>/dev/null)" in
  ubuntu-*) ;;
  *) warn "The patched amdgpu was built from vanilla source WITHOUT Ubuntu's \
backported fixes (risk of oopses / freezes). Fix:  sudo amdgpu-nodither-rebuild.sh --force \
then reboot." "module lacks distro fixes" ;;
esac
exit 0
