# Uptime & Activity

A bar uptime label and an activity panel for the Omarchy shell.

The bar shows how long the machine has been up, in a format you choose.
Clicking opens a panel with three line graphs — uptime, keyboard time and
screen time — over the last 24 hours, 7 days and 30 days, drawn on shared
axes so you can see at a glance when you were actually at the machine.

## What gets recorded, and what does not

This is the part worth reading before installing.

**Only timestamps are ever stored.** Not keystrokes, not screen contents, not
images.

- **Keyboard time** is the sum of typing *bursts*. A burst starts at the first
  key press after 60 seconds of silence and spans first press to last press.
  Presses within 60 seconds of each other stay in the same burst, so thinking
  pauses do not break a burst apart. Presses are read straight off the evdev
  nodes in `/dev/input`, and only keys classified as typing count — modifiers,
  lock keys, function keys, media/system keys and all `BTN_` codes (mouse,
  trackpad, pads) are excluded, so nothing the pointer does registers.
- **Screen time** is a presence estimate. The daemon grabs one small grayscale
  frame from the webcam every 10 seconds and compares it to the previous one; a
  mean-absolute-difference above a small threshold counts as motion. A session
  closes after a short grace period of calm so brief walk-aways do not split
  it. Frames are compared in memory and **never written to disk**.
- **Uptime** is one entry per boot, from `/proc/uptime`.

The log is encrypted at rest with AES-256. The key is a random 256-bit value in
`~/.config/omarchy/bar/data/activity.key` (mode 0600), separate from the log,
so a copied log file is useless on its own.

Nothing is collected unless you ask for it: turning **Keytime** or
**Screentime** off in the panel's SHOW options stops that series being
collected at all. The daemon re-reads its settings every few seconds and stops
opening input devices or grabbing camera frames for a disabled series, so the
data is never gathered in the first place rather than gathered-and-discarded.

The panel's **CLEAR** button wipes every saved series except the boot you are
currently running.

## Requirements

- Omarchy shell
- `python3`
- Membership of the `input` group, for reading `/dev/input` (keyboard time)
- A working webcam, if you want screen time

## Install

```sh
omarchy plugin add https://github.com/RobbieUK1/omarchy-uptime.git --enable
omarchy restart shell
```

The panel and the daemon shell out to helper scripts that ship in `bin/` but
have to live outside the plugin directory:

```sh
mkdir -p ~/.config/omarchy/bar/scripts
install -m 755 bin/activity-daemon  ~/.config/omarchy/bar/scripts/activity-daemon
install -m 755 bin/activity-graphs  ~/.config/omarchy/bar/scripts/activity-graphs
install -m 755 bin/activity_crypto.py ~/.config/omarchy/bar/scripts/activity_crypto.py
```

The daemon needs to run as a long-lived user service:

`~/.config/systemd/user/robbie-activity.service`

```ini
[Unit]
Description=Uptime + keyboard activity recorder
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=%h/.config/omarchy/bar/scripts/activity-daemon
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now robbie-activity.service
```

Then right-click your bar -> **Configure bar** (or edit
`~/.config/omarchy/shell.json`) and add the widget:

```json
"left": [
  { "id": "robbie.uptime" }
]
```

## Bar formats

| # | Format                   | Example            |
|---|--------------------------|--------------------|
| 0 | days / hours / minutes   | `12d 3h 45m UT`    |
| 1 | total minutes            | `17,827m UT`       |
| 2 | total seconds            | `1,069,663s UT`    |
| 3 | total milliseconds       | `1,069,663,000ms`  |

Format and display suffix are chosen in the panel's settings, and persist to
`~/.config/omarchy/bar/uptime-settings.json`. Uptime is rebased from
`/proc/uptime` every 60 seconds to avoid accumulating drift, and the
sub-second modes tick at 20Hz.

## How it works

`activity-daemon` is the only thing that touches hardware. It writes three
session series to `~/.config/omarchy/bar/data/activity-sessions.json` and keeps
an `alive` heartbeat, so after a reboot the previous session closes at its last
heartbeat — the gap between that and the next boot is the powered-off period,
which is correctly not counted as uptime.

The daemon watches `/dev/input/event*` for typing bursts. It picks up devices
that appear while it is running, and it closes a device as soon as it is
removed. That matters more than it sounds: a descriptor left open after its
device is unplugged stays readable-forever in the daemon's `select()` set, so
the main loop never blocks again and pins a whole CPU core until the service is
restarted. If uptime ever looks like it is costing far more CPU than it should,
`systemctl --user status robbie-activity.service` will show it.

`activity-graphs` reads and decrypts that log and prints the per-window
aggregates the panel draws. It is called with `--metric uptime|keyboard|presence`
and the panel polls it every 3 seconds while open.

The panel itself is a `PopupCard` rather than a `KeyboardPanel`, on purpose:
it has no text input, and it must not take keyboard focus away from whatever
you were typing in when you clicked the bar.

## What is not in this repo

Your activity data, your encryption key and your personal settings are **not**
committed and are excluded by `.gitignore`:

- `bar/data/activity-sessions.json` — your real session history
- `bar/data/activity.key` — the key that decrypts it
- `bar/uptime-settings.json` — your format and colour choices

They are created at runtime on your machine.

## License

MIT
