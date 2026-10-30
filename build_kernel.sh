#!/usr/bin/env bash
#
# build_kernel.sh - Build the UN1CA sm7125 kernel (a52q / a72q) as the tree
# currently is.
#
# Apply what you want in it first (apply_ksu.sh, apply_security_fixes.sh),
# or use build_all.sh, which applies everything, builds and reverts.
# Run it from the top of the kernel tree:
#
#     cd kernel_samsung_sm7125
#     ./build_kernel.sh                                   # asks what to build
#     ./build_kernel.sh --device both --ramdisk download  # no questions
#
# What it does:
#   1. Checks the build environment and stops, with the apt command that
#      fixes it, if anything is missing. It never installs anything.
#   2. Runs the tree's own build.sh for each device. Results go to
#      dist/<device>/. The kernel version string (uname -r) always ends in
#      "-g<commit>" for the checked-out commit, so the build is identifiable
#      and never matches stock. With --ramdisk extract, the boot.img security
#      patch level, the SEANDROIDENFORCE marker and the image size are copied
#      from the stock boot.img, and its AVB footer is re-created and signed
#      with AOSP's test key, as stock's is (test-keys/ next to this script).
#   3. If KernelSU-Next is applied, checks that it was built in.
#
# Options:
#   --device <a52q|a72q|both>   Device(s) to build (asked if omitted)
#   --ramdisk <mode>            Ramdisk for boot.img (asked if omitted):
#                                 extract   from a stock boot.img you provide
#                                 download  from github.com/frstprjkt/boot_samsung_sm7125
#                                 skip      build Image and dtbo.img only
#   --boot-img <dev>=<path>     Stock boot.img for "extract"
#                               (default: stock/<dev>/boot.img)
#   --clean                     Remove out/ before building
#   -h, --help                  Show this help

set -euo pipefail

ROOT_DIR="$PWD"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AVB_KEY="$SCRIPT_DIR/test-keys/testkey_rsa4096.pem"
OUT_DIR="$ROOT_DIR/out"
DIST_DIR="$ROOT_DIR/dist"
WORK_DIR="$ROOT_DIR/.build"

RAMDISK_REPO="https://github.com/frstprjkt/boot_samsung_sm7125"
RAMDISK_BRANCH="ramdisk"
RAMDISK_DIR="$WORK_DIR/ramdisk"

# What apply_ksu.sh adds to drivers/Makefile.
KSU_MAKEFILE_LINE='obj-$(CONFIG_KSU) += kernelsu/'

# "command:Debian package" pairs, and "file:Debian package" for headers.
REQUIRED_COMMANDS=(
    git:git make:make python3:python3 bc:bc bison:bison flex:flex perl:perl
    clang:clang ld.lld:lld llvm-ar:llvm llvm-nm:llvm llvm-objcopy:llvm
    llvm-objdump:llvm llvm-readelf:llvm llvm-strip:llvm
    mkbootimg:mkbootimg unpack_bootimg:mkbootimg openssl:openssl
)
REQUIRED_FILES=(
    /usr/include/openssl/opensslv.h:libssl-dev
)

SCMVERSION="$ROOT_DIR/.scmversion"

DEVICES=()
RAMDISK_MODE=""
declare -A BOOT_IMGS=()
declare -A STOCK_RELEASE=()
declare -A STOCK_PATCH_LEVEL=()
declare -A STOCK_HAS_AVB=()
CLEAN_SCM=""
CLEAN=0
WITH_KSU=0

CREATED_PATHS=()
TREE_BEFORE=""

log() {
    echo
    echo "==============================================="
    echo "$*"
    echo "==============================================="
}

