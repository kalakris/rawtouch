# How RawTouch works

For the curious and for contributors. None of this is needed to use the
app. The HID reports themselves are specified in the firmware module's
[wire format](https://github.com/kalakris/zmk-raw-touch/blob/main/docs/protocol.md).

## From finger to scroll event

The keyboard sends each pad's finger position, contact state and a device
timestamp at about 100 Hz. Contact state distinguishes a finger held still
from one that has lifted, which is what lets RawTouch coast on lift-off
and stop on touch-down.

Drag and momentum use both coordinates. Acceleration uses their combined
speed and applies the same gain to both, so a diagonal stays diagonal.
RawTouch does not lock gestures to one axis, though applications may.
Selecting a single scroll axis leaves the other out of both the output
and the speed calculations.

Scroll events are posted at the session event tap, never the HID tap, so
RawTouch composes with other mouse tools. Utilities that modify those
synthetic events can still change the result.

## Modes and the host lease

The keyboard scrolls on its own (Standard mode) unless a host holds a
**lease** on its touch stream. RawTouch acquires one per USB connection
or Bluetooth profile, asking for 30 seconds and renewing every 10. While
the lease is held, the firmware streams touch samples and suppresses its
own wheel events (RawTouch mode). RawTouch releases the lease when
disabled, on a normal quit, or when Accessibility permission is lost; it
checks the permission about once a second while ungranted and every five
seconds while granted. If RawTouch dies without releasing, the lease
expires within 30 seconds and the keyboard scrolls on its own again.

With a keyboard connected over both USB and Bluetooth, a switch of
connection mid-scroll hands the gesture over. The keyboard's frames for
the same pad arriving over the other connection take the gesture over at
once, recognized by the hardware identifier every connection of a
keyboard reports, and scrolling continues from where the finger is: no
new gesture, no jump, no momentum. The gesture adopts the new
connection's measured latency (see [Display sync](#display-sync)). Frames still in flight on the old
connection are ignored. If the new connection's frames come more than
150 ms after the old one's last, or macOS reports the old connection gone
before they arrive, as can happen when USB is unplugged, the gesture
ends without momentum and a new one starts on the other connection.
Disconnecting an unrelated keyboard does not end the active gesture.

## Recognizing a keyboard

Discovery looks for the vendor HID collection, then reads the feature
report and checks its `RAWT` magic, protocol version and length before a
device is treated as a keyboard or written to. That is identification,
not authentication.

The same report carries the keyboard's hardware identifier, read from its
chip and identical over USB and Bluetooth. That is how RawTouch shows one
keyboard rather than one entry per connection, and what per-keyboard
settings are keyed by. It also carries the module version of each half;
a split keyboard's other half announces its version with its first
touch, and RawTouch then re-reads the report.

## Display sync

A Pinnacle pad reports at most 100 samples per second, so on a 120 Hz
display every sixth frame would have no new sample: a visible stutter.

With **Sync scrolling to the display** on (the default), RawTouch posts
scroll updates on the refresh cycle of the display under the cursor. Each
update comes from the finger position a short latency before that
refresh: interpolated between the two samples that bracket that instant,
or extrapolated from the newest sample, never more than one sample period
past it. Momentum rides the same clock. If extrapolation overshoots a
sudden stop, RawTouch keeps the small offset rather than visibly
scrolling backward to correct it.

The latency a pad needs depends on the whole path its frames take. On the
tested keyboard, the central half's own pad over USB needs about 1 ms, the
pad relayed from the other half over a wired split link about 5 ms, the
same pad about 10 ms over a wireless split, and either pad 14–16 ms when
the Mac connection is Bluetooth. Whether the halves are wired can change
mid-session, so the latency is measured, not set. For each pad on each
connection, RawTouch keeps the last 200 frames' arrival lateness against
their device timestamps and, at every touch-down, adopts the 90th
percentile plus half a millisecond, clamped to 0–25 ms, for the whole
gesture. It never changes mid-gesture, which would move content under a
moving finger; a handover to the keyboard's other connection is the one
exception, and adopts that connection's value.

The percentile comes from replaying recorded deliveries through the
offline benchmark: on every path, the point where more latency stops
buying smoothness sits near p90 (see
[`bench/captures/`](../bench/captures/README.md)). A pad's first gesture
on a new connection runs at a 15 ms starting value, slightly laggy rather
than stuttery. Once 20 frames from touches longer than a tap have been
measured, the measurement takes over at the next touch-down.

The Advanced tab's **Latency** row shows what each pad has measured on
each connection. The last-gesture readout shows the latency the gesture
ran at, its connection, and how many display frames had to wait for a
late sample.

## Update check

RawTouch says when a newer app or firmware release is out; it never
downloads or installs anything. About ten seconds after launch and then
once a day while **Check for updates automatically**
(`updates.checkAutomatically`) is on, and whenever you choose **Check for
Updates…** in the menu, it asks GitHub's API for the latest release of
RawTouch and of `zmk-raw-touch`: one anonymous HTTPS request to
`api.github.com` each, with no cookies, cache or credentials, naming only
the app version in its User-Agent. Of the answer it reads the release's
tag and page.

The menu then lists a release newer than the running app, and a module
release newer than a connected keyboard's firmware; choosing one opens
the release page. While it lists one, the menu bar icon carries a small
up-arrow mark, left off only while the icon shows the attention triangle.
A development build (`0.0.0-dev`) is never offered the
app. A keyboard reports its module version as major.minor only, so a
patch release (0.2.1 for a keyboard on 0.2) is not offered. A half that
has not reported its version yet, such as a split's other half before
its first touch, is left out; a keyboard is out of date when any half it
has heard from is older. An automatic check only updates the menu, and
one that fails is only logged. A check from the menu is answered with an
alert, since choosing the item closes the menu: the updates found, with a
button to their release pages, or that there are none, or that GitHub
could not be reached.

## Benchmarks and validation

`swift run scroll-bench --offline` is the deterministic cadence check:
scripted finger motion at a 120 Hz display rate, no hardware, no posted
events. For live browser experiments, see
[`bench/safari-bounce/`](../bench/safari-bounce/README.md). A browser's
page-side animation log may run at a different rate from the display, so
it cannot by itself verify display-rate delivery.
