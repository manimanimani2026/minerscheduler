# ⛏️ Miner Scheduler

A macOS SwiftUI app for managing and scheduling Bitcoin mining hardware.

## Supported Miners
- **Proto** (HTTP API) — status, on/off, reboot, power target
- **Avalon Q** (CGMiner API on port 4028) — status, on/off, mode change (Eco/Standard/Super)

## Features
- Real-time dashboard with hashrate, power, J/TH, temperature, fan speed
- Scheduled on/off times for both miners
- Proto watchdog: auto-reboots if degraded for 2+ minutes
- Configurable IP addresses and ports

## Build
```bash
swift build -c release
```

## Install
```bash
mkdir -p /Applications/MinerScheduler.app/Contents/MacOS
cp .build/release/MinerScheduler /Applications/MinerScheduler.app/Contents/MacOS/
cp Info.plist /Applications/MinerScheduler.app/Contents/
open /Applications/MinerScheduler.app
```

## Requirements
- macOS 13.0+
- Swift 5.9+
