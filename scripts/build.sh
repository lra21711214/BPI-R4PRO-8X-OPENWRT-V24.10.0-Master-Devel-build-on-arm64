#!/bin/bash
set -euo pipefail

DEFAULT_MODE="auto"
MODE=""
JOBS=""
SHOW_HELP=0
SKIP_MENUCONFIG=0
FROM_STEP=""
LOG_DIR="logs"
LOG_FILE=""

GOLANG_MAKEFILE_TARGET="feeds/packages/lang/golang/golang/Makefile"
GOLANG_MAKEFILE_SOURCE="/home/builduser/configs/golang-Makefile"
CUSTOM_FEEDS_SOURCE="/home/builduser/configs/feeds.conf.default"

declare -a SKIP_INPUTS=()
declare -a SKIP_STEPS=()
declare -a RUN_STEPS=()

declare -a PREPARE_STEPS=("apply-configs" "feeds" "patch-golang")
declare -a AUTO_STEPS=(
    "apply-configs"
    "feeds"
    "patch-golang"
    "defconfig"
    "tools"
    "toolchain"
    "linux-firmware"
    "menuconfig"
    "final-build"
)
declare -a ALL_STEPS=(
    "apply-configs"
    "feeds"
    "patch-golang"
    "defconfig"
    "tools"
    "toolchain"
    "linux-firmware"
    "menuconfig"
    "final-build"
)

print_usage() {
    cat <<'EOF'
Usage:
  bash scripts/build.sh -m <auto|prepare> [options]
  bash scripts/build.sh <auto|prepare> [options]

Modes:
  auto      Prepare + precompile + menuconfig + final build
  prepare   Prepare only (show manual build commands)

Options:
  -m MODE, --mode MODE          Build mode: auto or prepare
  -j N, --jobs N                Number of parallel jobs (default: nproc)
  --from STEP                   Start from a specific step
  --skip STEP[,STEP...]         Skip one or more steps (comma-separated, repeatable)
  --skip-menuconfig             Skip menuconfig in auto mode
  -h, --help                    Show this help

Available Steps:
  apply-configs, feeds, patch-golang, defconfig, tools,
  toolchain, linux-firmware, menuconfig, final-build

Examples:
  bash scripts/build.sh -m auto -j 8
  bash scripts/build.sh auto --skip-menuconfig
  bash scripts/build.sh -m auto --from toolchain
  bash scripts/build.sh -m auto --skip menuconfig,linux-firmware
  bash scripts/build.sh -m prepare --from feeds
EOF
}

error() {
    echo "Error: $*" >&2
    exit 1
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

contains_step() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Required command '$cmd' not found in PATH."
    fi
}

on_error() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]:-unknown}"
    local cmd="${BASH_COMMAND:-unknown}"

    echo ""
    echo "[ERROR] Build script failed."
    echo "[ERROR] Exit code: $exit_code"
    echo "[ERROR] Line: $line_no"
    echo "[ERROR] Command: $cmd"
    if [ -n "$LOG_FILE" ]; then
        echo "[ERROR] Log file: $LOG_FILE"
    fi
    exit "$exit_code"
}

ensure_openwrt_root() {
    if [ ! -x "./scripts/feeds" ]; then
        error "Run this script from the OpenWrt root directory (e.g. /home/builduser/bpi)."
    fi
}

check_architecture() {
    local arch
    arch=$(uname -m)
    if [ "$arch" != "aarch64" ] && [ "$arch" != "arm64" ]; then
        echo "======================================================="
        echo "WARNING: This environment is specifically tailored for arm64 (Apple Silicon)."
        echo "Current architecture detected: $arch"
        echo ""
        echo "For x86_64/amd64 hosts, it is recommended to use the original project:"
        echo "https://github.com/BPI-SINOVOIP/BPI-R4PRO-8X-OPENWRT-V24.10.0-Master-Devel"
        echo "======================================================="
        echo -n "Press Enter to continue anyway, or Ctrl+C to abort..."
        read -r
        echo ""
    fi
}

