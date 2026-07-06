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
| 3 | The AMD SoundWire controller (`snd_pci_ps`) does not survive s2idle | Speakers dead after suspend/resume | `systemd-sleep` hook that rebinds the controller and restores the HiFi profile |

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

The resume hook is separate (it is host-specific):

```bash
sudo install -m755 50-px13-soundwire /usr/lib/systemd/system-sleep/
```

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
- **Dead after suspend** — install the resume hook; run it manually to
  recover now: `sudo /usr/lib/systemd/system-sleep/50-px13-soundwire post suspend`.
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

## Credits

- **nealstar** — original 16-patch series, including the channel-selection
  control this module carries.
- **fecet** — CachyOS packaging (`linux-cachyos-px13`,
  `asus-proart-px13-quirks`) for the < 7.1 era.
- **TI / Niranjan H Y, Baojun Xu, Kevin Lu** — upstream tas2783 driver.

## License

Guide and scripts: CC0. Kernel module: GPL-2.0 (derived from the upstream
driver).
