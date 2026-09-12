# Rascunho de comentário para CachyOS/linux-cachyos#737 — status no 7.3
# (postar como resposta ao @weskoop / @simiscoool-afk; revisar antes)
# v2 2026-09-12: resume sem interrupção (driver 7.3 + restore do canal)

@simiscoool-afk status as of this week, tested on `linux-cachyos-rc 7.3.0-rc2` on a PX13 HN7306EAC:

@weskoop both things you saw on 7.3-rc1 are reproducible, and both have a cause and a fix now. Neither is the amp driver.

**1. "Pro Audio profile only, Hi-Fi not available"** — this is the `rt721-sdca` headphone-jack codec, not the speakers. On 7.3 it runtime-suspends about 7 s after probe and never comes back: `rt721_sdca_dev_resume()` fails in `regcache_sync()` with `-ENODATA` (the peripheral ignores bus writes while sysfs still says `Attached`), and every later `pm_runtime_get()` fails the same way — you'll see `rt721-sdca ... ASoC error (-61)` in dmesg. That alone would only cost the jack, but PipeWire's ACP requires *every* mapping of the UCM `HiFi` verb to probe, so the dead `Headphones` mapping drops the whole profile and takes the internal `Speaker` with it. The card is left with `off` and `pro-audio` only. A reboot does not clear it (the codec dies 7 s after every probe).

The fix is to forbid the codec's runtime PM before that first suspend — one udev rule:

```
# /etc/udev/rules.d/90-px13-rt721-no-autosuspend.rules
ACTION=="add", SUBSYSTEM=="soundwire", KERNEL=="sdw:*:025d:0721:*", ATTR{power/control}="on"
```

then `udevadm control --reload` and either reboot or re-probe. Verified: the codec stays `active` with `runtime_suspended_time = 0`, no `-61`, the `HiFi` profile probes, and the Speaker sink comes back through UCM. Cost is the jack codec staying powered. It should go away once the resume path works upstream again — if anyone knows of a fix in flight for `rt721-sdca` / `soundwire_amd` runtime PM on 7.3, please link it.

**2. "Audio does not survive sleep"** — on 7.3 this one is mostly solved *by 7.3 itself*, with one catch. Andrey Golovko's three tas2783 resume fixes in 7.3 (drop the stale regcache on re-attach, power the Function up before preparing the port, `writeable_reg`) make the amps re-initialise on their own after s2idle. I measured it with the recovery hook deliberately disabled: bus `Attached`, no errors, PipeWire's sink still there, sound back within seconds — no reload, no PipeWire restart, browser audio untouched.

The catch: that re-initialisation replays the driver's init sequence, which puts cluster index `0x01` on **both** amps — so you come back in mono (both speakers Left) with every mixer value looking right. Nothing re-applies the channel assignment, because UCM only runs it on profile activation and nothing restarted PipeWire. The repo's module now remembers the last `Channel Playback` value userspace wrote and writes it back after every init; with that, a lid-close on 7.3.0-rc2 costs nothing: `PM: suspend exit` → 10 s later the hook looks at the bus, sees every codec `Attached`, and logs "nothing to do". Stereo confirmed by ear.

One warning that applies to *your* DKMS module if you carry one: a DKMS copy outranks the in-tree driver, so a module based on the 7.2 source **removes** those 7.3 resume fixes from a 7.3 kernel. That is exactly what the repo's module was doing until yesterday — the unconditional reload on resume was hiding it. It is now based on the 7.3 driver on every kernel, with the two calls that differ on 7.1/7.2 probed from the target kernel's headers at build time (a version-code check is not enough: @leepaulmann found Arch 7.1.9 with a different `sdca_parse_function()` than CachyOS 7.1.x under the same `LINUX_VERSION_CODE`).

Below 7.3 the hook still does the full reload, on purpose: a PCM left open across s2idle comes back running but silent there, because the SoundWire ports are never re-prepared — fixed in 7.3's `snd_soc_sdw_utils` ("prepare the stream again when resuming"), which a codec module cannot carry — and the PipeWire restart is what hides it. If you script that yourself, two things bit me: PipeWire is socket-activated, so `systemctl --user stop pipewire` alone does not release `/dev/snd` (stop `pipewire.socket` and `pipewire-pulse.socket` first, or the rmmod either aborts or — on 7.2 — hangs the kernel in `snd_card_disconnect_sync`); and don't start tearing the ACP down 2 s after resume — @leepaulmann hit a NULL deref in `release_resource()` 1 resume in 10 that way, wait ~10 s.

**What 7.2/7.3 did and did not fix.** Upstream absorbed the firmware-name and stub fixes and, in 7.3, the resume. What is still needed on top of stock: the single `tas2783-N Channel Playback` control (the ASUS ACPI has no SDCA function data, so the driver's fallback writes cluster index `0x01` to both amps → mono from one speaker, and now also → mono after every resume), and the UCM override, because `alsa-ucm-conf` ships no tas2783 config and 7.2 started tagging the card `spk:tas2783`, so without it UCM cannot open the card at all (worse than 7.1). The module builds from one source on 7.1, 7.2 and 7.3 (thanks @j842 for the 7.1 compat PR, and @leepaulmann and @s-bernard for the fork work that went in this week).

Everything, with the write-up of each failure mode and a `check-audio.sh` that names which one you are in:
**→ https://github.com/ftoleedo/px13-audio-fix**

```
bash install-durable.sh            # module + UCM + the udev rule above
bash install-resume-recovery.sh    # the sleep hook
bash check-audio.sh                # after every kernel update
```

@weskoop if you get to it this weekend, `bash check-audio.sh` on rc1/rc2 should tell you in one line whether you are hitting the rt721 case — I'd be glad to know it reproduces on a second machine.
