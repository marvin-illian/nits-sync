# Nits Sync

# Nits Sync is a small, menu-bar-only macOS app that follows the built-in
MacBook display's physical luminance and maps it to external monitors through
DDC/CI hardware brightness.

It is intentionally hardware-only: it does not add a dimming overlay or alter
display gamma, contrast, HDR, picture mode, or color profiles.

## Build the app yourself

Requirements: Apple silicon, macOS 13 or later for the finished app, and Xcode
16 or newer (including its command-line tools) to build it.

For a local build with an ad-hoc signature:

```sh
make app
```

The resulting bundle is:

```text
dist/Nits Sync.app
```

To build it and then sign it with the first valid code-signing identity found
in your keychain:

```sh
make signed-app
```

That command uses the first identity reported by:

```sh
security find-identity -v -p codesigning
```

It exits with a clear message when no valid identity is available. Both build
commands leave the finished app in `dist/Nits Sync.app`; neither installs nor
launches it. Move the bundle to `/Applications` before enabling **Start at
Login**. The build also creates the app's sun icon at every macOS icon size.
The optional identity-signing command is intended for local use; it does not
notarize the app for public distribution.

## First test

Open `Nits Sync.app`, then lower the MacBook brightness by several steps. If
the MacBook is already brighter than an external monitor's detected ceiling,
that monitor correctly remains at its maximum until the MacBook drops back
into the monitor's range.

### Low-latency mode

In the menu, enable **Low-Latency Sync** to reduce reaction time for external
brightness updates. This is done by:

- faster built-in nits sampling,
- a smaller deadband, and
- shorter DDC write/read verification delay.

Tradeoff: it can produce more jitter on noisy monitors or occasionally show
temporary mismatches after transient DDC errors.

Nits Sync retries a monitor automatically when its first DDC read is busy or
times out. You can also choose **Refresh Displays** in the menu at any time.

The preference is persisted as `lowLatencySync` and kept across app launches.

## Accuracy

The built-in panel reports live physical luminance. Standard DDC/CI external
monitors report a relative brightness control value, not live nits. Nits Sync
therefore stores a response curve for each physical monitor. The detected EDID
maximum is used as a starting estimate. If a monitor publishes no luminance
metadata, the app starts at 350 nits; replace that under **Set Maximum Nits…**.
Use **Calibrate This Display** for the closest visual match, or use a
colorimeter for measurement-grade calibration.

During calibration, Nits Sync shows matching white reference patches and an
**External Brightness** slider in its menu. Set the Mac to a low, middle, and
high brightness in turn, use the slider until the patches look equally bright,
and record each match. You do not need to use the monitor's on-screen controls.

Calibration is tied to a monitor's current picture/HDR/energy-saving mode.
Changing those settings can invalidate it.

## Restoration guarantee

Before its first brightness write, Nits Sync reads and durably records the
monitor's original raw DDC brightness. Turning synchronization off and a normal
Quit both restore that value and verify it before completing.

Force Quit, sudden power loss, or disconnecting a monitor can prevent immediate
restoration. The durable journal is retained so the app can recover safely on
the next launch when the exact monitor is available.

## Reset generated data

Choose **Reset Nits Sync…** in the menu to restore controlled monitors, turn
off **Start at Login**, remove all saved per-monitor calibration, preferences,
and recovery files, then quit. This leaves `Nits Sync.app` itself installed so
you can delete or keep the application separately.

Per-monitor profiles and the crash-recovery journal are stored under
`~/Library/Application Support/Nits Sync/` (or legacy `~/Library/Application Support/nits-ctrl/` from older builds). The Reset command removes those
folder and the app's small macOS preferences domain.

## Distribution note

The app uses unheadered macOS display services required for DDC on Apple
silicon. It is designed for local/Developer ID distribution outside the Mac
App Store and runs without App Sandbox.
