# TAS2783 speakers on the ASUS ProArt PX13 (HN7306) under Linux

Working **stereo** on the internal speakers of the ASUS ProArt PX13 (HN7306*,
AMD Strix Halo) — on a **stock kernel ≥ 7.1**, surviving kernel and
alsa-ucm-conf updates.

**Every SKU.** Nothing is hardcoded to one machine: the ALSA card index, the
card long name, the ACP PCI address and the PipeWire node names are all probed
at install time (`lib/px13-detect.sh`), and the installer now **fails loudly**
instead of exiting 0 without sound. See
[SKU independence](#sku-independence-why-it-used-to-break-on-other-px13s).

Tested on CachyOS `linux-cachyos 7.1.3-1` (HN7306EAC) and reported working on
HN7306EA / HN7306EA-LX005X. Should work on Arch, Fedora and other distros with
minor path adjustments.

> **On kernels < 7.1** the tas2783 driver in mainline was not usable and the
> fix was a patched kernel (nealstar's 16-patch series, packaged for CachyOS
> as `linux-cachyos-px13` + `asus-proart-px13-quirks`). That method still
> works but requires a kernel rebuild on every update. The original guide and
> patch set are kept in [`patches/`](patches/) for reference. Everything
> below is for **stock kernels ≥ 7.1**.

---

## TL;DR — what is broken on stock ≥ 7.1 and how this repo fixes it

TI upstreamed a new tas2783 driver in Linux 7.1 (it is **not** nealstar's
series). On the PX13 two problems remain:

| # | Problem | Symptom | Fix in this repo |
|---|---------|---------|------------------|
| 1 | The machine driver does not tag the card with `spk:tas2783`, so `alsa-ucm-conf` never creates the Speaker device | No sound at all / "Dummy Output" / only pro-audio profile | UCM **long-name override** in `conf.d/amd-soundwire/` forcing `SpeakerCodec = tas2783` |
| 2 | The driver initializes **both** amps with DSP cluster index `0x01` (the ASUS ACPI tables carry no usable SDCA/DisCo function data, so the driver falls back to a static init sequence) | Mono from **one** speaker — which one can change between boots — or a phantom "center" image | Small **DKMS module** (stock driver + channel-selection control) + UCM setting `Left`/`Right` per amp |
| 3 | s2idle kills the audio stack in **two layers**: the slaves drop off the SoundWire bus (a plain PCI unbind/bind of `snd_pci_ps` does **not** bring them back), and even when the bus still reports `Attached` the TAS2783 DSP has lost its **firmware** (`error playback without fw download` — silent mute while every mixer level looks fine) | Speakers dead/mute after suspend; the vanished card also wedges the WirePlumber graph so even **Bluetooth** audio stops | Detached `systemd-sleep` hook (`systemd-run`) + full module-stack reload → re-probe re-downloads the firmware ([details](#suspendresume-s2idle-recovery)) |

Bug #2 is **not** fixed in 7.2 either (checked `v7.2-rc1`: same fallback
init). The one-speaker report in
[CachyOS/linux-cachyos#737](https://github.com/CachyOS/linux-cachyos/issues/737)
on kernel 7.1.1 is exactly this.

Firmware note: `linux-firmware ≥ 20260519` ships the amp firmware as
`ti/audio/tas2783/1714-1-0x8.bin` / `1714-1-0xB.bin` — **no more extracting
blobs from the Windows driver**.

---

## Quick install

```bash
git clone https://github.com/ftoleedo/px13-audio-fix.git && cd px13-audio-fix
bash install-durable.sh        # asks for sudo when needed
# reboot once if the module can't be live-reloaded
```

`sudo bash install-durable.sh` works too: the installer needs root for the
module and the UCM files but must **not** be root for the PipeWire half
(`systemctl --user` does not exist for root), so when started under sudo it
drops back to `$SUDO_USER` for those steps. If it cannot find a session to drop
back to it says so instead of half-failing (`sudo PX13_USER=<you> bash ...`).

The script:

0. **Probes** the card index, the ALSA driver name and the `CardLongName`, and
   aborts with a diagnostic if there is no SoundWire card or no TAS2783 amp.
1. Installs the patched `snd-soc-tas2783-sdw` module via **DKMS**
   (auto-rebuilds on every kernel update) — falls back to a manual build
   into `/lib/modules/$(uname -r)/updates/` if dkms is not installed.
2. Installs the three UCM files under the long name **of your machine**, and
   removes any override this repo previously installed under a different SKU
   name (dead weight — UCM never reads it).
3. **Verifies** that UCM now exposes a `Speaker` device and exits non-zero with
   diagnostics if it does not. No more silent success.
4. Restarts PipeWire, selects the HiFi profile, checks the SoundWire
   peripherals, saves the ALSA state.

The suspend/resume recovery is a separate, optional step:

```bash
bash install-resume-recovery.sh        # hook + recovery script + dry run
```

---

## SKU independence (why it used to break on other PX13s)

The first version of this repo hardcoded four machine-specific values. Three of
them were cosmetic; one silently broke every laptop that was not the machine it
was written on:

| Hardcoded | Actually varies with | Symptom when wrong |
|---|---|---|
| `LONG=ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC` | **the SKU** (DMI product name) | **silent total failure** |
| `CARD=1` | boot order / other sound cards | wrong card poked |
| `alsa_card.pci-0000_c4_00.5-platform-amd_sdw` | ACP PCI address | profile switch fails |
| `PCI=0000:c4:00.5` | ACP PCI address | resume recovery does nothing |

The first one is fatal because of how ALSA UCM resolves configs
(`/usr/share/alsa/ucm2/ucm.conf`):

```
conf.d/${CardDriver}/${CardLongName}.conf     <- probed first
conf.d/${CardDriver}/${CardDriver}.conf       <- package-owned fallback
```

`CardLongName` is built from DMI, so it differs per SKU:

```
ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC    128 GB / GOPRO
ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EA-1.0-HN7306EA      64 GB, LX005X, ...
```

An override installed under the wrong name is **never read**. UCM falls back to
the stock config, the HiFi profile has no Speaker device, PipeWire shows a
dummy sink — and the old installer still printed its steps and exited 0.

Check yours with:

```bash
amixer -c "$(cat /proc/asound/cards | grep -i soundwire | awk '{print $1}')" info
#   Card sysdefault:1 'amdsoundwire'/'<-- this string is the long name -->'
```

Since then everything is probed at runtime and the installer refuses to finish
without a working Speaker device. Found by **@jamescutts** (silent failure on a
64 GB HN7306EA), pinpointed to that variable by **@dmicheel** (who hit it on a
non-GOPRO HN7306EA-LX005X too) and confirmed by **@DevGrishin**, in
[CachyOS/linux-cachyos#737](https://github.com/CachyOS/linux-cachyos/issues/737).

---

## Suspend/resume (s2idle) recovery

Three independent failures happen around s2idle on this machine, plus one
self-inflicted trap. All four were diagnosed on `linux-cachyos 7.1.5-1`:

1. **The SoundWire slaves vanish.** After resume the devices under
   `/sys/bus/soundwire/devices/sdw:0:1:*` are gone (or stuck `UNATTACHED`).
   A plain unbind/bind of the `snd_pci_ps` PCI device — the classic advice,
   and what the old hook here did — no longer re-enumerates them.
2. **The TAS2783 firmware is wiped even when the bus looks healthy.** On some
   resumes the slaves stay `Attached`, every mixer switch is on, the sink is
   unmuted, the HiFi profile is active — and the speakers are silent. dmesg
   has the smoking gun: `error playback without fw download`. The amp's DSP
   lost its firmware and only a full driver **re-probe** re-downloads it
   (`/lib/firmware/ti/audio/tas2783/`). This is why "check if it's Attached
   and skip" is a bug: recovery must run **unconditionally**.
3. **The wedged card takes Bluetooth down with it.** The vanished ALSA card
   leaves WirePlumber's graph broken ("PipeWire links failed to activate"):
   BT devices connect but no stream can link to them. Only a PipeWire/
   WirePlumber restart clears it.
4. **The trap: doing any of this inline in a system-sleep hook.** Post hooks
   block `systemd-suspend.service`, and systemd keeps the user session
   (`user.slice`) **frozen** until the service finishes. An inline recovery
   means a black screen for up to the 90 s service timeout on every wake —
   and a guaranteed deadlock if the hook tries to restart the session's
   PipeWire (which is frozen, waiting for the hook).

The fix is therefore split:

| File (repo) | Installed to | Purpose |
|---|---|---|
| `50-px13-soundwire` | `/usr/lib/systemd/system-sleep/` | post hook: dispatches the recovery as a transient unit (`systemd-run --no-block --collect`) and exits immediately — the screen is back in ~3 s |
| `px13-soundwire-recover.sh` | `/usr/local/lib/` | the actual recovery, ~30 s in the background: unbind PCI → unload the whole SoundWire/ACP module stack (children first) → reload → wait for `Attached` (probe re-downloads the amp firmware) → **always** restart the session PipeWire → reapply HiFi profile, unmute, restore default sink only if nothing better holds it |
| `lib/px13-detect.sh` | `/usr/local/lib/px13-audio-detect.sh` | the probes, shared by every script |
| — | `/etc/px13-audio-fix.conf` | cache of the ACP PCI address and long name, written while the hardware is healthy — the recovery needs them precisely when the card has already vanished from `/proc/asound` |
| `test-sdw-module-reload.sh` | — | interactive version of the same recovery; `sudo` it to bring audio back *right now* (plays a test sound and reports SUCCESS/FAIL) |

Install all of it with `bash install-resume-recovery.sh` (it also does a dry run
with a healthy bus, so you find out it works without having to suspend).

Everything is logged to `/var/log/px13-soundwire-resume.log`.

---

## What gets installed where

| File (repo) | Installed to | Purpose |
|---|---|---|
| `module/` | `/usr/src/snd-soc-tas2783-sdw-px13-1.0` (DKMS) | Stock 7.1.y tas2783 driver + `Channel Playback` control |
| `configs/ucm-card-override.conf.in` | `/usr/share/alsa/ucm2/conf.d/<CardDriver>/<CardLongName>.conf` — **both probed**, template placeholders substituted at install time | Forces the speaker codec; **unowned by any package** → survives `alsa-ucm-conf` updates |
| `lib/px13-detect.sh` | `/usr/local/lib/px13-audio-detect.sh` | Runtime probes: card, driver, long name, amp count, ACP PCI, PipeWire names |
| `configs/sof-soundwire_tas2783.conf` | `/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` | Speaker device for the HiFi profile; sets `tas2783-1 = Left`, `tas2783-2 = Right` on every profile activation (guarded on the **second** amp existing, so a single-amp variant still gets a mono Speaker instead of a broken profile) |
| `configs/codecs_tas2783_init.conf` | `/usr/share/alsa/ucm2/codecs/tas2783/init.conf` | Volume-control remap (supports both driver generations) |
| `50-px13-soundwire` | `/usr/lib/systemd/system-sleep/` | Recovers SoundWire after s2idle |
| `configs/99-echo-cancel.conf` | `~/.config/pipewire/pipewire.conf.d/` | Optional: echo-cancelled mic source for calls |
| `configs/51-amd-sdw-channels.conf` | `~/.config/wireplumber/wireplumber.conf.d/` | Optional: FL/FR channel positions on the speaker node |

### The kernel-side patch (module/)

The DKMS module is the stock `linux-7.1.y` `tas2783-sdw.c` with one
functional addition — nealstar's channel-selection control rebased onto the
upstream driver:

```
tas2783-N Channel Playback : enum { Off, Left, Right }
```

It writes the SDCA control `PPU21 / UDMPU CLUSTERINDEX` (values `0 / 1 / 4`),
which tells each amp's DSP which channel of the stereo stream to render.
Without it both amps stay at the boot value `0x01` written by
`tas2783_init_seq`.

---

## Verifying

```bash
uname -r                                   # stock kernel, >= 7.1
modinfo -k $(uname -r) snd_soc_tas2783_sdw -F filename
#   -> .../updates/... (the DKMS/patched module, not .../kernel/sound/...)

C=$(awk '/soundwire/ && /^ *[0-9]+ \[/ {print $1; exit}' /proc/asound/cards)
alsaucm -c "$C" list _devices/HiFi | grep Speaker      # must print "Speaker"
amixer -D "hw:$C" cget name='tas2783-1 Channel Playback'   # values=1 (Left)
amixer -D "hw:$C" cget name='tas2783-2 Channel Playback'   # values=2 (Right)

pactl list cards | grep "Active Profile"   # HiFi
speaker-test -D pulse -c2 -l1 -t wav       # voice L/R from the correct side
```

If the sides are physically swapped, exchange the two `cset` values in
`/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` and restart PipeWire.

---

## Troubleshooting

- **"Dummy output" / no Speaker device** — the long-name override is missing or
  installed under another SKU's name. `bash install-durable.sh` now detects the
  right name and refuses to finish without a Speaker device; if you are fixing
  it by hand, compare `amixer -c <card> info` (the string after the `/`) with
  the file names in `/usr/share/alsa/ucm2/conf.d/amd-soundwire/`. As a last
  resort you can force it: `PX13_LONGNAME='<name>' bash install-durable.sh`.
- **Mono / one speaker only** — the stock module is loaded instead of the
  patched one (`modinfo -k $(uname -r) snd_soc_tas2783_sdw -F filename`
  must point into `updates/`), or the `Channel Playback` controls are absent.
  After a kernel update without dkms, rebuild: `cd module && make LLVM=1`
  and reinstall.
- **Sound goes to pro-audio profile / "Invalid argument"** — switch profile:
  `pactl set-card-profile "$(pactl list short cards | awk '/sdw/{print $2;exit}')" HiFi`.
- **Dead after suspend** — `bash install-resume-recovery.sh`; recover
  immediately with `sudo /usr/local/lib/px13-soundwire-recover.sh` or
  `sudo ./test-sdw-module-reload.sh`.
- **Silent speakers although *everything* looks right** (sink default and
  unmuted, HiFi active, `amixer` switches on) after a resume — that is the
  wiped TAS2783 firmware (`dmesg | grep 'without fw download'`). Same fix as
  above: full module reload; a rebind alone will not re-download it.
- **Bluetooth connects but plays nothing** after a resume — wedged WirePlumber
  graph: `systemctl --user restart wireplumber pipewire pipewire-pulse`. If
  the BT device then only offers headset (mono) profiles, disconnect and
  reconnect it to rediscover A2DP.
- **Audio jumps to Bluetooth after profile switch** — set the default sink
  once: `wpctl set-default <id of Audio Coprocessor Speaker>`.
- **`Failed to connect to user scope bus ... $DBUS_SESSION_BUS_ADDRESS and
  $XDG_RUNTIME_DIR not defined`** — you are on a version older than `ff53876`
  and ran the installer entirely as root. Pull and re-run; the system half is
  already installed, the script is idempotent.

---

## Upstream status

The proper fix belongs in the kernel: either the `Channel Playback` control
or an ACPI/platform quirk mapping each amp's SoundWire `unique_id` to a
channel, since the PX13's ACPI provides no usable SDCA function data
(`function type only supported as DisCo constant`). Until something lands,
this repo keeps working setups alive across updates. Progress is tracked in
[CachyOS/linux-cachyos#737](https://github.com/CachyOS/linux-cachyos/issues/737).

The s2idle behavior is a **second kernel bug** worth reporting upstream
(ALSA/SoundWire): `tas2783-sdw` should re-download the DSP firmware in its
system-resume path (today it can come back `Attached` with no firmware and
mutes silently), and the AMD SoundWire manager (`soundwire_amd` /
`snd_pci_ps`) fails to re-enumerate its slaves after s2idle on Strix Halo —
a full module reload should not be necessary.

## Credits

- **nealstar** — original 16-patch series, including the channel-selection
  control this module carries.
- **fecet** — CachyOS packaging (`linux-cachyos-px13`,
  `asus-proart-px13-quirks`) for the < 7.1 era.
- **TI / Niranjan H Y, Baojun Xu, Kevin Lu** — upstream tas2783 driver.
- **jamescutts, dmicheel, DevGrishin** — found and pinpointed the silent
  SKU dependency (the UCM long name), which is what made this repo
  SKU-independent.

## License

Guide and scripts: CC0. Kernel module: GPL-2.0 (derived from the upstream
driver).
