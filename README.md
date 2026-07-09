# WattBar

A macOS menu bar app that shows your Mac's live power draw in watts — no sudo required.

Inspired by [mactop](https://github.com/context-labs/mactop) and iStat Menus, but living in the menu bar instead of a terminal.

## Features

- **Live system power** in the menu bar (e.g. `22.5 W`), updating at a configurable interval (0.5s / 1s / 2s / 5s)
- **Component breakdown**: CPU, GPU, Neural Engine, and Memory power, with CPU/GPU die temperatures, plus a "Rest of System" residual (display, SSD, radios, conversion losses)
- **Per-app power estimates**: measured CPU package power distributed across apps by their share of machine-wide CPU time — including short-lived child processes like compilers, which roll up into their parent app
- **Last-hour history**: time-weighted average, peak, and a sparkline chart
- **Thermal pressure** indicator (Nominal / Fair / Serious / Critical)
- **Power source** rows: adapter draw and battery draw
- **Launch at login** (on by default, toggleable)

## Why no sudo?

Tools built on `powermetrics` need root. WattBar reads the same underlying data from sources that don't:

| Data | Source |
|---|---|
| System / adapter / battery power | SMC keys (`PSTR`, `PDTR`, `PPBR`) via IOKit |
| CPU / GPU / ANE / DRAM power | IOReport "Energy Model" energy counters |
| CPU / GPU temperature | SMC `Tp*` / `Te*` / `Tg*` sensor keys |
| Per-app attribution | `proc_pid_rusage` CPU time + child-reap counters, budgeted against measured CPU package power |

## Requirements

- Apple Silicon Mac
- macOS 15+
- Xcode command line tools

## Build and run

```sh
./build.sh
open WattBar.app
```

## Debug CLI

The binary doubles as a command-line probe:

```sh
.build/release/WattBar --probe         # one reading of every power/temp source
.build/release/WattBar --apps          # per-app power estimate over 2 seconds
.build/release/WattBar --dump          # every raw SMC power sensor
.build/release/WattBar --login-status  # login item registration state
```

## Accuracy notes

- Per-app figures budget **CPU package power only**; they intentionally sum to the CPU component, not the system total.
- Time spent in privileged system processes (Spotlight, WindowServer, security daemons) can't be read without root and is reported honestly as "System & Other".
- E-core and P-core seconds are weighted equally, so light background apps are slightly overestimated relative to heavy P-core work.

## License

MIT
