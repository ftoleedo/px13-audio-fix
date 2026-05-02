# Getting TAS2783 Speakers Working on ASUS ProArt PX13 (HN7306EA) under Linux

A complete step-by-step guide to fix audio output on the internal speakers of the ASUS ProArt PX13 (model HN7306EA, AMD Strix Halo).

Tested on **CachyOS** with kernel `linux-cachyos-rc 7.1.0-rc1`. Should also work on Arch, Fedora, and other distros with minor adjustments.

---

## TL;DR

The PX13 ships with a **TAS2783** SoundWire smart amplifier driving the internal speakers. Out of the box on Linux:

1. The kernel has the driver (since 6.x), but **needs 16 unmerged patches** to expose the proper ALSA controls.
2. Even with the patches, **ALSA UCM configs** for `tas2783` don't exist in `alsa-ucm-conf` (only RT and Cirrus codecs are covered).
3. PipeWire defaults to **pro-audio profile**, which fails to open the device. You need to switch to the **HiFi profile**.
4. The two amps (`tas2783-1`, `tas2783-2`) require **manual channel assignment** — by default they may both be `Off` or both pointing to the same channel.
5. The physical channel mapping is **inverted** vs. what you'd expect: `tas2783-1` is the **left** speaker, `tas2783-2` is the **right** speaker (counter-intuitive given the numbering).

This guide walks through each fix.

---

## Hardware overview

```
$ lspci | grep -i audio
c4:00.1 Audio device: Advanced Micro Devices, Inc. [AMD/ATI] Rembrandt Radeon HD Audio Controller
c4:00.5 Multimedia controller: Advanced Micro Devices, Inc. [AMD] ACP/ACP3X/ACP6x Audio Coprocessor

$ cat /proc/asound/cards
 0 [Generic        ]: HDA-Intel - HD-Audio Generic
                      HD-Audio Generic at 0xa0440000 irq 126
 1 [amdsoundwire   ]: amd-soundwire - amd-soundwire
                      ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC

# Components on card 1:
$ pactl list cards | grep alsa.components
alsa.components = " cfg-amp:2 mic:acp-dmic cfg-mics:1 hs:rt721 spk:tas2783"
```

