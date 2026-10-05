#!/usr/bin/env bash
#
# Kernel build script for OnePlus Nord CE3 5G (ziti)
#
# Thanks to @StratoNeutro and @NoCache-69 for the base script.
#
# Run from the root of the kernel source tree. Needs anykernel.sh.in
# (the AnyKernel3 template) next to this script.
#
# Environment overrides (all optional):
#   BUILD_DIR            Where out/, logs/ and zips go      (default: ../build)
#   BUILD_USER/HOST      KBUILD_BUILD_USER / KBUILD_BUILD_HOST
#   KERNEL_VERSION       Overrides the version taken from CONFIG_LOCALVERSION
#   CLANG_DIR            Toolchain root; $CLANG_DIR/bin is put first in PATH
#   ANYKERNEL_REF        AnyKernel3 commit/tag to pin to
#   ANYKERNEL_TEMPLATE   Path to the anykernel.sh template
#   EXTRA_KCFLAGS        Extra flags appended to KCFLAGS (e.g. -Wno-error)
#   KEEP_LOGS            Number of build logs to keep       (default: 10)

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_SRC="$PWD"

BUILD_DIR="$(realpath -m "${BUILD_DIR:-$KERNEL_SRC/../build}")"
OUT_DIR="$BUILD_DIR/out"
LOG_DIR="$BUILD_DIR/logs"
KEEP_LOGS="${KEEP_LOGS:-10}"

DEFCONFIGS=(
    vendor/lahaina-qgki_defconfig
    vendor/oplus_yupik_QGKI.config
)
CONFIG_FRAGMENT="$KERNEL_SRC/arch/arm64/configs/vendor/oplus_yupik_QGKI.config"

# Only the boot Image is packaged, so only build that.
# Set to "" to build the default target (Image, dtbs, modules, ...).
BUILD_TARGETS="Image"