check_disk_space() {
    local min_space_gb=30
    local avail_blocks
    if avail_blocks=$(df -kP . | awk 'NR==2 {print $4}') && [ -n "$avail_blocks" ]; then
        local avail_gb=$((avail_blocks / 1024 / 1024))
        if [ "$avail_gb" -lt "$min_space_gb" ]; then
            echo "======================================================="
            echo "WARNING: Only ${avail_gb}GB of free disk space available."
            echo "OpenWrt build typically requires at least ${min_space_gb}GB."
            echo "Building may fail due to insufficient space."
            echo "======================================================="
            echo -n "Press Enter to continue anyway, or Ctrl+C to abort..."
            read -r
            echo ""
        else
            echo "Disk space check passed: ${avail_gb}GB available."
        fi
    fi
}

validate_jobs() {
    if [ -n "$JOBS" ]; then
        if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
            error "Invalid jobs value '$JOBS'. Use a positive integer."
        fi
        return
    fi

    JOBS="$(nproc)"
    if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
        error "Failed to determine a valid job count from nproc."
    fi
}

init_logging() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"
    if enable_tee_logging 2>/dev/null; then
        echo "Log file: $LOG_FILE"
    else
        echo "Warning: tee mirroring is unavailable in this environment. Logging only to file: $LOG_FILE" >&2
        exec >>"$LOG_FILE" 2>&1
        echo "Log file: $LOG_FILE"
    fi
}

enable_tee_logging() {
    exec > >(tee -a "$LOG_FILE") 2>&1
}

parse_skip_inputs() {
    local raw part cleaned
    for raw in "${SKIP_INPUTS[@]}"; do
        IFS=',' read -r -a parts <<< "$raw"
        for part in "${parts[@]}"; do
            cleaned="$(trim "$part")"
            if [ -n "$cleaned" ]; then
                SKIP_STEPS+=("$cleaned")
            fi
        done
    done
}

build_run_steps() {
    if [ "$MODE" = "prepare" ]; then
        RUN_STEPS=("${PREPARE_STEPS[@]}")
    else
        RUN_STEPS=("${AUTO_STEPS[@]}")
    fi

    if [ "$MODE" = "prepare" ] && [ "$SKIP_MENUCONFIG" -eq 1 ]; then
        echo "Warning: --skip-menuconfig is ignored in prepare mode."
    fi

    if [ "$MODE" = "auto" ] && [ "$SKIP_MENUCONFIG" -eq 1 ]; then
        local filtered=()
        local step
        for step in "${RUN_STEPS[@]}"; do
            if [ "$step" != "menuconfig" ]; then
                filtered+=("$step")
            fi
        done
        RUN_STEPS=("${filtered[@]}")
    fi
}

validate_step_controls() {
    local step

    if [ -n "$FROM_STEP" ]; then
        if ! contains_step "$FROM_STEP" "${ALL_STEPS[@]}"; then
            error "Unknown step for --from: '$FROM_STEP'."
        fi
        if ! contains_step "$FROM_STEP" "${RUN_STEPS[@]}"; then
            error "Step '$FROM_STEP' is not available in mode '$MODE'."
        fi
    fi

    for step in "${SKIP_STEPS[@]}"; do
        if ! contains_step "$step" "${ALL_STEPS[@]}"; then
            error "Unknown step for --skip: '$step'."
        fi
        if ! contains_step "$step" "${RUN_STEPS[@]}"; then
            error "Step '$step' cannot be skipped in mode '$MODE' because it is not active."
        fi
    done

    if [ -n "$FROM_STEP" ] && contains_step "$FROM_STEP" "${SKIP_STEPS[@]}"; then
        error "Step '$FROM_STEP' cannot be used in both --from and --skip."
    fi
}