So the codec stack is:
- **`spk:tas2783`** — internal stereo speakers (this is what we're fixing)
- **`hs:rt721`** — headphone jack and headset mic (Realtek RT721 SDCA)
- **`mic:acp-dmic`** — internal digital mic array
- **`cfg-amp:2`** — two TAS2783 amps (left + right)

---

## Prerequisites

You need:

1. A SoundWire-capable kernel (≥ 6.10 has the driver, but you need 7.1.0-rc1+ for the fixes).
2. Build tools: `base-devel`, `bc`, `cpio`, `xz`, `pahole`, `clang`, `lld`, `llvm`, `rust`.
3. `pipewire`, `wireplumber`, `alsa-ucm-conf`.
4. About **30–60 GB of free disk** during kernel build.

---

## Step 1 — Get the firmware files

The TAS2783 amp needs proprietary firmware extracted from the official ASUS Windows driver:

1. Download the audio driver from ASUS:
   https://www.asus.com/laptops/for-creators/proart/proart-px13-hn7306/helpdesk_download?model2Name=HN7306EA
2. Extract the package on a Windows machine (or with `7z` / `cabextract` on Linux).
3. Inside the `Firmwares` folder you'll find:
   - `1714-1-0x8.bin`
   - `1714-1-0xB.bin`
4. **Rename** them to drop the `0x`:
   - `1714-1-8.bin`
   - `1714-1-B.bin`
5. Copy both to `/lib/firmware/`:

```bash
sudo cp 1714-1-8.bin 1714-1-B.bin /lib/firmware/
```

The naming is **case-sensitive** — uppercase `B`, lowercase `bin`.

---

## Step 2 — Get the 16 kernel patches

The patches live in [CachyOS issue #737](https://github.com/CachyOS/linux-cachyos/issues/737) as comment attachments. Download all 16 with this script:

```bash
mkdir -p ~/tas2783-patches && cd ~/tas2783-patches

# Mapping of GitHub user-attachment IDs to filenames
declare -A patches=(
  [27120016]="0001-ALSA-tas2783-sdw-add-Playback-to-volume-control.patch"
  [27120027]="0002-Names-to-match-snd_soc_dai_driver-playback-capturest.patch"
  [27120020]="0003-removed-unused-fields.patch"
  [27120015]="0004-SOC_SINGLE_RANGE_TLV-uses-snd_soc_get_volsw-snd_soc_.patch"
  [27120014]="0005-dev_set_drvdata-already-called-intas_sdw_probe.patch"
  [27120019]="0006-refactor-setting-sa_func_data.patch"
  [27120017]="0007-check-AF01-for-init-data.patch"
  [27120022]="0008-setup-ports.patch"
  [27120018]="0009-Already-set-by-SOC_SINGLE_RANGE_TLV-Speaker-Playback.patch"
  [27120023]="0010-control-to-set-channel.patch"
  [27120028]="0011-mute-unmute-using-SND_SOC_DAPM_SWITCH.patch"
  [27120029]="0012-use-SND_SOC_DAPM_REG-to-power-on-off.patch"
  [27120024]="0013-reattach-after-resume.patch"
  [27135485]="0014-defer-check.patch"
  [27120021]="0015-to-help-alsa-find-them.patch"
  [27120026]="0016-cleanup-controls.patch"
)

for id in "${!patches[@]}"; do
  fname="${patches[$id]}"
  curl -sL -o "$fname" "https://github.com/user-attachments/files/${id}/${fname}"
done
ls *.patch | wc -l   # should print 16
```

### What each patch does (briefly)

| # | Title | Effect |
|---|---|---|
| 0001 | add Playback to volume control | renames `Amp Volume` → `Amp Playback Volume` |
| 0002 | match snd_soc_dai_driver names | aligns DAI names with playback/capture stream |
| 0003 | removed unused fields | cleanup |
| 0004 | SOC_SINGLE_RANGE_TLV uses get_volsw | proper TLV volume reading |
| 0005 | dev_set_drvdata already called | cleanup |
| 0006 | refactor sa_func_data | code reorganization |
| 0007 | check AF01 for init data | firmware init check |
| 0008 | setup ports | SoundWire port wiring |
| 0009 | Speaker Playback already set | naming consistency |
| 0010 | control to set channel | **adds the `Channel Playback` enum (Left/Right/Off)** — critical for stereo |
| 0011 | mute-unmute via SND_SOC_DAPM_SWITCH | adds DAPM switches for amp/speaker |
| 0012 | use SND_SOC_DAPM_REG for power | proper power management |
| 0013 | reattach after resume | fixes audio after suspend/resume |
| 0014 | defer check | timing fix during probe |
| 0015 | help alsa find them | exposes controls properly |
| 0016 | cleanup controls | final cleanup |

---

## Step 3 — Get the userspace configs

Five configuration files from the same issue (different comments):

```bash
mkdir -p ~/tas2783-configs && cd ~/tas2783-configs

curl -sL -o codecs_tas2783_init.conf       https://github.com/user-attachments/files/27120346/codecs_tas2783_init.conf.txt
curl -sL -o sof-soundwire_acp-dmic.conf    https://github.com/user-attachments/files/27120348/sof-soundwire_acp-dmic.conf.txt
curl -sL -o sof-soundwire_tas2783.conf     https://github.com/user-attachments/files/27120347/sof-soundwire_tas2783.conf.txt
curl -sL -o 99-echo-cancel.conf            https://github.com/user-attachments/files/27120651/99-echo-cancel.conf.txt
curl -sL -o 51-amd-sdw-channels.conf       https://github.com/user-attachments/files/27120709/51-amd-sdw-channels.conf.txt
```

### What each does

| File | Goes to | Purpose |
|---|---|---|
| `codecs_tas2783_init.conf` | `/usr/share/alsa/ucm2/codecs/tas2783/init.conf` | UCM init macros for TAS2783 |
| `sof-soundwire_tas2783.conf` | `/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` | UCM "HiFi" speaker definition |
| `sof-soundwire_acp-dmic.conf` | `/usr/share/alsa/ucm2/sof-soundwire/acp-dmic.conf` | UCM digital mic definition |
| `99-echo-cancel.conf` | `~/.config/pipewire/pipewire.conf.d/` | PipeWire WebRTC echo cancellation for the mic |
| `51-amd-sdw-channels.conf` | `~/.config/wireplumber/wireplumber.conf.d/` | WirePlumber channel position (FL/FR) on the speaker node |

---

## Step 4 — Build a kernel with the patches (CachyOS example)

If you're on CachyOS, the cleanest approach is to clone the kernel PKGBUILD and add the patches.

```bash
cd ~
git clone --depth 1 https://github.com/CachyOS/linux-cachyos.git
cd linux-cachyos/linux-cachyos-rc

# Copy patches into the PKGBUILD directory, prefixed to avoid name collisions
cp ~/tas2783-patches/*.patch .
for f in 00*.patch; do mv "$f" "tas2783-$f"; done
```

Edit `PKGBUILD` and **add the 16 patches to the source array**. Find the line `source=(...)` near line 220 and append, just after the `)`:

```bash
# TAS2783 SoundWire patches for ASUS ProArt PX13 (HN7306EA)
source+=(
    tas2783-0001-ALSA-tas2783-sdw-add-Playback-to-volume-control.patch
    tas2783-0002-Names-to-match-snd_soc_dai_driver-playback-capturest.patch
    tas2783-0003-removed-unused-fields.patch
    tas2783-0004-SOC_SINGLE_RANGE_TLV-uses-snd_soc_get_volsw-snd_soc_.patch
    tas2783-0005-dev_set_drvdata-already-called-intas_sdw_probe.patch
    tas2783-0006-refactor-setting-sa_func_data.patch
    tas2783-0007-check-AF01-for-init-data.patch
    tas2783-0008-setup-ports.patch
    tas2783-0009-Already-set-by-SOC_SINGLE_RANGE_TLV-Speaker-Playback.patch
    tas2783-0010-control-to-set-channel.patch
    tas2783-0011-mute-unmute-using-SND_SOC_DAPM_SWITCH.patch
    tas2783-0012-use-SND_SOC_DAPM_REG-to-power-on-off.patch
    tas2783-0013-reattach-after-resume.patch
    tas2783-0014-defer-check.patch
    tas2783-0015-to-help-alsa-find-them.patch
    tas2783-0016-cleanup-controls.patch
)
```

Then find the `b2sums=(...)` array (near line 819) and add 16 `SKIP` entries **between** the existing checksums for `config` and `dkms-clang.patch`:

```bash
b2sums=('<tarball-sum>'
        '<config-sum>'
        SKIP SKIP SKIP SKIP SKIP SKIP SKIP SKIP
        SKIP SKIP SKIP SKIP SKIP SKIP SKIP SKIP
        '<dkms-clang-sum>')
```

> **⚠ Important:** the order of `b2sums` must match the order of `source`. Since the 16 tas2783 patches are inserted *before* the LTO-conditional `dkms-clang.patch`, the SKIPs go between the config sum and the dkms-clang sum.

The CachyOS PKGBUILD's `prepare()` function automatically applies any `*.patch` in the `source` array — no further changes needed.

Now build:

```bash
makepkg -s
```

This takes 30–60 minutes on Strix Halo. You'll get two packages:
- `linux-cachyos-rc-7.1.rc1-2-x86_64.pkg.tar.zst`
- `linux-cachyos-rc-headers-7.1.rc1-2-x86_64.pkg.tar.zst`

Install them:

```bash
sudo pacman -U linux-cachyos-rc-*.pkg.tar.zst
```

Reboot, **selecting `linux-cachyos-rc` in the bootloader**.

### For non-CachyOS distros

Same idea: clone your kernel source, apply the 16 patches with `git am`, build, install. The patches apply cleanly on `linux-mainline` 7.1-rc1 and later.

---

## Step 5 — Verify the patches are active

After rebooting into the new kernel:

```bash
$ uname -r
7.1.0-rc1-2-cachyos-rc

$ amixer -c1 contents | grep -E "Speaker Playback|Channel Playback"
numid=27,iface=MIXER,name='tas2783-1 Speaker Playback Switch'
numid=10,iface=MIXER,name='tas2783-1 Speaker Playback Volume'
numid=29,iface=MIXER,name='tas2783-2 Speaker Playback Switch'
numid=13,iface=MIXER,name='tas2783-2 Speaker Playback Volume'
numid=11,iface=MIXER,name='tas2783-1 Channel Playback'
numid=14,iface=MIXER,name='tas2783-2 Channel Playback'
```

If you see **`Speaker Playback Switch`** and **`Channel Playback`**, you're good. If you only see `Amp Volume`/`Speaker Volume` (no `Playback`), you're on the unpatched kernel — bootloader picked the wrong entry.

---

## Step 6 — Install the userspace configs

```bash
cd ~/tas2783-configs

# UCM (system-wide)
sudo install -d /usr/share/alsa/ucm2/codecs/tas2783
sudo install -m644 codecs_tas2783_init.conf       /usr/share/alsa/ucm2/codecs/tas2783/init.conf
sudo install -m644 sof-soundwire_tas2783.conf     /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
sudo install -m644 sof-soundwire_acp-dmic.conf    /usr/share/alsa/ucm2/sof-soundwire/acp-dmic.conf

# Update the sof-soundwire regex to recognize tas2783 as a speaker codec
sudo sed -i 's|Regex "(rt1318(-1)?\|cs35l56(-bridge)?)"|Regex "(rt1318(-1)?\|cs35l56(-bridge)?\|tas2783(-1)?)"|' \
    /usr/share/alsa/ucm2/sof-soundwire/sof-soundwire.conf

# WirePlumber (per-user)
mkdir -p ~/.config/wireplumber/wireplumber.conf.d/
install -m644 51-amd-sdw-channels.conf ~/.config/wireplumber/wireplumber.conf.d/

# PipeWire echo cancellation (per-user)
mkdir -p ~/.config/pipewire/pipewire.conf.d/
install -m644 99-echo-cancel.conf ~/.config/pipewire/pipewire.conf.d/

# Restart PipeWire stack
systemctl --user restart pipewire pipewire-pulse wireplumber
```

> **Note:** if you previously created a custom WirePlumber rule that forced the card to `pro-audio` profile (a common workaround), **disable it now** — it will fight with the HiFi profile. Look for files like `~/.config/wireplumber/wireplumber.conf.d/51-strix-halo-audio.conf` containing `device.profile = "pro-audio"` and rename them to `*.disabled`.

---

## Step 7 — Switch the card profile to HiFi

This is **the single most important step** if you've been using the pro-audio workaround. The HiFi profile is created by the UCM configs you just installed; you need to actually select it.

```bash
# Verify HiFi profile is now available
$ pactl list cards | grep -A4 "amd_sdw" | grep -E "Active Profile|^\s+(HiFi|pro-audio):"
        HiFi: Play HiFi quality Music (sinks: 2, sources: 2, priority: 8600, available: yes)
        pro-audio: Pro Audio (sinks: 2, sources: 3, priority: 1, available: yes)
    Active Profile: pro-audio    # ← still on pro-audio

# Switch to HiFi
$ pactl set-card-profile alsa_card.pci-0000_c4_00.5-platform-amd_sdw HiFi
```

Now `wpctl status` should show clean sink names instead of the cryptic `pro-output-N`:

```
Sinks:
    72. Audio Coprocessor Speaker     [vol: 1.00]
    90. Audio Coprocessor Headphones  [vol: 1.00]
```

Set the speaker as default:

```bash
wpctl set-default 72   # use the actual ID from wpctl status
```

---

## Step 8 — **The gotcha: channel mapping**

If you `paplay` something now, you may notice:

- **No sound at all**, or
- **Sound only from one speaker**, or
- **Sound from both speakers but everything sounds mono**.

This is because the two amplifiers (`tas2783-1` and `tas2783-2`) each need to be told **which channel of the stereo stream they should reproduce**. The patch `0010-control-to-set-channel` adds an enum control with values `Off`, `Left`, `Right`. By default both amps may end up `Off` or both on the same channel — depending on the driver's init order.

Check current state:

```bash
$ amixer -c1 cget name='tas2783-1 Channel Playback'
numid=11,iface=MIXER,name='tas2783-1 Channel Playback'
  ; type=ENUMERATED,access=rw------,values=1,items=3
  ; Item #0 'Off'
  ; Item #1 'Left'
  ; Item #2 'Right'
  : values=1                     # ← currently Left

$ amixer -c1 cget name='tas2783-2 Channel Playback'
  : values=2                     # ← currently Right
```

Also make sure all the amp/speaker switches are **on** (the UCM should do this, but verify):

```bash
amixer -c1 cset name='tas2783-1 Amp Playback Switch' on
amixer -c1 cset name='tas2783-1 Speaker Playback Switch' on
amixer -c1 cset name='tas2783-2 Amp Playback Switch' on
amixer -c1 cset name='tas2783-2 Speaker Playback Switch' on
```

And test:

```bash
speaker-test -D pulse -c 2 -l 1 -t wav
# Listens for "Front Left" and "Front Right" voice prompts
```

---

## Step 9 — **The other gotcha: physical channels are inverted**

After setting `tas2783-1 = Left` and `tas2783-2 = Right`, **the speakers may be physically swapped** — i.e. the voice that says "Front Left" comes out the **right-hand side** of the laptop, and vice-versa. This happens because, on the PX13, the SoundWire link IDs don't follow the physical left-right layout you'd assume:

- `tas2783-1` is wired to the **LEFT** speaker (despite being amp #1)
- `tas2783-2` is wired to the **RIGHT** speaker

So if `speaker-test` plays the channels in the wrong physical positions, **swap the channel assignments**:

```bash
# Wrong (sound is inverted):
# tas2783-1 = Right, tas2783-2 = Left

# Right (correct stereo on the PX13):
amixer -c1 cset name='tas2783-1 Channel Playback' Left
amixer -c1 cset name='tas2783-2 Channel Playback' Right
```

Re-run `speaker-test` until "Front Left" comes out the **left** physical speaker and "Front Right" the **right**.

> **Diagnostic trick:** if a `speaker-test` plays only one side regardless of the channel setting, it doesn't mean the second amp is broken — try inverting the assignments first. The most common cause of "only one speaker works" is that **both amps are set to the same channel** (e.g. both `Right`), so only one of them ends up reproducing audio because the other has no input audio routed to it.

---

## Step 10 — Test the microphones

The PX13 has **three** mic options exposed under the HiFi profile:

| Source | Description | When to use |
|---|---|---|
| `Audio Coprocessor Digital Microphone` | Raw internal DMIC array (built-in mic) | Generic recording |
| `echo-cancel-source` (PipeWire filter) | Same DMIC, processed with WebRTC echo cancellation + high-pass filter | **Calls (Discord, Zoom, Meet)** — this is the recommended one |
| `Audio Coprocessor Headset Microphone` | RT721 headset mic via 3.5mm jack | Only when a wired headset is plugged in |

The `echo-cancel-source` is created automatically by the `99-echo-cancel.conf` you installed; it shows up in apps as **"Noise Suppressed Microphone"**.

### Quick record-and-playback test

```bash
# 1) Raw DMIC — record 5s and play it back
parecord --device=alsa_input.pci-0000_c4_00.5-platform-amd_sdw.HiFi__Mic__source \
         --rate=48000 --channels=2 /tmp/mic-raw.wav &
sleep 5; kill %1 2>/dev/null
paplay --device=alsa_output.pci-0000_c4_00.5-platform-amd_sdw.HiFi__Speaker__sink /tmp/mic-raw.wav

# 2) Echo-cancelled mic — same test
parecord --device=echo-cancel-source --rate=48000 --channels=1 /tmp/mic-ec.wav &
sleep 5; kill %1 2>/dev/null
paplay --device=alsa_output.pci-0000_c4_00.5-platform-amd_sdw.HiFi__Speaker__sink /tmp/mic-ec.wav
```

### Verify the recording isn't silent

If you hear nothing on playback, first check if the recording itself contains audio (vs. the mic being muted):

```bash
ffmpeg -i /tmp/mic-raw.wav -af "volumedetect" -f null /dev/null 2>&1 | grep -E "mean|max"
# Healthy:  mean_volume ~ -25 to -10 dB,  max_volume ~ 0 to -3 dB
# Silent:   mean_volume below -60 dB
```

If the recording has audio but you can't hear it on playback, the speaker volume may just be low — `wpctl set-volume <speaker-id> 0.85` and try again.

### Quick mic permission tip

Some apps (Firefox, Chromium, Flatpak apps) gate mic access through their own permission system on top of PipeWire. Check the app's site/profile permissions if PipeWire shows the source healthy but the app reports "no microphone".

---

## Step 11 — Persist everything across reboots

After confirming stereo works correctly:

```bash
# Save all ALSA controls (channels, switches, volumes)
sudo alsactl store

# Verify the alsa-restore service will run at boot
systemctl is-enabled alsa-restore   # should print "static" (always enabled)
```

PipeWire/WirePlumber automatically remember the default sink and the active card profile, so you don't need to do anything else for those.

The `/var/lib/alsa/asound.state` file now has your channel mappings and switch states; `alsa-restore.service` reapplies them on boot.

---

## Final state — what working audio looks like

```bash
$ uname -r
7.1.0-rc1-2-cachyos-rc

$ pactl list cards | grep -A1 "amd_sdw" | grep "Active Profile"
    Active Profile: HiFi

$ wpctl status | grep -A3 "Sinks:"
 ├─ Sinks:
 │  *   72. Audio Coprocessor Speaker             [vol: 1.00]
 │      90. Audio Coprocessor Headphones          [vol: 1.00]

$ amixer -c1 cget name='tas2783-1 Channel Playback' | tail -1
  : values=1     # Left
$ amixer -c1 cget name='tas2783-2 Channel Playback' | tail -1
  : values=2     # Right

$ speaker-test -D pulse -c 2 -l 1 -t wav
# "Front Left"  → comes from left speaker  ✓
# "Front Right" → comes from right speaker ✓
```

---

## Troubleshooting

### "Invalid argument" on every play attempt

Symptom in `journalctl --user -u pipewire`:

```
pw.node: (...amd_sdw...) suspended -> error (Start error: Argumento inválido)
```

**Cause:** card is in `pro-audio` profile, which doesn't negotiate a compatible PCM format with the TAS2783.

**Fix:** switch profile (Step 7).

### Headphones work but speakers don't

The headphone jack uses the **RT721** codec, completely independent of TAS2783. If headphones work but speakers don't, it confirms the issue is on the TAS2783/SoundWire path, not on the codec sub-system as a whole.

### After suspend/resume, speakers go silent

Patch `0013-reattach-after-resume.patch` should fix this. If you still see it after a clean reboot with all patches, double-check `dmesg | grep tas2783` for re-attach errors.

### `alsaucm` shows "Invalid argument" errors

```
alsaucm: error failed to open sound card sof-soundwire: Invalid argument
```

This is a non-fatal cosmetic issue with the UCM `${CardComponents}` variable when invoked from CLI. PipeWire/WirePlumber don't go through the same code path; if the HiFi profile is active and `pactl list cards` shows it, you're fine.

### Mic doesn't work / picks up speaker noise

The `99-echo-cancel.conf` config creates a separate "Noise Suppressed Microphone" virtual source via PipeWire's WebRTC echo-cancel module. In your communication app (Discord, Zoom, etc.), select that virtual source instead of the raw "Audio Coprocessor Digital Microphone".

### Audio jumps to Bluetooth headphones after switching profile

If you switch the card profile (`pro-audio` → `HiFi`) while a Bluetooth audio device is connected, PipeWire will see the previously-selected sink (`pro-output-2`, which was named under pro-audio) disappear, and **fall back to the next available sink by priority**. With a Bluetooth headset connected, that's usually the headset — and your laptop suddenly stops making sound.

**Symptom:**

```bash
$ wpctl status | grep -A4 "Sinks:"
 ├─ Sinks:
 │      57. Radeon HDMI 3
 │      62. Audio Coprocessor Speaker
 │      84. Audio Coprocessor Headphones
 │  *  108. MOMENTUM 3                  # ← Bluetooth stole the default
```

**Fix:** explicitly set the HiFi speaker sink as default after every profile change:

```bash
SPEAKER_ID=$(wpctl status | awk '/Audio Coprocessor Speaker/ {gsub(/[^0-9]/,"",$1); print $1; exit}')
wpctl set-default "$SPEAKER_ID"
```

WirePlumber persists this — once you set it explicitly, future reboots will boot to the speaker (or wherever you last sent audio), not jump to Bluetooth.

You can confirm the persistence with:

```bash
$ wpctl status | grep -A2 "Default Configured"
 └─ Default Configured Devices:
         0. Audio/Sink    alsa_output.pci-0000_c4_00.5-platform-amd_sdw.HiFi__Speaker__sink
         1. Audio/Source  alsa_input.pci-0000_c4_00.5-platform-amd_sdw.HiFi__Mic__source
```

If the configured default still references `pro-output-N` (the old pro-audio sink), the profile switch didn't update it — re-run `wpctl set-default` once on the HiFi sink.

### Card profile reverts to `pro-audio` after a reboot or PipeWire restart

Some setups have a leftover WirePlumber rule (often added as a workaround before the patches existed) that **forces** the card to `device.profile = "pro-audio"`. This typically lives in `~/.config/wireplumber/wireplumber.conf.d/` with a name like `51-strix-halo-audio.conf`.

If you see the profile flip back to pro-audio every time you restart the audio stack, search for and disable that file:

```bash
grep -rl 'pro-audio' ~/.config/wireplumber/ /etc/wireplumber/
# rename anything that matches:
mv <matched-file> <matched-file>.disabled
systemctl --user restart wireplumber
```

---

## What still needs upstream work

These patches are not yet merged into mainline Linux. The maintainers (`hasunpark` on the issue thread and others) are iterating on them. Until they land:

- You'll have to rebuild the kernel package after every CachyOS/Arch kernel update.
- The UCM configs may eventually be upstreamed to `alsa-ucm-conf`, but for now they're maintained as drive-by attachments on the issue.

Watch [CachyOS issue #737](https://github.com/CachyOS/linux-cachyos/issues/737) for progress.

---

## Credits

- **`hasunpark`** and other contributors on [CachyOS issue #737](https://github.com/CachyOS/linux-cachyos/issues/737) for the patches and configs
- **CachyOS** for the kernel build infrastructure
- **ASUS** for the firmware blobs (extracted from the official Windows driver)

---

## License

This guide is released into the public domain (CC0). The patches and configs themselves are licensed by their respective authors (mostly GPL-2.0 for kernel patches).
