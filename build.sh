#!/bin/bash
#
# Kernel build script for OnePlus Nord CE2 Lite 5G (oscaro) with KernelSU support
#
# Thanks to @StratoNeutro for base script

# Exit on any error
set -e

# -----------------
# ARGUMENT PARSING
# -----------------

CLEAN_BUILD=false
DEFCONFIG1="vendor/lahaina-qgki_defconfig"
DEFCONFIG2="vendor/oplus_yupik_QGKI.config"
TOOLCHAIN_TYPE="system"  # Options: aosp, gcc, system

# Parse arguments
for arg in "$@"; do
    case $arg in
        --clean)
            CLEAN_BUILD=true
            echo "==> Clean build enabled"
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --clean         Perform a clean build"
            echo "  --help, -h      Show this help message"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# -----------------
# BUILD LOG SETUP
# -----------------

LOG_DIR="${PWD}/../logs"
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"

# Redirect all output (stdout + stderr) to log + terminal
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==> Build log: $LOG_FILE"

# -----------------
# BUILD CONFIGURATION
# -----------------
# Set your build user and host for the kernel version string
export KBUILD_BUILD_USER="okkotsu"
export KBUILD_BUILD_HOST="${HOSTNAME}"

# Set the architecture and sub-architecture
export ARCH=arm64
export SUBARCH=arm64

# Define the output directory
CONFIG="${PWD}/.."
OUTPUT_DIR="${CONFIG}/out"

# Define kernel source tree path
KERNEL_SRC="${PWD}"

# AnyKernel3 configuration
ANYKERNEL_DIR="${PWD}/../AnyKernel3"
KERNEL_NAME="AmpereKernel"
KERNEL_VERSION="1.0"
DEVICE_CODENAME="ziti"

