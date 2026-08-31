# Implementation notes

Things about this that are not obvious, kept because each one cost real time to
find. Not needed to use the plugin — see [README.md](README.md) for that.

## Cover art comes over Bluetooth, and needs two things nobody has by default

AVRCP 1.6 sends an image *handle* with the track metadata; the image itself is
pulled over an OBEX Basic Imaging session on a PSM the phone advertises. bluez
5.87 implements both halves, but:

- The BIP client lives in **obexd**, shipped separately as `bluez-obex`. Without
  that package BlueZ never advertises cover-art support, so the phone never
  sends a handle.
- **`Experimental = true`** in `/etc/bluetooth/main.conf` is what makes BlueZ
  publish `ImgHandle` on D-Bus. Without it the attribute is parsed and dropped.

With both, `org.bluez.MediaPlayer1.Track` gains a seventh field and
`MediaPlayer1.ObexPort` carries the PSM to fetch from.

A connect to that PSM refused right after linking is **normal** — the phone
opens its imaging responder lazily. Retry rather than concluding it is
unsupported.

`Image1.Properties` reports what a source actually holds. Do not assume
`native` is the largest: an iPhone reports native 200×200 alongside a 280×280
variant, and the variant carries real detail rather than being an upscale.
Request the largest advertised descriptor. Unadvertised sizes are silently
answered with native, so there is no point guessing at larger ones.

## Two traps reading BlueZ over D-Bus

`busctl get-property` escapes every non-ASCII byte as octal in text output. An
artist of `Green Day • Video Available` arrives as the literal characters
`\342\200\242`, so any pattern expecting a bullet silently never matches. Read
properties with `busctl --json=short` and jq instead.

`org.bluez.obex.Image1.Get` takes `(s, s, a{sv})`. Calling it `sssa{sv}` fails,
and with a fallback in place the symptom is not an error but a "full size" image
that is quietly identical to the thumbnail.

## `ServicesResolved` cannot be trusted

It has been observed `true` while every GATT read failed with "Not connected",
and `false` while the link was fine. The only honest test of the LE link is a
real round trip — the battery characteristic read is used for this.

## Battery

Read the standard GATT Battery Service (`0x180F` / `0x2A19`), not
`org.bluez.Battery1`. The latter is pinned at 100 for a phone on A2DP alone,
because iOS reports battery over HFP and no HFP link is held. Measured side by
side: GATT 82%, `Battery1` 100%. `Battery1.Source` is empty exactly when the
value is a phantom, so it is used only as a fallback and only when that field
is set.

## App notifications are not possible over Bluetooth

MAP carries the phone's message store, which means SMS. ANCS — Apple's service
— carries everything, and it was implemented here and verified working before
being removed.

