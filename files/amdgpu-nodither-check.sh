#!/bin/sh
# Safety net: warn (desktop notification) if the running kernel's amdgpu is
# NOT the dither-disabled build — so a fix silently reverted by a kernel update
# can never go unnoticed. Installed as an XDG autostart entry (user session).
MARK="$(modinfo -F frc_dither amdgpu 2>/dev/null)"
if [ "$MARK" = "disabled" ]; then
  exit 0
fi
MSG="The running amdgpu driver is NOT the dither-disabled build — temporal \
dithering (FRC) is back. Fix it:  sudo amdgpu-nodither-rebuild.sh  then reboot."
if command -v notify-send >/dev/null 2>&1; then
  notify-send -u critical -i dialog-warning "amdgpu: dithering is NOT disabled" "$MSG"
fi
logger -t amdgpu-nodither "WARNING: running amdgpu is not the dither-disabled build"