# -----------------
# ANYKERNEL3 SETUP
# -----------------
setup_anykernel() {
    echo "==> Setting up AnyKernel3..."
    
    if [ ! -d "$ANYKERNEL_DIR" ]; then
        echo "==> Cloning AnyKernel3..."
        git clone https://github.com/ziti-resources/AnyKernel3.git "$ANYKERNEL_DIR" --depth 1
    fi
    
    # Configure AnyKernel3
    cat > "$ANYKERNEL_DIR/anykernel.sh" << 'EOF'
# AnyKernel3 Ramdisk Mod Script
# osm0sis @ xda-developers

## AnyKernel setup
# begin properties
properties() { '
kernel.string=AmpereKernel for OnePlus Nord CE3 5G
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=ziti
device.name2=OnePlus Nord CE3 5G
device.name3=CPH2569
device.name4=OP5953L1
device.name5=
supported.versions=16-17
supported.patchlevels=
'; } # end properties

# shell variables
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see for reference
. tools/ak3-core.sh;

## AnyKernel install
dump_boot;

write_boot;
## end install
EOF
    
    echo "==> AnyKernel3 setup complete"
}

# -----------------
# PACKAGE KERNEL
# -----------------
package_kernel() {
    echo ""
    echo "==> Packaging kernel with AnyKernel3..."
    
    KERNEL_IMG="$OUTPUT_DIR/arch/arm64/boot/Image"
    
    if [ ! -f "$KERNEL_IMG" ]; then
        echo "✗ Kernel image not found at $KERNEL_IMG"
        exit 1
    fi
    
    # Clean AnyKernel3 directory
    rm -rf "$ANYKERNEL_DIR"/*.zip
    rm -rf "$ANYKERNEL_DIR"/Image*
    rm -rf "$ANYKERNEL_DIR"/modules
    
    # Copy kernel files
    cp "$KERNEL_IMG" "$ANYKERNEL_DIR/"
    echo "✓ Copied kernel Image"
    
    # Create zip
    ZIP_NAME="$KERNEL_NAME-$KERNEL_VERSION-$DEVICE_CODENAME-$(date +%Y%m%d-%H%M).zip"
    cd "$ANYKERNEL_DIR"
    zip -r9 "$ZIP_NAME" * -x .git README.md *placeholder
    mv "$ZIP_NAME" "$KERNEL_SRC/"
    cd "$KERNEL_SRC"
    
    echo "✓ Kernel packaged: $ZIP_NAME"
    echo "✓ Flashable zip location: $KERNEL_SRC/$ZIP_NAME"
}

# -----------------
# TOOLCHAIN SETUP
# -----------------

# Set cross-compile variables
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export SRCTREE="${KERNEL_SRC}"

# Enable Clang for non-GCC builds
if [ "$TOOLCHAIN_TYPE" != "gcc" ]; then
    export LLVM=1
    export LLVM_IAS=1
fi

# -----------------
# BUILD PROCESS
# -----------------
echo "==============================================="
echo "  Kernel Build Script - Fixed Toolchain"
echo "==============================================="
echo "Device: OnePlus Nord CE3 5G (ziti)"
echo "Platform: Lahaina (SM8350) - GKI 1.0"
echo "Defconfig: $DEFCONFIG1 $DEFCONFIG2"
echo "Clean Build: $CLEAN_BUILD"
echo "Toolchain: $TOOLCHAIN_TYPE"
echo "==============================================="

# Clean the source tree if requested
if [ "$CLEAN_BUILD" = true ]; then
    echo "==> Cleaning source tree (mrproper)..."
    make O=$OUTPUT_DIR mrproper
else
    echo "==> Skipping clean (incremental build)..."
fi

# Set the kernel configuration file
echo "==> Setting up config: $DEFCONFIG1 $DEFCONFIG2"
make O=$OUTPUT_DIR ARCH=arm64 ${DEFCONFIG1} ${DEFCONFIG2}

# Regenerate config
make O=$OUTPUT_DIR ARCH=arm64 olddefconfig

# Common make arguments
MAKE_ARGS=(
    -j$(nproc --all)
    O=$OUTPUT_DIR
    ARCH=arm64
)

# Add Clang-specific args if using Clang
if [ "$TOOLCHAIN_TYPE" != "gcc" ]; then
    MAKE_ARGS+=(
        -j$(nproc --all)
        CC=clang
        LD=ld.lld
        AR=llvm-ar
        NM=llvm-nm
        OBJCOPY=llvm-objcopy
        OBJDUMP=llvm-objdump
        STRIP=llvm-strip
        LLVM=1
        LLVM_IAS=1
    )
fi

# Add cross-compilation
MAKE_ARGS+=(
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
)

# Start the compilation process
echo "==> Starting kernel compilation..."
echo "Make args: ${MAKE_ARGS[@]}"
export KCFLAGS="-O3 -flto=thin -march=armv8.2-a+crypto+dotprod"
echo "Started with ${KCFLAGS}"

make "${MAKE_ARGS[@]}"

# -----------------
# BUILD VERIFICATION
# -----------------

echo ""
echo "==> Build verification..."
if [ -f "${OUTPUT_DIR}/arch/arm64/boot/Image" ]; then
    KERNEL_SIZE=$(stat -c%s "${OUTPUT_DIR}/arch/arm64/boot/Image")
    echo "✓ Kernel Image: $(echo "scale=2; $KERNEL_SIZE/1024/1024" | bc) MB"
else
    echo "✗ Kernel Image not found!"
    exit 1
fi

# -----------------
# ANYKERNEL3 PACKAGING
# -----------------

setup_anykernel
package_kernel

# -----------------
# COMPLETION
# -----------------

echo ""
echo "==============================================="
echo "        Build finished successfully!           "
echo "==============================================="
echo "Toolchain: $TOOLCHAIN_TYPE"
echo "Kernel Image: ${OUTPUT_DIR}/arch/arm64/boot/Image"
echo "Flashable ZIP: ${KERNEL_SRC}/$KERNEL_NAME-$KERNEL_VERSION-$DEVICE_CODENAME-*.zip"
echo "==============================================="
