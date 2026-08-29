# amdgpu-disable-dithering

Disable **GPU‑side output dithering** — truncation, spatial dither, and
especially **temporal dithering (FRC, Frame Rate Control)** — in the AMD
`amdgpu` display driver on Linux, by rebuilding `amdgpu` with a tiny patch.

**Why anyone would want this:** temporal dithering rapidly toggles a pixel
between two colours every frame to fake an intermediate shade. Many people
never notice it, but a minority are physically sensitive to the resulting
flicker and get **eye strain, headaches, fatigue or nausea**. `amdgpu` enables
this dithering by default and offers **no runtime switch** to turn it off, so
the only reliable way to disable it is to patch and rebuild the module.

---

## ⚠️ Tested on exactly one machine — read this first

This procedure was developed and verified on a **single** hardware/software
configuration:

| | |
|---|---|
| GPU | AMD Radeon **RX 6700** (Navi 22, **RDNA2**), driver `amdgpu` |
| Distro | **Ubuntu 24.04.4 LTS** (noble) |
| Kernel | **7.0.0-28-generic** (HWE stack; upstream base 7.0.12) — also in use on `7.0.0-29` and `7.0.0-30` |
| Display | HDMI to a TV, **X11** (XFCE) |
| Secure Boot | **Enabled** (module must be MOK‑signed) |

**I have not tested this on any other hardware, GPU generation, kernel, distro,
or display setup, and I can't say how universal it is within `amdgpu` + Linux.**

The *approach* — patch `resource_build_bit_depth_reduction_params()` so the
driver programs no dithering, then rebuild `amdgpu` — should generalise, because
that function is the single place AMD's Display Core decides on bit‑depth
reduction. But **every concrete detail will differ on other systems**: kernel
version and source, whether Secure Boot / MOK applies, build flags, config
option names, GPU generation quirks. Treat the exact commands here as a *worked
example*, not a guaranteed recipe. Read each step, understand it, and adapt.