die() {
    echo >&2
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    sed -n '3,/^set -euo pipefail$/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

is_interactive() {
    [ -t 0 ] && [ -t 1 ]
}

check_kernel_tree() {
    [ -f "$ROOT_DIR/build.sh" ] &&
        [ -f "$ROOT_DIR/arch/arm64/configs/vendor/atoll-sec-perf_defconfig" ] ||
        die "$ROOT_DIR is not the sm7125 kernel tree; run this from its top directory"
    git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        die "$ROOT_DIR is not a git checkout (needed for the kernel version string)"
}

check_environment() {
    log "Checking build environment"
    local missing=() packages=() entry item pkg

    for entry in "${REQUIRED_COMMANDS[@]}"; do
        item="${entry%%:*}" pkg="${entry##*:}"
        command -v "$item" >/dev/null 2>&1 || { missing+=("$item"); packages+=("$pkg"); }
    done
    for entry in "${REQUIRED_FILES[@]}"; do
        item="${entry%%:*}" pkg="${entry##*:}"
        [ -e "$item" ] || { missing+=("$item"); packages+=("$pkg"); }
    done
    [ -x "$ROOT_DIR/tools/mkdtimg" ] || missing+=("tools/mkdtimg (part of the kernel tree)")

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing: ${missing[*]}" >&2
        if [ ${#packages[@]} -gt 0 ]; then
            echo "Install from the Debian repositories with:" >&2
            echo "    sudo apt install $(printf '%s\n' "${packages[@]}" | sort -u | tr '\n' ' ')" >&2
        fi
        die "build environment incomplete"
    fi

    if [ -d "$ROOT_DIR/llvm-aosp" ]; then
        echo "NOTE: $ROOT_DIR/llvm-aosp exists; build.sh puts it ahead of the system clang."
    fi
    echo "OK ($(clang --version | head -n1))"
}

# KernelSU-Next counts as applied when drivers/Makefile builds it; its
# sources must then be linked in too.
check_kernelsu() {
    if grep -qxF "$KSU_MAKEFILE_LINE" "$ROOT_DIR/drivers/Makefile"; then
        [ -f "$ROOT_DIR/drivers/kernelsu/Kconfig" ] ||
            die "the KernelSU-Next hooks are applied but drivers/kernelsu is missing;
    run ./apply_ksu.sh again, or ./apply_ksu.sh --revert"
        WITH_KSU=1
        echo "KernelSU-Next: applied"
    else
        echo "KernelSU-Next: not applied"
    fi
}

choose_devices() {
    local answer="${1:-}"
    if [ -z "$answer" ]; then
        is_interactive || die "no device given; pass --device a52q, a72q or both"
        echo
        echo "Which device(s) should be built?"
        echo "  1) a52q"
        echo "  2) a72q"
        echo "  3) both"
        read -r -p "Choice [1-3]: " answer
        case "$answer" in
            1) answer=a52q ;;
            2) answer=a72q ;;
            3) answer=both ;;
        esac
    fi
    case "$answer" in
        a52q|a72q) DEVICES=("$answer") ;;
        both) DEVICES=(a52q a72q) ;;
        *) die "invalid device '$answer' (expected a52q, a72q or both)" ;;
    esac
}

choose_ramdisk_mode() {
    local answer="${1:-}"
    if [ -z "$answer" ]; then
        is_interactive || die "no ramdisk source given; pass --ramdisk extract, download or skip"
        echo
        echo "Where should the boot.img ramdisk come from?"
        echo "  1) extract  - from a stock boot.img you provide"
        echo "  2) download - from $RAMDISK_REPO"
        echo "  3) skip     - build Image and dtbo.img only, no boot.img"
        read -r -p "Choice [1-3]: " answer
        case "$answer" in
            1) answer=extract ;;
            2) answer=download ;;
            3) answer=skip ;;
        esac
    fi
    case "$answer" in
        extract|download|skip) RAMDISK_MODE="$answer" ;;
        *) die "invalid ramdisk source '$answer' (expected extract, download or skip)" ;;
    esac
}