print_run_plan() {
    local step
    echo "Mode: $MODE"
    echo "Jobs: $JOBS"
    echo "Run steps:"
    for step in "${RUN_STEPS[@]}"; do
        echo "  - $step"
    done

    if [ -n "$FROM_STEP" ]; then
        echo "Start from: $FROM_STEP"
    fi
    if [ "${#SKIP_STEPS[@]}" -gt 0 ]; then
        echo "Skip steps: ${SKIP_STEPS[*]}"
    fi
}

step_apply_configs() {
    echo "--- Step: apply-configs ---"
    if [ -f "$CUSTOM_FEEDS_SOURCE" ]; then
        cp "$CUSTOM_FEEDS_SOURCE" ./feeds.conf.default
        echo "Done: Custom feeds.conf.default applied."
    else
        echo "Warning: Custom feeds.conf.default not found. Using default."
    fi
}

step_feeds() {
    echo "--- Step: feeds ---"
    ./scripts/feeds update -a
    ./scripts/feeds install -a
}

step_patch_golang() {
    echo "--- Step: patch-golang ---"
    if [ ! -f "$GOLANG_MAKEFILE_SOURCE" ]; then
        error "Custom Golang Makefile not found: $GOLANG_MAKEFILE_SOURCE"
    fi

    local target_dir
    target_dir="$(dirname "$GOLANG_MAKEFILE_TARGET")"
    if [ ! -d "$target_dir" ]; then
        error "Target directory not found: $target_dir"
    fi
    if [ ! -f "$GOLANG_MAKEFILE_TARGET" ]; then
        error "Target Golang Makefile not found: $GOLANG_MAKEFILE_TARGET"
    fi

    cp "$GOLANG_MAKEFILE_SOURCE" "$GOLANG_MAKEFILE_TARGET"
    echo "Done: Replaced Golang Makefile with the custom arm64 version."
}

step_defconfig() {
    echo "--- Step: defconfig ---"
    make defconfig
}

step_tools() {
    echo "--- Step: tools ---"
    make tools/compile -j"$JOBS" V=s
}

step_toolchain() {
    echo "--- Step: toolchain ---"
    make toolchain/compile -j"$JOBS" V=s
}

step_linux_firmware() {
    echo "--- Step: linux-firmware ---"
    make package/firmware/linux-firmware/compile -j"$JOBS" V=s
}

step_menuconfig() {
    echo "--- Step: menuconfig ---"
    echo "The menuconfig interface will now open."
    echo "Select packages, save, and exit to continue."
    sleep 2
    make menuconfig
}

step_final_build() {
    echo "--- Step: final-build ---"
    make -j1 V=s
    echo "--- All Done! ---"
    echo "Build completed. Please check bin/targets/mediatek/filogic/ on your host machine."
}

run_step() {
    local step="$1"
    case "$step" in
        apply-configs) step_apply_configs ;;
        feeds) step_feeds ;;
        patch-golang) step_patch_golang ;;
        defconfig) step_defconfig ;;
        tools) step_tools ;;
        toolchain) step_toolchain ;;
        linux-firmware) step_linux_firmware ;;
        menuconfig) step_menuconfig ;;
        final-build) step_final_build ;;
        *) error "Internal error: unknown step '$step'." ;;
    esac
}

run_steps() {
    local from_reached=0
    local step
    if [ -z "$FROM_STEP" ]; then
        from_reached=1
    fi

    for step in "${RUN_STEPS[@]}"; do
        if [ "$from_reached" -eq 0 ]; then
            if [ "$step" = "$FROM_STEP" ]; then
                from_reached=1
            else
                echo "Skipping step '$step' (before --from '$FROM_STEP')."
                continue
            fi
        fi

        if contains_step "$step" "${SKIP_STEPS[@]}"; then
            echo "Skipping step '$step' (--skip)."
            continue
        fi

        run_step "$step"
    done
}

