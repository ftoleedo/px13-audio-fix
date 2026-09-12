# Rascunho de comentário para CachyOS/linux-cachyos#737 — status no 7.3
# (postar como resposta ao @weskoop / @simiscoool-afk; revisar antes)

@simiscoool-afk status as of this week, tested on `linux-cachyos-rc 7.3.0-rc2` on a PX13 HN7306EAC:

@weskoop both things you saw on 7.3-rc1 are reproducible, and both have a cause and a fix now. Neither is the amp driver.

**1. "Pro Audio profile only, Hi-Fi not available"** — this is the `rt721-sdca` headphone-jack codec, not the speakers. On 7.3 it runtime-suspends about 7 s after probe and never comes back: `rt721_sdca_dev_resume()` fails in `regcache_sync()` with `-ENODATA` (the peripheral ignores bus writes while sysfs still says `Attached`), and every later `pm_runtime_get()` fails the same way — you'll see `rt721-sdca ... ASoC error (-61)` in dmesg. That alone would only cost the jack, but PipeWire's ACP requires *every* mapping of the UCM `HiFi` verb to probe, so the dead `Headphones` mapping drops the whole profile and takes the internal `Speaker` with it. The card is left with `off` and `pro-audio` only. A reboot does not clear it (the codec dies 7 s after every probe).

The fix is to forbid the codec's runtime PM before that first suspend — one udev rule:

```
# /etc/udev/rules.d/90-px13-rt721-no-autosuspend.rules
ACTION=="add", SUBSYSTEM=="soundwire", KERNEL=="sdw:*:025d:0721:*", ATTR{power/control}="on"
```

then `udevadm control --reload` and either reboot or re-probe. Verified: the codec stays `active` with `runtime_suspended_time = 0`, no `-61`, the `HiFi` profile probes, and the Speaker sink comes back through UCM. Cost is the jack codec staying powered. It should go away once the resume path works upstream again — if anyone knows of a fix in flight for `rt721-sdca` / `soundwire_amd` runtime PM on 7.3, please link it.

**2. "Audio does not survive sleep"** — the TAS2783 amps drop their DSP firmware in s2idle. The bus comes back `Attached` and every mixer level looks fine, but the amp is silent until it is re-probed (which re-downloads the firmware). The repo's systemd-sleep hook does that automatically: release the card, unbind the ACP PCI device, unload the SoundWire/ACP module stack, reload, rebind, restart the session PipeWire. Verified this week on 7.3.0-rc2 with a real lid-close: 18 s from `PM: suspend exit` to stereo back, no intervention.

Two things that bit me on the way and are worth knowing if you script this yourself: PipeWire is socket-activated, so `systemctl --user stop pipewire` alone does not release `/dev/snd` (stop `pipewire.socket` and `pipewire-pulse.socket` first, or the rmmod either aborts or — on 7.2 — hangs the kernel in `snd_card_disconnect_sync`); and the module unload order has to come from `lsmod` at run time, because the platform module was renamed to `snd_sof_amd_acp7x` on 7.3 and any hardcoded list leaves the SoundWire master loaded.

**What 7.2/7.3 did and did not fix.** Upstream absorbed the firmware-name and stub fixes, so the DKMS module in the repo is now the stock driver plus a single control (`tas2783-N Channel Playback`) — still needed, because the ASUS ACPI has no SDCA function data and the driver's fallback writes cluster index `0x01` to both amps → mono from one speaker. Also still needed: the UCM override, because `alsa-ucm-conf` ships no tas2783 config and 7.2 started tagging the card `spk:tas2783`, so without it UCM cannot open the card at all (worse than 7.1). The module now builds from one source on 7.1, 7.2 and 7.3 (thanks @j842 for the 7.1 compat PR).

Everything, with the write-up of each failure mode and a `check-audio.sh` that names which one you are in:
**→ https://github.com/ftoleedo/px13-audio-fix**

```
bash install-durable.sh            # module + UCM + the udev rule above
bash install-resume-recovery.sh    # the sleep hook
bash check-audio.sh                # after every kernel update
```

@weskoop if you get to it this weekend, `bash check-audio.sh` on rc1/rc2 should tell you in one line whether you are hitting the rt721 case — I'd be glad to know it reproduces on a second machine.