KERNEL_NAME="AmpereKernel"
DEVICE_CODENAME="ziti"
# Taken from CONFIG_LOCALVERSION so the version only lives in one place.
KERNEL_VERSION="${KERNEL_VERSION:-$(sed -n 's/^CONFIG_LOCALVERSION=".*-\([^-"]*\)"/\1/p' "$CONFIG_FRAGMENT" 2>/dev/null || true)}"
KERNEL_VERSION="${KERNEL_VERSION:-dev}"

ANYKERNEL_DIR="$BUILD_DIR/AnyKernel3"
ANYKERNEL_STAGE="$BUILD_DIR/ak3-stage"
ANYKERNEL_REPO="https://github.com/ziti-resources/AnyKernel3.git"
ANYKERNEL_REF="${ANYKERNEL_REF:-}"
ANYKERNEL_TEMPLATE="${ANYKERNEL_TEMPLATE:-$SCRIPT_DIR/anykernel.sh.in}"

BUILD_USER="${BUILD_USER:-okkotsu}"
BUILD_HOST="${BUILD_HOST:-}"

CLEAN_BUILD=false
AGGRESSIVE=false
REPRODUCIBLE=false
MENUCONFIG=false
MAKE_ZIP=true
USE_CCACHE=auto
JOBS=""

LOG_FILE=""
TEE_PID=""
START_TIME=$SECONDS
ZIP_STAMP="$(date +%Y%m%d-%H%M)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
step() { echo; echo "==> $*"; }
ok()   { echo "✓ $*"; }
warn() { echo "! $*" >&2; }
die()  { echo "✗ $*" >&2; exit 1; }

# Parallel jobs: min(CPU count, available RAM / ~1.5 GiB). ThinLTO and clang
# can use a lot of memory per job; override with -j if you know better.
default_jobs() {
    local cpus mem_kb by_mem
    cpus="$(nproc)"
    mem_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
    if [ -n "$mem_kb" ] && [ "$mem_kb" -gt 0 ]; then
        by_mem=$((mem_kb / 1572864))
        if [ "$by_mem" -lt 1 ]; then by_mem=1; fi
        if [ "$by_mem" -lt "$cpus" ]; then cpus="$by_mem"; fi
    fi
    echo "$cpus"
}
DEFAULT_JOBS="$(default_jobs)"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --clean         Wipe the output dir and run mrproper before building
  --aggressive    Add -O3 and -march=armv8.2-a+crypto+dotprod to KCFLAGS
  --reproducible  Pin KBUILD_BUILD_TIMESTAMP to the last commit date and use
                  a generic build host (unless BUILD_HOST is set)
  --menuconfig    Configure, run menuconfig, write the changed options to
                  \$BUILD_DIR/menuconfig-changes.config, then exit (no build)
  --no-zip        Build the Image only, skip AnyKernel3 packaging
  --no-ccache     Don't use ccache even if it is installed
  -j, --jobs N    Parallel jobs (default: $DEFAULT_JOBS, based on CPUs and RAM)
  -h, --help      Show this help message
EOF
}

kmake() { make "${MAKE_ARGS[@]}" "$@"; }

# Refuse to run rm -rf on anything that isn't clearly a disposable out dir.
guard_out_dir() {
    local out src
    out="$(realpath -m "$OUT_DIR")"
    src="$(realpath -m "$KERNEL_SRC")"

    [ -n "$out" ] && [ "$out" != "/" ] || die "Refusing to use '$out' as the output dir"
    [ "$out" != "${HOME:-}" ]          || die "Refusing to use \$HOME as the output dir"
    case "$src/" in "$out"/*) die "Output dir '$out' contains the source tree" ;; esac
    case "$out/" in "$src"/*) die "Output dir '$out' is inside the source tree; set BUILD_DIR elsewhere" ;; esac
}

prune_logs() {
    local old=()
    mapfile -t old < <(find "$LOG_DIR" -maxdepth 1 -name 'build-*.log' -printf '%T@ %p\n' \
        | sort -rn | tail -n +$((KEEP_LOGS + 1)) | cut -d' ' -f2-)
    if [ "${#old[@]}" -gt 0 ]; then rm -f "${old[@]}"; fi
}

# Send stdout+stderr to the terminal and a log file.
setup_logging() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"
    exec 3>&1 4>&2
    exec > >(tee -a "$LOG_FILE") 2>&1
    TEE_PID=$!
    prune_logs
}

# Restore the real stdout/stderr and wait for tee so the log's tail isn't lost.
cleanup() {
    if [ -n "$TEE_PID" ]; then
        exec 1>&3 2>&4 3>&- 4>&-
        wait "$TEE_PID" 2>/dev/null || true
    fi
}

trap 'echo "✗ Build failed (line $LINENO, exit $?)" >&2' ERR
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --clean)        CLEAN_BUILD=true ;;
        --aggressive)   AGGRESSIVE=true ;;
        --reproducible) REPRODUCIBLE=true ;;
        --menuconfig)   MENUCONFIG=true ;;
        --no-zip)       MAKE_ZIP=false ;;
        --no-ccache)    USE_CCACHE=never ;;
        -j|--jobs)
            JOBS="${2:-}"
            [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs needs a positive integer"
            shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done
JOBS="${JOBS:-$DEFAULT_JOBS}"

# ---------------------------------------------------------------------------
# Sanity checks and toolchain
# ---------------------------------------------------------------------------
[ -f "$KERNEL_SRC/Makefile" ] || die "Run this script from the kernel source root"
guard_out_dir

if [ -n "${CLANG_DIR:-}" ]; then
    [ -d "$CLANG_DIR/bin" ] || die "CLANG_DIR '$CLANG_DIR' has no bin/ directory"
    export PATH="$CLANG_DIR/bin:$PATH"
fi

# Host tools the kernel build itself needs, plus the LLVM binutils.
for tool in make git zip tar bc flex bison sha256sum \
            clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-strip; do
    command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
done
if $MAKE_ZIP && ! $MENUCONFIG; then
    [ -f "$ANYKERNEL_TEMPLATE" ] || die "Missing AnyKernel template: $ANYKERNEL_TEMPLATE"
fi

CC_CMD="clang"
if [ "$USE_CCACHE" = auto ] && command -v ccache >/dev/null 2>&1; then
    CC_CMD="ccache clang"
    export CCACHE_BASEDIR="$KERNEL_SRC"
fi

# Build identity
if $REPRODUCIBLE; then
    if ts="$(git -C "$KERNEL_SRC" log -1 --format=%cI 2>/dev/null)" && [ -n "$ts" ]; then
        export KBUILD_BUILD_TIMESTAMP="$ts"
    else
        die "--reproducible needs the kernel source to be a git checkout"
    fi
    BUILD_HOST="${BUILD_HOST:-builder}"
fi
BUILD_HOST="${BUILD_HOST:-${HOSTNAME:-$(hostname)}}"

export ARCH=arm64
export KBUILD_BUILD_USER="$BUILD_USER"
export KBUILD_BUILD_HOST="$BUILD_HOST"

# NOTE: KCFLAGS must be passed on the make command line. A command-line
# variable always beats an exported one, so exporting it separately would
# silently throw the extra flags away.
# LTO is controlled by CONFIG_LTO_CLANG_* in the defconfig, not by KCFLAGS.
KCFLAGS="-mtune=cortex-a78"
if $AGGRESSIVE; then
    KCFLAGS+=" -O3 -march=armv8.2-a+crypto+dotprod"
fi
if [ -n "${EXTRA_KCFLAGS:-}" ]; then
    KCFLAGS+=" $EXTRA_KCFLAGS"
fi

MAKE_ARGS=(
    -C "$KERNEL_SRC"
    O="$OUT_DIR"
    ARCH=arm64
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
    CLANG_TRIPLE=aarch64-linux-gnu-
    CC="$CC_CMD"
    LD=ld.lld
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip
    LLVM=1
    LLVM_IAS=1
    -j"$JOBS"
)

# menuconfig needs a real terminal, so it must not run behind the tee pipe.
if ! $MENUCONFIG; then
    setup_logging
fi

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
configure_kernel() {
    step "Configuring"
    local cfg
    for cfg in "${DEFCONFIGS[@]}"; do
        kmake "$cfg"          # defconfig first, then fragments merge into .config
    done
    kmake olddefconfig

    # The 32-bit compat vDSO needs its own cross compiler.
    # if grep -q '^CONFIG_COMPAT_VDSO=y' "$OUT_DIR/.config"; then
    #     command -v arm-linux-gnueabi-gcc >/dev/null 2>&1 \
    #         || die "CONFIG_COMPAT_VDSO=y but arm-linux-gnueabi-gcc is missing"
    # fi
}

run_menuconfig() {
    local base="$OUT_DIR/.config.before" changes="$BUILD_DIR/menuconfig-changes.config"
    cp "$OUT_DIR/.config" "$base"
    kmake menuconfig

    # Lines present in the new .config but not the old one (valid fragment syntax).
    diff --new-line-format='%L' --old-line-format='' --unchanged-line-format='' \
        <(grep -E '^(CONFIG_|# CONFIG_)' "$base" | sort) \
        <(grep -E '^(CONFIG_|# CONFIG_)' "$OUT_DIR/.config" | sort) > "$changes" || true

    ok "Changed options written to: $changes"
    echo "   Merge what you want to keep into: $CONFIG_FRAGMENT"
    echo
    cat "$changes"
}

verify_build() {
    step "Verifying build"
    local image="$OUT_DIR/arch/arm64/boot/Image" magic release
    [ -f "$image" ] || die "Kernel Image not found at $image"

    # arm64 Image header carries the magic "ARM\x64" at offset 56.
    magic="$(od -An -tx1 -j56 -N4 "$image" | tr -d ' \n')"
    [ "$magic" = "41524d64" ] || die "Image has no valid arm64 header (magic: $magic)"

    release="$(cat "$OUT_DIR/include/config/kernel.release" 2>/dev/null || true)"
    ok "Kernel Image: $(du -h "$image" | cut -f1)"
    ok "Kernel release: ${release:-unknown}"
    case "$release" in
        *"$KERNEL_VERSION"*) ;;
        *) warn "Release string doesn't contain '$KERNEL_VERSION'; check CONFIG_LOCALVERSION" ;;
    esac
}

setup_anykernel() {
    step "Preparing AnyKernel3"
    if [ ! -d "$ANYKERNEL_DIR/.git" ]; then
        git clone --depth 1 "$ANYKERNEL_REPO" "$ANYKERNEL_DIR"
    fi
    if [ -n "$ANYKERNEL_REF" ]; then
        git -C "$ANYKERNEL_DIR" fetch --depth 1 origin "$ANYKERNEL_REF"
        git -C "$ANYKERNEL_DIR" checkout --quiet --detach FETCH_HEAD
    else
        warn "ANYKERNEL_REF not set; using the clone as-is. Pin it for reproducible zips."
    fi
    ok "AnyKernel3 at $(git -C "$ANYKERNEL_DIR" rev-parse --short HEAD)"
}

# Usage: package_kernel VARNAME   (stores the zip's file name in VARNAME)
package_kernel() {
    step "Packaging kernel with AnyKernel3"
    local image="$OUT_DIR/arch/arm64/boot/Image"
    local zip_name="$KERNEL_NAME-$KERNEL_VERSION-$DEVICE_CODENAME-$ZIP_STAMP.zip"

    # Stage from the committed tree so the clone is never modified.
    rm -rf "$ANYKERNEL_STAGE"
    mkdir -p "$ANYKERNEL_STAGE"
    git -C "$ANYKERNEL_DIR" archive HEAD | tar -x -C "$ANYKERNEL_STAGE"

    sed -e "s|@KERNEL_NAME@|$KERNEL_NAME|g" \
        -e "s|@KERNEL_VERSION@|$KERNEL_VERSION|g" \
        -e "s|@DEVICE_CODENAME@|$DEVICE_CODENAME|g" \
        "$ANYKERNEL_TEMPLATE" > "$ANYKERNEL_STAGE/anykernel.sh"
    cp "$image" "$ANYKERNEL_STAGE/"
    ok "Staged Image and anykernel.sh"

    rm -f "$BUILD_DIR/$zip_name" "$BUILD_DIR/$zip_name.sha256"
    (
        cd "$ANYKERNEL_STAGE"
        zip -r9 -q "$BUILD_DIR/$zip_name" . -x ".git*" "README.md" "*placeholder"
    )
    (
        cd "$BUILD_DIR"
        sha256sum "$zip_name" > "$zip_name.sha256"
    )
    ok "Packaged: $BUILD_DIR/$zip_name"
    ok "SHA-256:  $(cut -d' ' -f1 "$BUILD_DIR/$zip_name.sha256")"

    printf -v "$1" '%s' "$zip_name"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
cat <<EOF
===============================================
            Kernel Build Script
===============================================
Device:     OnePlus Nord CE3 5G ($DEVICE_CODENAME)
Platform:   Yupik - GKI 1.0
Version:    $KERNEL_NAME $KERNEL_VERSION
Defconfig:  ${DEFCONFIGS[*]}
Clean:      $CLEAN_BUILD
Jobs:       $JOBS
KCFLAGS:    $KCFLAGS
Compiler:   $CC_CMD ($(clang --version | head -n1))
Linker:     $(ld.lld --version | head -n1)
Reproducible: $REPRODUCIBLE
Log:        ${LOG_FILE:-none}
===============================================
EOF

if $CLEAN_BUILD; then
    step "Cleaning (rm out dir + mrproper)"
    rm -rf "$OUT_DIR"
    make -C "$KERNEL_SRC" mrproper
else
    step "Incremental build (use --clean for a fresh one)"
fi
mkdir -p "$OUT_DIR"

configure_kernel

if $MENUCONFIG; then
    run_menuconfig
    exit 0
fi

if [ "$CC_CMD" != "clang" ]; then ccache -z >/dev/null; fi

step "Compiling ${BUILD_TARGETS:-default targets}"
# shellcheck disable=SC2086  # BUILD_TARGETS is intentionally word-split
kmake KCFLAGS="$KCFLAGS" $BUILD_TARGETS

verify_build

ZIP_NAME=""
if $MAKE_ZIP; then
    setup_anykernel
    package_kernel ZIP_NAME
fi

ELAPSED=$((SECONDS - START_TIME))
echo
echo "==============================================="
echo "        Build finished successfully!"
echo "==============================================="
echo "Kernel Image:  $OUT_DIR/arch/arm64/boot/Image"
if [ -n "$ZIP_NAME" ]; then
    echo "Flashable ZIP: $BUILD_DIR/$ZIP_NAME"
fi
echo "Time taken:    $((ELAPSED / 60))m $((ELAPSED % 60))s"
if [ "$CC_CMD" != "clang" ]; then
    echo "ccache:"
    ccache -s | sed 's/^/  /'
fi
echo "==============================================="