# Resolve the stock boot.img of every selected device up front, so a missing
# file is reported before anything is downloaded or built.
locate_boot_images() {
    [ "$RAMDISK_MODE" = extract ] || return 0
    local dev path default
    for dev in "${DEVICES[@]}"; do
        default="stock/$dev/boot.img"
        path="${BOOT_IMGS[$dev]:-}"
        if [ -z "$path" ] && is_interactive; then
            read -r -p "Stock boot.img for $dev [$default]: " path
        fi
        path="${path:-$default}"
        case "$path" in /*) ;; *) path="$ROOT_DIR/$path" ;; esac
        [ -f "$path" ] || die "stock boot.img for $dev not found at $path
    Put the boot.img of a working $dev ROM there (e.g. from the UN1CA
    zip, or 'dd' the boot partition off the phone), or pass
    --boot-img $dev=<path>. Alternatively use --ramdisk download or skip."
        BOOT_IMGS[$dev]="$path"
        echo "$dev: using $path"
    done
}

# Release string up to the SCM part, e.g. "4.14.357-openela-valeryn": the
# Makefile version plus CONFIG_LOCALVERSION from the configs build.sh uses.
kernel_release_prefix() {
    local dev="$1" defconfig kver localversion
    defconfig="$(sed -n 's/^readonly DEFCONFIG="\(.*\)"$/\1/p' "$ROOT_DIR/build.sh")"
    [ -n "$defconfig" ] || die "cannot find DEFCONFIG in build.sh"
    kver="$(make -s -C "$ROOT_DIR" kernelversion 2>/dev/null)"
    localversion="$(cat "$ROOT_DIR/arch/arm64/configs/$defconfig" \
        "$ROOT_DIR/arch/arm64/configs/vendor/samsung/$dev.config" |
        sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' | tail -n1)"
    echo "$kver$localversion"
}

# Unpack each stock boot.img and record its kernel version string and
# security patch level, which the build copies.
inspect_stock_images() {
    [ "$RAMDISK_MODE" = extract ] || return 0
    local dev dir info release patch_level prefix
    mkdir -p "$WORK_DIR"
    for dev in "${DEVICES[@]}"; do
        dir="$WORK_DIR/unpack-$dev"
        rm -rf "$dir"
        info="$(unpack_bootimg --boot_img "${BOOT_IMGS[$dev]}" --out "$dir")"
        [ -s "$dir/ramdisk" ] || die "${BOOT_IMGS[$dev]} contains no ramdisk"

        patch_level="$(sed -n 's/^os patch level: //p' <<<"$info")"
        [ -n "$patch_level" ] || die "${BOOT_IMGS[$dev]} has no security patch level"
        release="$(grep -a -o -m1 'Linux version [^ ]*' "$dir/kernel" | cut -d' ' -f3)" || true
        release="${release%%$'\n'*}"
        [ -n "$release" ] || die "cannot read the kernel version from ${BOOT_IMGS[$dev]}"

        prefix="$(kernel_release_prefix "$dev")"
        case "$release" in
            "$prefix"-*) ;;
            *) die "the stock $dev kernel is $release, but this tree builds $prefix
    Its version string cannot be copied. Use the boot.img of a ROM whose
    kernel matches this tree, or --ramdisk download or skip." ;;
        esac
        STOCK_RELEASE[$dev]="$release"
        STOCK_PATCH_LEVEL[$dev]="$patch_level"
        echo "$dev: stock kernel $release, security patch level $patch_level"

        if [ "$(tail -c 64 "${BOOT_IMGS[$dev]}" | head -c 4)" = AVBf ]; then
            STOCK_HAS_AVB[$dev]=1
            [ -f "$AVB_KEY" ] || die "the stock $dev boot.img has an AVB footer, but $AVB_KEY is missing
    It is AOSP's test key, external/avb/test/data/testkey_rsa4096.pem in
    https://android.googlesource.com/platform/external/avb (see test-keys/README)."
            echo "$dev: stock boot.img has an AVB footer; it will be re-signed with the test key"
        fi
    done
}

# Identify every build by the commit it was built from: "-g<12-hex>", the
# format setlocalversion uses, written to .scmversion so the build picks it
# up. We emit it ourselves rather than let setlocalversion do it because it
# stays silent at a tagged HEAD (ours is) and would append "-dirty" for the
# applied hooks. The hooks are working-tree changes and do not move the
# commit, so this tells our build apart from stock and from other commits,
# not one hook set from another. build_device writes the file per device.
prepare_scmversion() {
    [ ! -e "$SCMVERSION" ] ||
        die "$SCMVERSION exists (left over from an interrupted run?); remove it"
    CREATED_PATHS+=("$SCMVERSION")
    CLEAN_SCM="-g$(git -C "$ROOT_DIR" rev-parse HEAD | cut -c1-12)"
}

prepare_ramdisks() {
    log "Preparing ramdisks ($RAMDISK_MODE)"
    rm -rf "$RAMDISK_DIR"
    mkdir -p "$RAMDISK_DIR"
    local dev repo="$WORK_DIR/ramdisk-repo"

    case "$RAMDISK_MODE" in
        extract)
            # Unpacked by inspect_stock_images.
            for dev in "${DEVICES[@]}"; do
                mv "$WORK_DIR/unpack-$dev/ramdisk" "$RAMDISK_DIR/ramdisk-$dev"
                rm -rf "$WORK_DIR/unpack-$dev"
            done
            ;;
        download)
            if [ -d "$repo/.git" ]; then
                git -C "$repo" fetch -q --depth=1 origin "$RAMDISK_BRANCH"
                git -C "$repo" checkout -q --detach FETCH_HEAD
            else
                rm -rf "$repo"
                git clone -q --depth=1 -b "$RAMDISK_BRANCH" "$RAMDISK_REPO" "$repo"
            fi
            for dev in "${DEVICES[@]}"; do
                [ -f "$repo/ramdisk-$dev" ] || die "$RAMDISK_REPO has no ramdisk-$dev"
                cp "$repo/ramdisk-$dev" "$RAMDISK_DIR/ramdisk-$dev"
            done
            ;;
        skip)
            # build.sh always packs a boot.img; give it an empty ramdisk and
            # throw that image away afterwards.
            for dev in "${DEVICES[@]}"; do
                : > "$RAMDISK_DIR/ramdisk-$dev"
            done
            ;;
    esac
    ls -l "$RAMDISK_DIR"
}

# build.sh expects boot/ramdisk-<dev> and mkbootimg/mkbootimg.py in the tree.
# Point those at our ramdisks and Debian's mkbootimg for the build only.
link_build_inputs() {
    local boot="$ROOT_DIR/boot" mkb="$ROOT_DIR/mkbootimg"
    local mkb_bin
    mkb_bin="$(command -v mkbootimg)"

    # A link we left behind in an interrupted run is ours to replace.
    if [ -e "$boot" ] || [ -L "$boot" ]; then
        [ "$(readlink "$boot")" = .build/ramdisk ] ||
            die "$boot exists; move it away so the selected ramdisk is used"
    fi
    ln -sfn .build/ramdisk "$boot"
    CREATED_PATHS+=("$boot")

    # cleanup removes in reverse order, so the directory goes in first.
    if [ -L "$mkb/mkbootimg.py" ] && [ "$(readlink "$mkb/mkbootimg.py")" = "$mkb_bin" ]; then
        CREATED_PATHS+=("$mkb" "$mkb/mkbootimg.py")
    elif [ ! -e "$mkb" ] || { [ -d "$mkb" ] && [ -z "$(ls -A "$mkb")" ]; }; then
        mkdir -p "$mkb"
        ln -s "$mkb_bin" "$mkb/mkbootimg.py"
        CREATED_PATHS+=("$mkb" "$mkb/mkbootimg.py")
    elif [ ! -f "$mkb/mkbootimg.py" ]; then
        die "$mkb exists but has no mkbootimg.py; remove it to use Debian's mkbootimg"
    fi
}

# Fingerprint of the tracked files' changes, to notice a build editing them.
tree_state() {
    git -C "$ROOT_DIR" diff HEAD | sha256sum
}

cleanup() {
    local status=$? i
    set +e
    for ((i = ${#CREATED_PATHS[@]} - 1; i >= 0; i--)); do
        if [ -L "${CREATED_PATHS[i]}" ] || [ -f "${CREATED_PATHS[i]}" ]; then
            rm -f "${CREATED_PATHS[i]}"
        else
            rmdir "${CREATED_PATHS[i]}" 2>/dev/null
        fi
    done
    if [ -n "$TREE_BEFORE" ] && [ "$(tree_state)" != "$TREE_BEFORE" ]; then
        echo "WARNING: the build modified tracked files (KernelSU-Next's Kbuild edits sources);" >&2
        echo "see git diff. The apply scripts' --revert may not undo this." >&2
    fi
    exit "$status"
}

verify_build() {
    [ "$WITH_KSU" -eq 1 ] || return 0
    local opt
    for opt in CONFIG_KSU=y CONFIG_KSU_MANUAL_HOOK=y; do
        grep -qx "$opt" "$OUT_DIR/.config" || die "$opt missing from $OUT_DIR/.config"
    done
    [ -f "$OUT_DIR/drivers/kernelsu/kernelsu.o" ] ||
        die "KernelSU-Next was not built into the kernel"
}

# Rewrite a boot.img with another security patch level, keeping every other
# header field and payload as they are.
set_patch_level() {
    local img="$1" level="$2" dir="$WORK_DIR/repack" args=() i
    rm -rf "$dir"
    mapfile -d '' args < <(unpack_bootimg --boot_img "$img" --out "$dir" --format=mkbootimg -0)
    for ((i = 0; i < ${#args[@]}; i++)); do
        if [ "${args[i]}" = --os_patch_level ]; then
            args[i + 1]="$level"
        fi
    done
    mkbootimg "${args[@]}" --output "$img"
    rm -rf "$dir"
    grep -qx "os patch level: $level" <<<"$(unpack_bootimg --boot_img "$img" --out "$dir")" ||
        die "failed to set the security patch level of $img"
    rm -rf "$dir"
}

# Stock UN1CA boot images carry Samsung's SEANDROIDENFORCE marker right after
# the image and are zero-padded to the partition size, which ends in an AVB
# hash footer. Mirror the marker and the size, and re-create the footer when
# stock has one; the padding also keeps a stale footer from surviving at the
# end of the partition.
match_stock_layout() {
    local dev="$1" img="$2" stock="$3" img_size stock_size
    if grep -qa SEANDROIDENFORCE "$stock"; then
        printf SEANDROIDENFORCE >> "$img"
    fi
    img_size="$(stat -c %s "$img")"
    stock_size="$(stat -c %s "$stock")"
    [ "$img_size" -le "$stock_size" ] ||
        die "$img ($img_size bytes) is larger than the stock image ($stock_size bytes)"
    if [ -n "${STOCK_HAS_AVB[$dev]:-}" ]; then
        avb_add_footer "$img" "$stock" "$AVB_KEY"
    else
        truncate -s "$stock_size" "$img"
    fi
}

# Give <image> the AVB hash footer of <stock>, signed with <key>: the stock
# vbmeta is the template (descriptors, salt, flags, release string), only the
# image size and digest change. Padded to the stock (partition) size.
# A stand-in for `avbtool add_hash_footer`, which Debian does not package.
avb_add_footer() {
    python3 -I - "$@" <<'PYEOF'
import hashlib, struct, subprocess, sys

FOOTER = struct.Struct(">4sIIQQQ28x")
HEADER = struct.Struct(">4sIIQQI11QII48s80x")
BLOCK = 4096


def avb_public_key(pem):
    out = subprocess.run(["openssl", "rsa", "-in", pem, "-noout", "-modulus"],
                         check=True, capture_output=True, text=True).stdout
    n = int(out.strip().split("=", 1)[1], 16)
    bits = n.bit_length()
    n0inv = (2**32 - pow(n, -1, 2**32)) % 2**32
    rr = pow(2, 2 * bits, n)
    return (struct.pack(">II", bits, n0inv) + n.to_bytes(bits // 8, "big")
            + rr.to_bytes(bits // 8, "big"))


def build(content, template, footer_version, partition_size, pem):
    (_, _, _, auth_size, aux_size, algorithm, hash_off, hash_size, sig_off,
     sig_size, pk_off, pk_size, _, _, desc_off, desc_size, *_) = HEADER.unpack(template[:256])
    if algorithm not in (1, 2, 3):  # SHA256_RSA2048/4096/8192
        sys.exit(f"unsupported AVB algorithm {algorithm}")
    header = template[:256]
    aux = bytearray(template[256 + auth_size:256 + auth_size + aux_size])

    hashed = 0
    pos = desc_off
    while pos < desc_off + desc_size:
        tag, length = struct.unpack_from(">QQ", aux, pos)
        body = pos + 16
        if tag == 2:  # hash descriptor
            _, alg, name_len, salt_len, digest_len, _ = struct.unpack_from(">Q32sIIII", aux, body)
            salt_at = body + 116 + name_len
            salt = bytes(aux[salt_at:salt_at + salt_len])
            digest = hashlib.new(alg.rstrip(b"\0").decode(), salt + content).digest()
            if len(digest) != digest_len:
                sys.exit("unexpected hash descriptor digest length")
            struct.pack_into(">Q", aux, body, len(content))
            aux[salt_at + salt_len:salt_at + salt_len + digest_len] = digest
            hashed += 1
        pos = body + length
    if hashed != 1:
        sys.exit(f"expected one hash descriptor in the stock vbmeta, found {hashed}")

    key = avb_public_key(pem)
    if len(key) != pk_size:
        sys.exit("the key does not have the size of the stock vbmeta key")
    aux[pk_off:pk_off + pk_size] = key

    signed = header + bytes(aux)
    signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", pem],
                               input=signed, check=True, capture_output=True).stdout
    if len(signature) != sig_size:
        sys.exit("unexpected signature size")
    auth = bytearray(auth_size)
    auth[hash_off:hash_off + hash_size] = hashlib.sha256(signed).digest()
    auth[sig_off:sig_off + sig_size] = signature
    vbmeta = header + bytes(auth) + bytes(aux)

    vbmeta_offset = -(-len(content) // BLOCK) * BLOCK
    image = content + bytes(vbmeta_offset - len(content)) + vbmeta
    if len(image) + FOOTER.size > partition_size:
        sys.exit("the image does not fit the partition")
    return (image + bytes(partition_size - FOOTER.size - len(image))
            + FOOTER.pack(b"AVBf", *footer_version, len(content), vbmeta_offset, len(vbmeta)))


img, stock_path, pem = sys.argv[1:]
stock = open(stock_path, "rb").read()
magic, major, minor, original_size, vbmeta_offset, vbmeta_size = FOOTER.unpack(stock[-64:])
if magic != b"AVBf":
    sys.exit(f"{stock_path} has no AVB footer")
template = stock[vbmeta_offset:vbmeta_offset + vbmeta_size]

# Self-test: if stock was signed with this key, re-signing its own content
# must reproduce it byte for byte.
fields = HEADER.unpack(template[:256])
auth_size, pk_off, pk_size = fields[3], fields[10], fields[11]
stock_key = template[256 + auth_size + pk_off:256 + auth_size + pk_off + pk_size]
if stock_key == avb_public_key(pem):
    if build(stock[:original_size], template, (major, minor), len(stock), pem) != stock:
        sys.exit("self-test failed: re-signing the stock boot.img does not reproduce it")
    print("AVB: self-test passed (stock footer reproduced with the test key)")
else:
    print("AVB: stock was signed with another key; signing with the test key instead")

content = open(img, "rb").read()
open(img, "wb").write(build(content, template, (major, minor), len(stock), pem))
print(f"AVB: footer added to {img}")
PYEOF
}

build_device() {
    local dev="$1" dest="$DIST_DIR/$1" prefix expected
    log "Building $dev"
    prefix="$(kernel_release_prefix "$dev")"
    expected="$prefix$CLEAN_SCM"
    echo "$CLEAN_SCM" > "$SCMVERSION"

    (cd "$ROOT_DIR" && bash ./build.sh "$dev")
    verify_build
    [ "$(cat "$OUT_DIR/include/config/kernel.release")" = "$expected" ] ||
        die "kernel version is $(cat "$OUT_DIR/include/config/kernel.release"), expected $expected"
    if [ "$RAMDISK_MODE" = extract ]; then
        set_patch_level "$ROOT_DIR/boot-$dev.img" "${STOCK_PATCH_LEVEL[$dev]}"
        match_stock_layout "$dev" "$ROOT_DIR/boot-$dev.img" "${BOOT_IMGS[$dev]}"
    fi

    rm -rf "$dest"
    mkdir -p "$dest"
    mv -f "$ROOT_DIR/dtbo-$dev.img" "$dest/dtbo.img"
    if [ "$RAMDISK_MODE" = skip ]; then
        rm -f "$ROOT_DIR/boot-$dev.img"
    else
        mv -f "$ROOT_DIR/boot-$dev.img" "$dest/boot.img"
    fi
    cp -f "$OUT_DIR/arch/arm64/boot/Image" "$dest/Image"
    cp -f "$OUT_DIR/include/config/kernel.release" "$dest/kernel.release"
}

device_arg=""
ramdisk_arg=""
while [ $# -gt 0 ]; do
    case "$1" in
        --device|--ramdisk|--boot-img)
            [ $# -ge 2 ] || die "$1 needs a value"
            case "$1" in
                --device) device_arg="$2" ;;
                --ramdisk) ramdisk_arg="$2" ;;
                --boot-img)
                    [[ "$2" =~ ^(a52q|a72q)=.+ ]] || die "--boot-img expects <a52q|a72q>=<path>"
                    BOOT_IMGS[${2%%=*}]="${2#*=}"
                    ;;
            esac
            shift
            ;;
        --clean) CLEAN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

check_kernel_tree
check_environment
check_kernelsu
choose_devices "$device_arg"
choose_ramdisk_mode "$ramdisk_arg"
locate_boot_images
inspect_stock_images

trap cleanup EXIT
trap 'exit 130' INT TERM
TREE_BEFORE="$(tree_state)"

prepare_ramdisks
prepare_scmversion
link_build_inputs

if [ "$CLEAN" -eq 1 ]; then
    log "Cleaning $OUT_DIR"
    rm -rf "$OUT_DIR"
fi

for dev in "${DEVICES[@]}"; do
    build_device "$dev"
done

log "Done"
for dev in "${DEVICES[@]}"; do
    echo "$dev ($(cat "$DIST_DIR/$dev/kernel.release")):"
    ls -1 "$DIST_DIR/$dev" | sed "s|^|  $DIST_DIR/$dev/|"
done