**No warranty. You can end up with a black screen if a step is wrong** (been
there — see [Recovery](#recovery)). Have a way to get a terminal (SSH from
another machine, or a TTY) before you start.

---

## How it works

AMD's Display Core (DC) applies bit‑depth reduction in the **OPP → FMT** block
of the pipeline. The decision is made in one function:

```
drivers/gpu/drm/amd/display/dc/core/dc_resource.c
    void resource_build_bit_depth_reduction_params(struct dc_stream_state *stream,
                                                    struct bit_depth_reduction_params *fmt_bit_depth)
```

It fills `fmt_bit_depth` with truncation / spatial‑dither / temporal‑dither
(frame‑random, frame‑modulation) flags depending on the stream's output colour
depth. Notably:

* at **8‑bit** output it uses static spatial dithering (`FRAME_RANDOM = 0`), but
* at **10‑bit** output it falls into `DITHER_OPTION_TRUN10` with
  `FRAME_RANDOM = 1` — i.e. **temporal dithering is on**. With a deep‑colour
  display and `max bpc = 16`, the driver may well pick 10‑bit, so FRC is active.

The driver already has a "do nothing" path: `DITHER_OPTION_DISABLE` returns
early with the struct all‑zero. **The patch simply forces that path**, so no
truncation, no spatial dither and no temporal dither (FRC) is ever programmed —
regardless of the output bit depth:

```c
	memset(fmt_bit_depth, 0, sizeof(*fmt_bit_depth));

+	/* disable all output bit-depth reduction (truncation + spatial +
+	 * temporal/FRC dithering); identical to DITHER_OPTION_DISABLE */
+	return;
```

See [`amdgpu-nodither.patch`](amdgpu-nodither.patch).

> There is **no `amdgpu` module parameter** for this. `amdgpu.dcdebugmask`
> (the driver's only debug knob) has no dithering bit as of kernel 7.0 — it was
> verified against `enum DC_DEBUG_MASK` in `amd_shared.h`. Hence the rebuild.

The build also appends a one‑line marker, `MODULE_INFO(frc_dither, "disabled")`,
so you can confirm at any time that the running driver is the patched one:

```console
$ modinfo -F frc_dither amdgpu
disabled
```

---

## The critical build detail (why naive builds fail)

Modern distro kernels are compiled with CPU‑mitigation features that change the
machine code of every function — on the tested kernel:

```
CONFIG_CALL_PADDING=y
CONFIG_FUNCTION_PADDING_BYTES=16
CONFIG_MITIGATION_CALL_DEPTH_TRACKING=y
CONFIG_MITIGATION_RETHUNK=y   CONFIG_MITIGATION_RETPOLINE=y
```

If you build `amdgpu` from a **standalone kernel tree**, the module's function
padding / `objtool`‑generated call sites won't match what the kernel's module
loader expects, and loading fails at runtime with:

```
modprobe: ERROR: could not insert 'amdgpu': Exec format error
module: x86/modules: Invalid relocation target, existing value is nonzero ...
```

(The module signature and `vermagic` can be perfectly correct and it still
won't load.)

**The fix: build `amdgpu` as an *external module* against the installed kernel
build tree** `/lib/modules/$(uname -r)/build`. That tree carries the distro's
exact `.config`, mitigation flags, **`objtool` binary**, `Module.symvers` and
`kernel.release`, so the resulting module's relocations **and** `vermagic` match
the running kernel automatically. This is the same mechanism DKMS uses.

Two gotchas when building the in‑tree `amdgpu` driver out‑of‑tree:

1. **`TRACE_INCLUDE_PATH`** in `amdgpu_trace.h` is relative to the kernel
   srctree and won't resolve for an external build — rewrite it to an absolute
   path.
2. That absolute path **must not contain the token `linux`**: `linux` is a
   predefined GCC macro (`= 1`), so a path like `.../linux-7.0.12/...` gets
   mangled to `.../1-7.0.12/...`. Extract the source into a directory named
   e.g. `ksrc` instead of the default `linux-<ver>`.

Both are handled automatically by [`rebuild.sh`](rebuild.sh).

---

## Quick start (Ubuntu, the tested path)

```bash
git clone https://github.com/minavr/amdgpu-disable-dithering
cd amdgpu-disable-dithering
sudo bash setup.sh
#   -> installs build deps, creates & imports a local MOK signing key,
#      installs the automation, and (once the MOK is enrolled) builds+installs
#      the patched module.
# Reboot. In the blue "MOK Manager" screen: Enroll MOK -> enter the one-time
# password you set -> Continue.
sudo amdgpu-nodither-rebuild.sh     # build + sign + install for this kernel
sudo reboot
# verify:
modinfo -F frc_dither amdgpu        # must print:  disabled
```

Then judge the real result: **does your eye strain / nausea go away** after a
while of normal use? That's the only test that ultimately matters.

---

## Step by step (manual / for adapting to other systems)

### 1. Identify your GPU, kernel and session

```bash
lspci -nnk | grep -iA3 -E 'vga|display'   # confirm amdgpu
uname -r                                   # your kernel release
echo "$XDG_SESSION_TYPE"                   # x11 / wayland
```

### 2. Install build dependencies (Debian/Ubuntu)

```bash
sudo apt-get install -y build-essential flex bison libssl-dev libelf-dev \
    libdw-dev bc zstd curl xz-utils mokutil libnotify-bin
```

* `libdw-dev` is required — without it the kernel's `gendwarfksyms` tool
  (used for `MODVERSIONS`) fails with `fatal error: dwarf.h`.
* You also need the **matching kernel headers**: `linux-headers-$(uname -r)`
  (the tested machine had them via `linux-headers-generic-hwe-24.04`).

### 3. Get the kernel source matching your running kernel

Ubuntu's HWE kernel tracks an upstream stable base; read it from the headers'
`Makefile` and download that tarball:

```bash
KDIR=/lib/modules/$(uname -r)/build
V=$(awk -F'= *' '/^VERSION/{print $2}'    $KDIR/Makefile)
P=$(awk -F'= *' '/^PATCHLEVEL/{print $2}' $KDIR/Makefile)
S=$(awk -F'= *' '/^SUBLEVEL/{print $2}'   $KDIR/Makefile)
BASE="$V.$P.$S"                    # e.g. 7.0.12
curl -fLO "https://cdn.kernel.org/pub/linux/kernel/v${V}.x/linux-$BASE.tar.xz"
mkdir ksrc-build && tar -C ksrc-build -xf linux-$BASE.tar.xz
mv ksrc-build/linux-$BASE ksrc-build/ksrc     # dir name WITHOUT the token "linux"
cd ksrc-build/ksrc
```

> If your distro applies large out‑of‑tree changes to the AMD driver you may
> instead need the distro's own kernel source (e.g. `apt-get source`). On the
> tested Ubuntu HWE kernel the upstream stable source compiled cleanly against
> the distro headers.

### 4. Apply the patch (+ marker)

```bash
patch -p1 < /path/to/amdgpu-nodither.patch    # or insert the early return by hand
printf '\n#include <linux/module.h>\nMODULE_INFO(frc_dither, "disabled");\n' \
    >> drivers/gpu/drm/amd/display/dc/core/dc_resource.c
```

### 5. Fix the tracepoint include for out‑of‑tree build

```bash
AMD=$PWD/drivers/gpu/drm/amd/amdgpu
sed -i "s|^#define TRACE_INCLUDE_PATH .*|#define TRACE_INCLUDE_PATH $AMD|" \
    drivers/gpu/drm/amd/amdgpu/amdgpu_trace.h
```

### 6. Build as an external module against the installed kernel tree

```bash
make -C /lib/modules/$(uname -r)/build M="$AMD" modules -j"$(nproc)"
strip --strip-debug "$AMD/amdgpu.ko"          # ~740 MB -> ~40 MB
```

Sanity‑check before trusting it:

```bash
modinfo -F vermagic   "$AMD/amdgpu.ko"        # must equal the stock module's
modinfo -F frc_dither "$AMD/amdgpu.ko"        # must print: disabled
```

### 7. Sign for Secure Boot (skip if Secure Boot is off)

Create a Machine Owner Key once, sign the module, and enroll the key:

```bash
sudo mkdir -p /var/lib/amdgpu-nodither
sudo openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 \
    -keyout /var/lib/amdgpu-nodither/MOK.priv -outform DER \
    -out /var/lib/amdgpu-nodither/MOK.der -subj "/CN=local amdgpu module signing/"
sudo /lib/modules/$(uname -r)/build/scripts/sign-file sha256 \
    /var/lib/amdgpu-nodither/MOK.priv /var/lib/amdgpu-nodither/MOK.der "$AMD/amdgpu.ko"
sudo mokutil --import /var/lib/amdgpu-nodither/MOK.der   # set a one-time password
```

### 8. Install and reboot

```bash
KREL=/lib/modules/$(uname -r)/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.zst
sudo cp -a "$KREL" "$KREL.stock-orig"         # backup!
sudo zstd -q -f -19 "$AMD/amdgpu.ko" -o /tmp/amdgpu.ko.zst
sudo install -m0644 /tmp/amdgpu.ko.zst "$KREL"
sudo depmod "$(uname -r)"
sudo update-initramfs -u -k "$(uname -r)"
sudo reboot
```

On the reboot, **enroll the MOK** in the blue MOK Manager screen (only the first
time). Then verify:

```bash
modinfo -F frc_dither amdgpu     # disabled
```

> **Secure Boot ordering:** don't overwrite the stock module *before* the MOK is
> enrolled — until the key is trusted, lockdown will refuse to load your signed
> module and you'll boot without a GPU driver. Enroll first, then install.

---

## Automated scripts (reference implementation)

These automate everything above for the tested Ubuntu config:

| file | purpose |
|---|---|
| [`amdgpu-nodither.patch`](amdgpu-nodither.patch) | the source patch |
| [`rebuild.sh`](rebuild.sh) | download source, patch, build against KDIR, verify `vermagic` + marker + **`struct module` relocation layout**, sign, install. `--build-only` compiles without installing; `--force` rebuilds even when the installed module already looks patched |
| [`setup.sh`](setup.sh) | one‑time installer: build deps, MOK, automation, first build |
| [`files/zz-amdgpu-nodither`](files/zz-amdgpu-nodither) | `/etc/kernel/postinst.d/` hook — rebuilds the patched module for every newly installed kernel |
| [`files/amdgpu-nodither-rebuild.service`](files/amdgpu-nodither-rebuild.service) | boot‑time fallback that rebuilds if the running kernel is unpatched |
| [`files/amdgpu-nodither-check.*`](files/) | desktop notification if `amdgpu` fails to load at all, or if the running driver is *not* the patched build |

### Persistence across kernel updates

A plain module replacement does **not** survive kernel updates — the next kernel
ships the stock (dithering) module and silently overrides yours. The
`postinst.d` hook rebuilds the patched module automatically whenever a new
kernel is installed (log: `/var/log/amdgpu-nodither.log`). The boot service and
the desktop check are a safety net: if a rebuild ever fails, you get a visible
warning instead of a silent return of the flicker.

### Updating an existing install

The scripts run from `/usr/local/sbin/`, **not** from your clone — the kernel
hook calls `/usr/local/sbin/amdgpu-nodither-rebuild.sh`. Pulling a new version
of this repo therefore changes nothing until you redeploy it:

```bash
git pull
sudo bash setup.sh --no-build        # redeploys the scripts to /usr/local/sbin
sudo amdgpu-nodither-rebuild.sh --force
sudo reboot
```

Skipping the redeploy is exactly how the failure described in
[Post-mortem](#post-mortem-a-kernel-update-left-the-machine-at-1024x768) happened:
a fixed `rebuild.sh` sat in the clone for weeks while the kernel hook kept
running the old, broken one.

---

## Verifying it worked

```bash
# the driver is actually driving a display (not just present as a file):
readlink -f /sys/class/drm/card*/device/driver     # .../drivers/amdgpu
modinfo -F frc_dither amdgpu                       # disabled
xrandr | head -3                                   # your real resolution
```

> `modinfo` reads the module **file on disk**, so it prints `disabled` even when
> no driver is loaded at all. Always check the DRM binding too — that is the one
> test that distinguishes "patched and running" from "patched and dead".

The technical checks only prove the *patched code* is running. The decisive test
is subjective: after normal use, is the eye strain / fatigue / nausea gone?

---

## Recovery

If a boot ends in a black screen, get a terminal (SSH or a TTY) and restore the
stock module:

```bash
KV=$(uname -r)
M=/lib/modules/$KV/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.zst
sudo cp -a "$M.stock-orig" "$M"
sudo depmod "$KV" && sudo update-initramfs -u -k "$KV"
sudo reboot
```

To also disable the automation:

```bash
sudo rm -f /etc/kernel/postinst.d/zz-amdgpu-nodither \
           /etc/xdg/autostart/amdgpu-nodither-check.desktop
sudo systemctl disable --now amdgpu-nodither-rebuild.service
```

---

## Pitfalls we hit (so you don't)

* **`Exec format error` / `Invalid relocation target`** on load → you built
  against a standalone tree; build against `/lib/modules/$(uname -r)/build`.
  This is the nastiest one: the build, the signature and `vermagic` all look
  fine, and the module only dies at load time — see
  [Post-mortem](#post-mortem-a-kernel-update-left-the-machine-at-1024x768).
* **`fatal error: dwarf.h`** during `modules_prepare`/build → install `libdw-dev`.
* **Trace include not found**, or path mangled to `1-<ver>` → fix
  `TRACE_INCLUDE_PATH` and use a source dir without the token `linux`.
* **Signed module still rejected** under Secure Boot → the MOK isn't enrolled
  yet; enroll it (MOK Manager) before relying on the module.
* **`modprobe` succeeds at boot but `/sys/module/amdgpu` is missing** → the
  module loaded then failed init; almost always the relocation issue above.

---

## Post-mortem: a kernel update left the machine at 1024x768

A real failure from this setup, worth reading before you trust any automation
of your own.

**Symptom.** After a routine `apt upgrade` (kernel `7.0.0-28` → `7.0.0-29`) the
desktop came up at **1024×768** and refused every other mode — and stayed that
way across reboots for three days. The GPU was fine; `amdgpu` simply never
loaded, so the display fell back to `simpledrm` on the EFI framebuffer:

```console
$ journalctl -k -b | grep -iE 'amdgpu|relocation'
module: x86/modules: Invalid relocation target, existing value is nonzero
```

**Cause.** A fixed `rebuild.sh` (the KDIR build described above) existed only in
the working copy and had **never been copied to `/usr/local/sbin/`**. So when
the kernel hook fired for the new kernel, it rebuilt the module with the old
standalone‑tree method → the binary carried a different `struct module` layout
than the running kernel expects → the loader rejected it.

The layout difference is directly visible in the module's relocations:

```bash
readelf -r -W amdgpu.ko | grep -A5 gnu.linkonce.this_module   # broken vs. .stock-orig
#  broken build:  cleanup_module @ 0x490
#  stock module:  cleanup_module @ 0x4a8
```

**Why nothing warned.** All three safety nets were blind in the same way — they
tested the module *file*, never the *running* driver:

1. `rebuild.sh` saw `frc_dither=disabled` on disk → "already patched, nothing to
   do" → the boot service's retry did nothing either, forever.
2. The kernel hook's rebuild reported success — the module built and signed
   cleanly; the defect only appears at load time.
3. `amdgpu-nodither-check.sh` tested `modinfo -F frc_dither amdgpu`, which reads
   that same file on disk, so it stayed quiet while there was no driver at all.

**Fixes now in this repo.**

* `rebuild.sh` compares the `.gnu.linkonce.this_module` relocation offsets of
  the module it just built against the stock module, and **refuses to install**
  on a mismatch — a missing driver is far worse than a dithering one.
* The same comparison runs in the "already patched" shortcut, so a module that
  cannot load triggers a rebuild instead of "nothing to do".
* `rebuild.sh --force` skips that shortcut entirely.
* `amdgpu-nodither-check.sh` first checks whether `amdgpu` is bound to a DRM
  card, and shouts if the driver never loaded.

**The general lesson:** a check that reads an artefact on disk proves only that
the artefact exists. If what you care about is a *running* component, test the
running component.

---

## Credits

Developed on real hardware with the help of Claude Code. Contributions/reports
from other GPUs, kernels and distros are very welcome — especially data points
on how far this generalises.