It rides the LE link, and that link cannot be held up from this side.
`Device1.Connect` has no transport selector: with the audio link established
BlueZ reads the device as already connected and retries BR/EDR, failing with
`br-connection-create-socket` without ever attempting LE. Upstream
[bluez#511](https://github.com/bluez/bluez/issues/511) asks for per-device
transport selection and is closed as not planned.

[ancs4linux](https://github.com/pzmarzly/ancs4linux), the one working Linux
ANCS project, gets its link the other way round — Linux advertises, the phone
connects — and deliberately hijacks pairing so the phone cannot redirect audio
to the PC. The established solution excludes A2DP, which is this plugin's whole
purpose.

Symptom worth recognising if anyone tries again: **SMS keeps working, app
notifications do not.**

## `off` has to be held, not applied once

Setting the phone's card profile to `off` releases the local audio node but
leaves the AVDTP link standing, so the phone goes on believing it is playing to
a speaker. `org.bluez.Device1.DisconnectProfile` with the phone's **Audio
Source** UUID (`0000110a`) is what actually ends it: the `bluez_card`
disappears while `bluetoothctl info` still reports `Connected: yes` — which is
exactly the plain Bluetooth device the plugin promises to hand back.

Doing it once is not enough. The phone can re-establish A2DP whenever it likes
and BlueZ will accept it, and a `bluez5.auto-connect = [a2dp_sink a2dp_source]`
rule in a WirePlumber drop-in makes that automatic. So `sync` calls
`enforce_off` while the switch is off, and `Model.needsSync` reports drift for a
card that has reappeared with a profile other than `off`.

What none of this can do is hide the machine from the phone's speaker list. The
adapter advertises **Audio Sink** (`0000110b`) permanently — WirePlumber
registers the role when its bluez monitor loads, per adapter, not per device —
so a paired phone will always offer this machine as an output. Removing it
means dropping `a2dp_sink` from `bluez5.roles` and restarting WirePlumber: a
config rewrite and a daemon restart, and this plugin does neither.

## Which phone to reconnect to

BlueZ publishes no last-connected time on D-Bus. `/var/lib/bluetooth` holds one
but is root-only, so the plugin remembers the MAC itself, written on every sync
that sees a phone connected.

`devices Paired` lists everything ever bonded — headphones, mice, speakers — so
it needs a filter. The **Audio Source** UUID is the right one: it marks a device
that can play *to* this machine, as opposed to one that consumes audio from it.

The reconnect is one detached attempt from `on`, never from `sync`. A
`bluetoothctl connect` to an absent device blocks for the length of a page scan,
which is far longer than the shell will wait for the switch to throw, and
retrying every poll would page a phone that is simply elsewhere.

## Volume mirroring

AVRCP Absolute Volume is already implemented on both sides — BlueZ exposes it
as a writable `Volume` on `org.bluez.MediaTransport1`, 0–127, emitting a change
whenever the phone's slider moves. Only the link to PipeWire was missing.

Two measures keep it from fighting itself, and both are needed:

- **Echo suppression.** Our own write returns as a change notification;
  anything within 600ms of a write is treated as that echo.
- **A deadband.** Rounding between 0–127 and a percentage never round-trips, so
  a change must move more than 2% to count.

When reading the log, a burst of `phone -> N%` lines is the user pressing volume
buttons, not oscillation. Check the direction prefix before diagnosing a loop.

## Why some parts are daemons

obexd destroys a session the moment the D-Bus client that created it
disconnects, so MAP cannot be a shell-out the way the artwork fetch is.
Volume mirroring needs to watch D-Bus and `pactl subscribe` at once. Both run as
transient user units.

Both are pinned to `/usr/bin/python3`: PyGObject lives in the system
interpreter, and `/usr/bin/env python3` picks up a mise shim that does not have
it.

## QML

Never insert a block into `Panel.qml` by line number and assume the nesting is
right. It went wrong twice — once landing a section inside a `PanelSeparator`,
once landing the cover pane inside the media row, whose height is derived from
its content so the expanded cover overflowed and painted over everything below.
QML accepts both as legal child nesting: no error, no log line, and
`omarchy plugin validate` passes because it only checks the manifest.

Verify placement with a brace-depth pass before restarting the shell. Siblings
must report the same depth:

```bash
awk '{ n=gsub(/\{/,"{"); m=gsub(/\}/,"}")
       if ($0 ~ /id: (thing|sibling)/) printf "depth=%d %s\n", d, $0
       d += n - m }' Panel.qml
```

Do not pass a height cap to `fittedContentHeight`. It already clamps to
available screen height; a second cap becomes a ceiling the panel cannot grow
past, which silently clips content.

Use `Color.accent` for an active state, not `bar.urgent`. The token behind
`bar.urgent` is `Color.bar.active`, which makes it look correct — but every
first-party use is error-flavoured, so it reads as a warning.

## pactl

`pactl -f json` prints `Invalid ASCII character: 0xffffffc3` to stderr for
non-ASCII device names and still emits valid JSON. Redirect stderr; it is not a
failure.

## Removal

`omarchy plugin remove` deletes the directory and runs nothing — there is no
uninstall hook, and no first-party plugin ships background services, so there
was no pattern to copy. Three things cover it:

- `omarchy-speaker-mode uninstall` reverts Bluetooth and deletes state and
  cache. The README tells people to run it first.
- `Component.onDestruction` in Panel.qml stops the daemons when the plugin is
  unloaded — the same hook `omarchy.bluetooth` uses to stop its discovery scan.
  It stops daemons only, never speaker mode's own state, so a shell restart
  brings them straight back on the next sync.
- Each daemon checks every 30s that its own file still exists and exits if not,
  as a backstop for a directory deleted without the uninstall step.

## Do not use `pgrep -f` / `pkill -f` on these daemon names

The pattern matches the shell command line running the check, so it finds — and
kills, or reports on — the wrong process. The `[o]marchy` bracket trick does not
help when the command line also contains the plain string. Get the pid from the
process itself:

```bash
setsid sh -c 'echo $$ > /tmp/x.pid; exec /path/to/daemon args' &
```
