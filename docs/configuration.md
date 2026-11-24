# Configuration

The Settings window covers everyday adjustments; this page is the
reference behind it. Every setting lives in
`~/.config/rawtouch/config.json`. RawTouch reloads the file when it
changes, including saves from an external editor.

## The file

Every key is optional, and a missing file means the defaults. This
example changes the scroll gain and the coasting time:

```json
{
  "scale": 1.2,
  "momentum": { "decayTimeConstant": 0.7 }
}
```

[`resources/config.example.json`](../resources/config.example.json) lists
every global default.

- A malformed edit is reported, and the last valid configuration stays in
  use. If the file is invalid at startup, RawTouch reports the error and
  uses the defaults. Either way the file is never overwritten while it is
  invalid: changes made in the app apply but are not saved, and the menu
  says “config.json couldn’t be read — changes aren’t saved”. Once the
  file reads again, its contents take over, replacing those changes.
- Unknown keys are logged and ignored.
- Numbers are clamped to the ranges below when used.
- Changing a setting in the app rewrites the file with sorted keys.

## Global settings

| Key | In Settings | Default | Meaning / range |
|---|---|---|---|
| `enabled` | **Use RawTouch Scrolling** (menu) | `true` | Master switch. `false` returns keyboards to Standard mode. |
| `scale` | Scrolling › **Scroll gain** | `1.0` | Base scroll gain; 0.1–10. See [Gain](#gain). |
| `reverseScrolling` | Scrolling › **Reverse scrolling** | `false` | Reverse both axes after applying their baseline directions. |
| `acceleration.enabled` | Advanced › **Accelerate with finger speed** | `true` | Apply speed-dependent gain. |
| `acceleration.exponent` | Advanced › **Curve steepness** | `0.9` | Shape of the acceleration curve; 0–2. Zero gives constant gain. |
| `acceleration.referenceFingerSpeed` | Advanced › **Speed for 1× gain (finger)** | `40` | Finger speed at which the acceleration gain is 1×, in mm/s on the pad; 1–500. |
| `acceleration.minGain` | Advanced › **Lowest gain** | `1.0` | Minimum acceleration multiplier; 0.05–1. |
| `acceleration.maxGain` | Advanced › **Highest gain** | `16.0` | Maximum acceleration multiplier; 1–20. |
| `momentum.decayTimeConstant` | Scrolling › **Coasting time** | `0.55` | Coast decay in seconds; 0.05–5. Larger values coast longer. |
| `momentum.minimumFlickSpeed` | Scrolling › **Minimum flick speed (on screen)** | `23` | Lift-off speed needed to start momentum, in mm/s of content on screen; 0–1200. |
| `momentum.maximumCoastSpeed` | Scrolling › **Maximum coast speed (on screen)** | `4600` | Cap on the initial momentum speed, in mm/s of content on screen; 25–12000. |
| `momentum.liftStrengthFloor` | Scrolling › **Flick sensitivity** | `0.6` | 0–0.95, 0 disables. See [Flick sensitivity](#flick-sensitivity). |
| `resampling.enabled` | Advanced › **Sync scrolling to the display** | `true` | Schedule scrolling with display refreshes ([Display sync](how-it-works.md#display-sync)). |
| `updates.checkAutomatically` | Advanced › **Check for updates automatically** | `true` | Ask GitHub once a day for the latest app and firmware releases ([Update check](how-it-works.md#update-check)). **Check for Updates…** in the menu works either way. |

Speeds are measured along the direction the finger or content moves, so
a diagonal flick counts at its full speed rather than just its vertical
part. On a pad set to one scroll axis, only movement along that axis
counts.

### Gain

`scale` is a multiplier relative to physical 1:1 movement. Before
acceleration, RawTouch computes:

```text
points per sensor count = scale × display points per mm ÷ pad counts per mm
```

At `scale: 1.0`, slow finger movement moves content about the same
physical distance on screen. Acceleration adds gain on top, so fast
movement does not stay 1:1. The display is the one under the cursor when
the gesture starts. A display that reports no physical size borrows the
main display's, or 4.3 points/mm if that reports none either; a pad that
reports no resolution is taken as 38 counts/mm. The same figures turn the
millimetre speeds above into screen points.

### Flick sensitivity

As a finger lifts, its contact patch shrinks over the last few frames and
the reported position wanders with it. A frame whose touch strength falls
below `liftStrengthFloor` times the touch's own typical strength marks the
finger leaving. A flick (fast enough to coast, and not braking) keeps
scrolling at its firm-contact speed through those frames and coasts from
it; anything else is followed as reported. The Settings readout says
"carried N frames" when this happened.

## Per-keyboard settings

In **Settings → Keyboards**, the **Keyboard** picker chooses whose settings
are shown; it is hidden when there is only one. A keyboard connected over
both USB and Bluetooth is one keyboard here, with one set of settings.

- The **Status** row shows the keyboard's mode on each connection, and
  the **Firmware** row the module version and protocol it reports.
- **Use RawTouch with this keyboard** off returns that keyboard to
  Standard mode on every connection; other keyboards carry on. **Use
  RawTouch Scrolling** in the menu turns RawTouch off everywhere.
- **Use this pad** off stops RawTouch scrolling from one pad. While the
  keyboard is in RawTouch mode, it also stops taps in scroll context:
  RawTouch ignores that pad's touches, so it cannot confirm those taps.
  Pointer-context taps still work. To restore Standard mode scrolling and
  taps, turn off **Use RawTouch with this keyboard**; modes apply to a
  whole keyboard.
- **Custom gain** overrides **Scroll gain** for one pad.
- **Orientation** holds a pad's axes, sensor mapping and directions (see
  [Axes and direction](#axes-and-direction)).
- Click a keyboard or pad heading to rename it; Return saves, Escape
  cancels. Clearing a keyboard's name restores the product name its
  firmware reports; clearing a pad's name restores RawTouch's own
  numbering, **Pad 0**, **Pad 1** and so on. Names are used everywhere
  RawTouch names the keyboard or pad.

Settings for a keyboard that is not connected stay in the picker, marked
**not connected**; **Remove Settings…** deletes them.

### Per-keyboard overrides

In the file, a keyboard's settings live under `devices.<key>`, and a
pad's under `devices.<key>.pads.<id>`. The easiest way to get the key is
to change any setting in **Keyboards** and look in the `devices` object;
it is also in the tooltip of **Use RawTouch with this keyboard**. This
uses gain 1.2 globally, names pad 0 and gives it gain 0.9 and vertical
scrolling, and makes pad 1 scroll horizontally:

```json
{
  "scale": 1.2,
  "devices": {
    "id:YOUR_HARDWARE_ID": {
      "pads": {
        "0": { "name": "Scroll pad", "scale": 0.9, "axes": "vertical" },
        "1": { "axes": "horizontal" }
      }
    }
  }
}
```

Pad 1 and every pad on other keyboards inherit gain 1.2. A pad scrolls
only when the master, keyboard, and pad switches all allow it.

| Key | Default | Meaning |
|---|---|---|
| `devices.<key>.enabled` | `true` | Use RawTouch with this keyboard. `false` returns it to Standard mode on every connection. |
| `devices.<key>.name` | firmware's product name | Display name for this keyboard; up to 24 characters. |
| `devices.<key>.pads.<id>.name` | `Pad <id>` | Display name for this pad; up to 24 characters. |
| `devices.<key>.pads.<id>.enabled` | `true` | Use RawTouch scrolling for this pad. |
| `devices.<key>.pads.<id>.scale` | global `scale` | This pad's base gain; 0.1–10. |
| `devices.<key>.pads.<id>.axes` | `"both"` | Output directions: `"both"`, `"vertical"`, or `"horizontal"`. |
| `devices.<key>.pads.<id>.axis` | firmware orientation | Raw sensor axis driving vertical scrolling: `"x"` or `"y"`. The other drives horizontal. |
| `devices.<key>.pads.<id>.invert` | firmware orientation | Override the vertical baseline inversion with `true` or `false`. |
| `devices.<key>.pads.<id>.invertHorizontal` | firmware orientation | Override the horizontal baseline inversion with `true` or `false`. |

Turning a pad control back to its default in Settings (**Custom gain**
off, **Automatic**, **Both**, or an empty name) removes its key from the
file.

### Keyboard keys

Keyboards are keyed by the hardware identifier their firmware reads from
the chip, `id:<hex>`, which is the same over USB and Bluetooth. Pad IDs
come from the firmware and do not universally mean left or right; scroll
on a pad and look at the Settings readout to learn its number.

Firmware that reports no identifier is keyed per connection instead:
`usb:<serial>` from the USB serial number, or `bt:<address>` over
Bluetooth, so its USB and Bluetooth settings are separate. A known
placeholder serial, one that many devices share, is not used. With no usable
identifier at all, scrolling still works, but only the global settings
apply. To see what a keyboard reports over USB:

```sh
ioreg -r -c IOHIDDevice -l | grep SerialNumber
```

## Axes and direction

**Scroll axes** (`axes`) selects a pad's output directions: both,
vertical, or horizontal. **Vertical axis** (`axis`) instead selects which
raw coordinate, sensor X or sensor Y, drives vertical scrolling; the other
drives horizontal. Leave it automatic unless movement comes out on the
wrong axis. Changing it also swaps the direction baselines derived from
the firmware's orientation.

**Vertical direction** (`invert`) and **Horizontal direction**
(`invertHorizontal`) override those baselines independently. Omitting an
override uses the firmware orientation; setting it to `false` disables
that baseline inversion. Natural scrolling and **Reverse scrolling** still
apply afterward.

Changing the sensor mapping or the scroll axes ends a gesture in progress
without momentum; direction changes apply immediately. These settings
choose output directions only: your keymap still decides whether a pad
always scrolls or needs a layer.
