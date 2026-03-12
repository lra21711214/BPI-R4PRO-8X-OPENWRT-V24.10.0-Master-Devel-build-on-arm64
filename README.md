# BPI-R4PRO-8X-OPENWRT-V24.10.0-Master-Devel-build-on-arm64

A Dockerized OpenWrt build environment specifically optimized for compiling the Banana Pi BPI-R4 Pro (MediaTek MT7988 / Filogic 880) firmware natively on **Apple Silicon (M1/M2/M3/M4) arm64 hosts**.

Building OpenWrt on arm64 macOS typically fails due to x86-based Go bootstrap dependencies and cross-compilation toolchain mismatches. This repository solves these issues by providing a pre-configured Docker environment with native arm64 toolchains and a patched Golang Makefile.

## ✨Features

- **Native arm64 build:** No x86 emulation (Rosetta/QEMU) required. Full speed on Apple Silicon.
- **Go bootstrap fix:** Automatically patches the Golang Makefile to use a pre-installed host Go `1.24.6` environment.
- **Custom feeds support:** Easily add third-party feeds (like `kenzo` and `small`) via the `configs/` directory.
- **Persistent caching:** Downloaded sources (`dl/`) and build outputs (`bin/`) are synced to the host to speed up subsequent builds.

## 🛠Prerequisites

- Apple Silicon Mac (M1/M2/M3/M4)
- Docker Desktop or OrbStack installed and running

## 📂Repository Structure

```text
.
├── Dockerfile
├── docker-compose.yml
├── configs/
│   ├── feeds.conf.default    # Custom feeds configuration
│   └── golang-Makefile       # Patched Makefile for Go bootstrap
├── scripts/
│   └── build.sh              # Unified build script (auto / prepare mode)
├── logs/                     # Build logs written by build.sh
├── .config                   # Optional persistent OpenWrt config file on host
├── dl/                       # Persistent download cache
└── bin/                      # Compiled firmware output
```

## 🚀Getting Started

### 1. Clone the repository and prepare host paths

```bash
git clone <YOUR_GITHUB_REPO_URL>
cd BPI-R4PRO-8X-OPENWRT-V24.10.0-Master-Devel-build-on-arm64

# Persistent cache/output directories
mkdir -p bin dl
```

### 2. Start the Docker container

```bash
docker compose up -d
docker compose exec bpi-builder bash
```

### 3. Build Firmware

⚙️ Target Configuration Check
Regardless of the option you choose, when the make menuconfig interface opens, please ensure the following fundamental settings are correctly selected:

- Target System: MediaTek ARM
- Subtarget: Filogic 8x0 (MT798x)
- Target Profile: Bananapi BPI-R4-PRO-8X

Inside the container (`/home/builduser/bpi`), choose one workflow:

#### Option A: Semi-Automated Build (Recommended)

This script updates feeds, applies arm64 patches, pre-compiles the toolchain, opens the menuconfig interface for you to select packages, and finally builds the firmware.

```bash
bash /home/builduser/scripts/build.sh -m auto
```

#### Option B: Manual Build (Advanced)

This script only updates feeds and applies the necessary patches. You will need to run the compilation commands manually.

```bash
bash /home/builduser/scripts/build.sh -m prepare

# Manual steps after build.sh prepare
make defconfig
make menuconfig
make tools/compile -j$(nproc) V=s
make toolchain/compile -j$(nproc) V=s
make package/firmware/linux-firmware/compile -j$(nproc) V=s
make -j$(nproc) V=s
```

### build.sh CLI options

```bash
# Show help (also shown when no args are provided)
bash /home/builduser/scripts/build.sh --help

# Set parallel jobs
bash /home/builduser/scripts/build.sh -m auto -j 8

# Resume from a step
bash /home/builduser/scripts/build.sh -m auto --from toolchain

# Skip one or more steps
bash /home/builduser/scripts/build.sh -m auto --skip menuconfig,linux-firmware

# Skip only menuconfig in auto mode
bash /home/builduser/scripts/build.sh -m auto --skip-menuconfig
```

Available step names:
`apply-configs`, `feeds`, `patch-golang`, `defconfig`, `tools`, `toolchain`, `linux-firmware`, `menuconfig`, `final-build`

Each run writes a timestamped log file to `logs/build-YYYYmmdd-HHMMSS.log`.
If the build completes successfully, firmware images are generated in `bin/targets/mediatek/filogic/`.

## ⏱ Build Time Reference

- Host: Apple Silicon `M1 Max`
- Docker VM allocation: `8 CPU cores`, `16 GB RAM`
- `bash /home/builduser/scripts/build.sh -m auto`: approximately **1 hour**

Build time varies with package selection, cache warm-up state (`dl/`, `bin/`), and network speed.

## ⚠️Important Note for BPI-R4 Pro (10G SFP+)

To ensure the 10G SFP+ ports work correctly, make sure the following packages are selected in `make menuconfig`:

- `kmod-sfp`
- `kmod-mt7988-eth`
- `ethtool` (highly recommended for checking link speeds)

## ⚠️ Disclaimer
This project and the provided scripts are distributed "as is" and without any warranty. Flashing custom firmware carries inherent risks and may potentially brick your device or void your warranty. The author(s) of this repository are not responsible for any hardware damage, data loss, or network instability that may occur. **Use at your own risk.**

## 📜 Credits & License
* Base OpenWrt branch provided by [BPI-SINOVOIP](https://github.com/BPI-SINOVOIP).
* The custom Golang Makefile (`configs/golang-Makefile`) is originally authored by Jeffery To.
* This project is licensed under the **GNU General Public License v2.0**.
