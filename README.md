# RDP Launcher

A bar widget for [Omarchy](https://omarchy.org): saved RDP connections to Windows,
launched with FreeRDP 3. An independent community plugin, not affiliated with
the Omarchy project.

## Install

```bash
omarchy pkg add freerdp libsecret gnome-keyring gcc libxcursor
omarchy plugin add https://github.com/lipchanskiy/rdp-launcher.git --enable
```

Update later with `omarchy plugin update rdp-launcher`, remove with
`omarchy plugin remove rdp-launcher`. `gcc` and `libxcursor` are only needed
for the pointer fix on scaled monitors (see below).

## How it works

- Profiles: `~/.config/rdp-launcher/connections.json` (no secrets).
- Passwords: system keyring (gnome-keyring), `service=rdp-launcher id=<id>`.
  Passed to FreeRDP over stdin (`/args-from:stdin`), never on a command line.
- Window: `xfreerdp3` via XWayland (zero scaling = real pixels; sdl-freerdp3
  breaks on HiDPI). `+dynamic-resolution`: the remote desktop resizes with the
  window. Opens maximized over the work area (bar stays visible): the helper
  finds the session's window by pid and maximizes it, no Hyprland rule needed.
  Scale "auto" follows the monitor's scale.
- `-grab-keyboard`: Hyprland shortcuts keep working inside the session.
  Fullscreen: Super+F, or Ctrl+Alt+Enter (FreeRDP); a hidden bar at the top
  edge in fullscreen has minimize / window / close.
- Logs: `~/.local/state/rdp-launcher/<id>.log`. Failures raise a notification.
- Other client: set `RDP_LAUNCHER_CLIENT=xfreerdp3`.

Keys in the panel: Enter connect · N new · E edit · X delete (twice) · Esc close.
Helper: `bin/rdp-launcher connect|store|forget|has|saved`.

## Mouse pointer on a scaled monitor

Under XWayland with `force_zero_scaling`, Hyprland scales X cursors by the
monitor scale, on top of Windows' own DPI scaling, so the remote pointer came
out ~2.5× too big. `src/cursor-shim.c` (built to `bin/cursor-shim.so` on first
use) is LD_PRELOADed into xfreerdp only and shrinks each remote pointer image
by the monitor scale. Disable with `RDP_LAUNCHER_CURSOR_FIX=0`.

## Keyboard layout

FreeRDP normally sends physical keys (scancodes), which Windows turns into
letters with *its own* layout, so switching the layout in Linux did nothing
there (Russian typed as "ghbdtn"). "Linux layout" (on by default, per
connection) adds `/kbd:unicode:on`: letters go as the characters the current
Linux layout produces; Ctrl/Alt/Win shortcuts and special keys stay physical
keys. XIM goes through X's built-in method (`XMODIFIERS=@im=none`), not fcitx5.
Turn it off for apps that ignore Unicode input (some games, remote consoles).