print_prepare_next_steps() {
    echo "======================================================="
    echo "Environment preparation complete."
    echo "Run the following commands manually:"
    echo ""
    echo "  1. make defconfig"
    echo "  2. make menuconfig"
    echo "  3. make tools/compile -j$JOBS V=s"
    echo "  4. make toolchain/compile -j$JOBS V=s"
    echo "  5. make package/firmware/linux-firmware/compile -j$JOBS V=s"
    echo "  6. make -j1 V=s"
    echo "======================================================="
}

parse_args() {
    local original_argc=$#
    local opt optarg_value
    local -a positional=()

    while getopts ":m:j:h-:" opt; do
        case "$opt" in
            m) MODE="$OPTARG" ;;
            j) JOBS="$OPTARG" ;;
            h) SHOW_HELP=1 ;;
            -)
                case "$OPTARG" in
                    help) SHOW_HELP=1 ;;
                    skip-menuconfig) SKIP_MENUCONFIG=1 ;;
                    mode)
                        optarg_value="${!OPTIND:-}"
                        [ -n "$optarg_value" ] || error "--mode requires an argument."
                        MODE="$optarg_value"
                        OPTIND=$((OPTIND + 1))
                        ;;
                    mode=*) MODE="${OPTARG#*=}" ;;
                    jobs)
                        optarg_value="${!OPTIND:-}"
                        [ -n "$optarg_value" ] || error "--jobs requires an argument."
                        JOBS="$optarg_value"
                        OPTIND=$((OPTIND + 1))
                        ;;
                    jobs=*) JOBS="${OPTARG#*=}" ;;
                    from)
                        optarg_value="${!OPTIND:-}"
                        [ -n "$optarg_value" ] || error "--from requires an argument."
                        FROM_STEP="$optarg_value"
                        OPTIND=$((OPTIND + 1))
                        ;;
                    from=*) FROM_STEP="${OPTARG#*=}" ;;
                    skip)
                        optarg_value="${!OPTIND:-}"
                        [ -n "$optarg_value" ] || error "--skip requires an argument."
                        SKIP_INPUTS+=("$optarg_value")
                        OPTIND=$((OPTIND + 1))
                        ;;
                    skip=*) SKIP_INPUTS+=("${OPTARG#*=}") ;;
                    *)
                        error "Unknown option '--$OPTARG'. Use --help for usage."
                        ;;
                esac
                ;;
            :)
                error "Option '-$OPTARG' requires an argument."
                ;;
            \?)
                error "Unknown option '-$OPTARG'. Use --help for usage."
                ;;
        esac
    done

    shift $((OPTIND - 1))
    positional=("$@")

    if [ "${#positional[@]}" -gt 0 ] && [ -z "$MODE" ]; then
        case "${positional[0]}" in
            auto|prepare)
                MODE="${positional[0]}"
                positional=("${positional[@]:1}")
                ;;
        esac
    fi

    if [ "${#positional[@]}" -gt 0 ]; then
        error "Unexpected argument(s): ${positional[*]}"
    fi

    if [ "$original_argc" -eq 0 ]; then
        SHOW_HELP=1
    fi

    if [ "$SHOW_HELP" -eq 1 ]; then
        print_usage
        exit 0
    fi

    if [ -z "$MODE" ]; then
        MODE="$DEFAULT_MODE"
    fi

    case "$MODE" in
        auto|prepare) ;;
        *) error "Unknown mode '$MODE'. Use auto or prepare." ;;
    esac
}

main() {
    parse_args "$@"
    ensure_openwrt_root
    check_architecture
    check_disk_space
    require_command make
    require_command tee
    if [ -z "$JOBS" ]; then
        require_command nproc
    fi
    validate_jobs
    parse_skip_inputs
    build_run_steps
    validate_step_controls
    init_logging
    trap on_error ERR
    print_run_plan
    run_steps

    if [ "$MODE" = "prepare" ]; then
        print_prepare_next_steps
    fi
}

main "$@"
