# TAS2783 speakers on the ASUS ProArt PX13 (HN7306EA) under Linux

Working **stereo** on the internal speakers of the ASUS ProArt PX13 (HN7306EA,
AMD Strix Halo) — on a **stock kernel ≥ 7.1**, surviving kernel and
alsa-ucm-conf updates.

Tested on CachyOS `linux-cachyos 7.1.3-1`. Should work on Arch, Fedora and
other distros with minor path adjustments.

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

The script:

1. Installs the patched `snd-soc-tas2783-sdw` module via **DKMS**
   (auto-rebuilds on every kernel update) — falls back to a manual build
   into `/lib/modules/$(uname -r)/updates/` if dkms is not installed.
2. Installs the three UCM files (see below).
3. Restarts PipeWire, selects the HiFi profile, checks the SoundWire
   peripherals, saves the ALSA state.

The resume recovery is separate (it is host-specific — PCI address and module
list mapped on this machine, kernel 7.1.5):

```bash
sudo install -m755 50-px13-soundwire /usr/lib/systemd/system-sleep/
sudo install -m755 px13-soundwire-recover.sh /usr/local/lib/
```

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
| `test-sdw-module-reload.sh` | — | interactive version of the same recovery; `sudo` it to bring audio back *right now* (plays a test sound and reports SUCCESS/FAIL) |

Everything is logged to `/var/log/px13-soundwire-resume.log`.

---

## What gets installed where

| File (repo) | Installed to | Purpose |
|---|---|---|
| `module/` | `/usr/src/snd-soc-tas2783-sdw-px13-1.0` (DKMS) | Stock 7.1.y tas2783 driver + `Channel Playback` control |
| `configs/px13-longname-override.conf` | `/usr/share/alsa/ucm2/conf.d/amd-soundwire/ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC.conf` | Forces the speaker codec; **unowned by any package** → survives `alsa-ucm-conf` updates |
| `configs/sof-soundwire_tas2783.conf` | `/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` | Speaker device for the HiFi profile; sets `tas2783-1 = Left`, `tas2783-2 = Right` on every profile activation (guarded by `ControlExists`) |
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

amixer -D hw:1 cget name='tas2783-1 Channel Playback'   # values=1 (Left)
amixer -D hw:1 cget name='tas2783-2 Channel Playback'   # values=2 (Right)

pactl list cards | grep "Active Profile"   # HiFi
speaker-test -D pulse -c2 -l1 -t wav       # voice L/R from the correct side
```

If the sides are physically swapped, exchange the two `cset` values in
`/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` and restart PipeWire.

---

## Troubleshooting

- **"Dummy output" / no Speaker device** — the long-name override is not
  installed or the card long-name differs. Check
  `cat /proc/asound/card1/id` and `alsaucm -c1 list _devices/HiFi`.
- **Mono / one speaker only** — the stock module is loaded instead of the
  patched one (`modinfo -k $(uname -r) snd_soc_tas2783_sdw -F filename`
  must point into `updates/`), or the `Channel Playback` controls are absent.
  After a kernel update without dkms, rebuild: `cd module && make LLVM=1`
  and reinstall.
- **Sound goes to pro-audio profile / "Invalid argument"** — switch profile:
  `pactl set-card-profile alsa_card.pci-0000_c4_00.5-platform-amd_sdw HiFi`.
- **Dead after suspend** — install the resume pair (hook + recover script);
  recover immediately with `sudo /usr/local/lib/px13-soundwire-recover.sh`
  or `sudo ./test-sdw-module-reload.sh`.
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

## License

Guide and scripts: CC0. Kernel module: GPL-2.0 (derived from the upstream
driver).
