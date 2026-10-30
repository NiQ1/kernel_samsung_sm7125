#!/usr/bin/env bash
#
# patch_rom_zip.sh - Put a KernelSU-Next kernel into a UN1CA flashable ZIP.
#
# Run it from the top of the kernel tree, next to the build scripts:
#
#     ./patch_rom_zip.sh UN1CA_3.2.1-9f8add9e_20260929_a52q-sign.zip
#
# What it does:
#   1. Reads the target device (a52q / a72q) from the ZIP's build_info.txt.
#   2. Extracts the ZIP's boot.img and has build_all.sh build the kernel
#      (KernelSU-Next and the security fixes) with it as the stock image
#      (ramdisk, version string, patch level and layout all come from it).
#      With --as-is, build_kernel.sh builds the tree as it is instead, with
#      whatever you applied yourself.
#   3. Writes a new ZIP in which only boot.img is replaced. Every other entry
#      is copied unchanged and checked against the original's CRC.
#   4. Signs it with signapk -w, as UN1CA does, but with AOSP's test key
#      (test-keys/ next to this script): UN1CA's own key is not public. This
#      also replaces META-INF/com/android/otacert with the test certificate.
#      The signature is then verified.
#
# Options:
#   -o, --output <path>   Output ZIP (default: dist/<name>-ksu.zip, with a
#                         trailing "-sign" dropped from the name)
#   --as-is               Build the tree as it is (default output name ends
#                         in -custom instead of -ksu)
#   --ksu-ref <ref>       Passed on to build_all.sh (not with --as-is)
#   --clean               Passed on to the build script
#   -h, --help            Show this help

set -euo pipefail

ROOT_DIR="$PWD"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ALL="$SCRIPT_DIR/build_all.sh"
BUILD_KERNEL="$SCRIPT_DIR/build_kernel.sh"
OTA_CERT="$SCRIPT_DIR/test-keys/testkey.x509.pem"
OTA_KEY="$SCRIPT_DIR/test-keys/testkey.pk8"
DIST_DIR="$ROOT_DIR/dist"
WORK_DIR="$ROOT_DIR/.build/rom-zip"

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

# python3 -I so nothing next to the ZIP or in $PWD is imported.
zip_tool() {
    python3 -I - "$@" <<'PYEOF'
import os, struct, subprocess, sys, zipfile, zlib

OTACERT = "META-INF/com/android/otacert"

def read_device(path):
    z = zipfile.ZipFile(path)
    names = set(z.namelist())
    if "build_info.txt" in names:
        for line in z.read("build_info.txt").decode().splitlines():
            if line.startswith("device="):
                return line.split("=", 1)[1].strip()
    return ""

def extract(path, member, dest):
    with zipfile.ZipFile(path) as z, z.open(member) as src, open(dest, "wb") as out:
        while chunk := src.read(1 << 20):
            out.write(chunk)

def crc_of(path):
    crc = 0
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            crc = zlib.crc32(chunk, crc)
    return crc

def rebuild(src_path, member, new_file, out_path):
    """Copy src_path to out_path in entry order, replacing member with
    new_file. Reading verifies every source CRC; the written CRCs are
    compared with the source afterwards."""
    with zipfile.ZipFile(src_path) as zin, \
         zipfile.ZipFile(out_path, "w", allowZip64=True) as zout:
        for info in zin.infolist():
            zi = zipfile.ZipInfo(info.filename, info.date_time)
            zi.compress_type = info.compress_type
            zi.create_system = info.create_system
            zi.external_attr = info.external_attr
            if info.filename == member:
                src = open(new_file, "rb")
                zi.file_size = os.path.getsize(new_file)
            else:
                src = zin.open(info)
                zi.file_size = info.file_size
            with src, zout.open(zi, "w") as dst:
                while chunk := src.read(1 << 20):
                    dst.write(chunk)
        # No comment: the source's comment holds its whole-file signature,
        # which no longer matches.

    new_crc = crc_of(new_file)
    with zipfile.ZipFile(src_path) as a, zipfile.ZipFile(out_path) as b:
        ia, ib = a.infolist(), b.infolist()
        if [i.filename for i in ia] != [i.filename for i in ib]:
            sys.exit("entry list differs from the source")
        for x, y in zip(ia, ib):
            want = new_crc if x.filename == member else x.CRC
            if y.CRC != want or (x.filename != member and y.file_size != x.file_size):
                sys.exit(f"{x.filename}: content differs from what was written")
        print(f"verified {len(ib)} entries; only {member} replaced")

def run(args, data=None):
    return subprocess.run(args, input=data, check=True, capture_output=True).stdout

def verify_signed(unsigned_path, signed_path, cert, work_dir):
    """Check that signing changed nothing but otacert, then verify the
    whole-file signature the way recovery does: a CMS signature in the ZIP
    comment over everything before the comment-length field."""
    cert_bytes = open(cert, "rb").read()
    with zipfile.ZipFile(unsigned_path) as a, zipfile.ZipFile(signed_path) as b:
        ia, ib = a.infolist(), b.infolist()
        if [i.filename for i in ia] != [i.filename for i in ib]:
            sys.exit("signing changed the entry list")
        for x, y in zip(ia, ib):
            if x.filename == OTACERT:
                if b.read(y) != cert_bytes:
                    sys.exit(f"{OTACERT} is not the signing certificate")
            elif (x.CRC, x.file_size) != (y.CRC, y.file_size):
                sys.exit(f"signing changed {x.filename}")

    size = os.path.getsize(signed_path)
    with open(signed_path, "rb") as f:
        f.seek(size - 6)
        sig_start, magic, comment_size = struct.unpack("<HHH", f.read(6))
        if magic != 0xFFFF or sig_start > comment_size:
            sys.exit("no whole-file signature in the ZIP comment")
        f.seek(size - comment_size - 22)
        eocd = f.read(22 + comment_size)
    if eocd[:4] != b"PK\x05\x06" or struct.unpack_from("<H", eocd, 20)[0] != comment_size:
        sys.exit("the ZIP comment is not where the signature footer says")
    sig_file = os.path.join(work_dir, "signature.der")
    with open(sig_file, "wb") as f:
        f.write(eocd[22 + comment_size - sig_start:22 + comment_size - 6])

    signed_len = size - comment_size - 2
    p = subprocess.Popen(["openssl", "cms", "-verify", "-binary", "-inform", "DER",
                          "-in", sig_file, "-content", "/dev/stdin", "-noverify",
                          "-out", "/dev/null"],
                         stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    with open(signed_path, "rb") as f:
        left = signed_len
        while left:
            chunk = f.read(min(left, 1 << 20))
            p.stdin.write(chunk)
            left -= len(chunk)
    p.stdin.close()
    err = p.stderr.read()
    if p.wait() != 0:
        sys.exit("signature does not verify: " + err.decode(errors="replace"))

    signer = run(["openssl", "pkcs7", "-inform", "DER", "-in", sig_file, "-print_certs"])
    fingerprint = ["openssl", "x509", "-noout", "-fingerprint", "-sha256"]
    if run(fingerprint, signer) != run(fingerprint + ["-in", cert]):
        sys.exit("the ZIP is signed by an unexpected certificate")
    os.remove(sig_file)
    print(f"signature verified ({signed_len} bytes signed by {os.path.basename(cert)})")

cmd, *args = sys.argv[1:]
if cmd == "device":
    print(read_device(*args))
elif cmd == "extract":
    extract(*args)
elif cmd == "rebuild":
    rebuild(*args)
elif cmd == "verify-signed":
    verify_signed(*args)
PYEOF
}

input=""
output=""
build_args=()
as_is=0
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output|--ksu-ref)
            [ $# -ge 2 ] || die "$1 needs a value"
            case "$1" in
                -o|--output) output="$2" ;;
                --ksu-ref) build_args+=(--ksu-ref "$2") ;;
            esac
            shift
            ;;
        --clean) build_args+=(--clean) ;;
        --as-is) as_is=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; die "unknown option: $1" ;;
        *)
            [ -z "$input" ] || die "only one input ZIP can be given"
            input="$1"
            ;;
    esac
    shift
done

[ -n "$input" ] || { usage >&2; die "no input ZIP given"; }
[ -f "$input" ] || die "$input not found"
if [ "$as_is" -eq 1 ]; then
    build_script="$BUILD_KERNEL" suffix=custom
    for arg in "${build_args[@]}"; do
        [ "$arg" != --ksu-ref ] || die "--ksu-ref does not apply with --as-is; pass it to apply_ksu.sh"
    done
else
    build_script="$BUILD_ALL" suffix=ksu
fi
[ -x "$build_script" ] || die "$build_script not found; keep the scripts together in one directory"
missing=()
for entry in python3:python3 signapk:signapk openssl:openssl; do
    command -v "${entry%%:*}" >/dev/null 2>&1 || missing+=("${entry##*:}")
done
[ ${#missing[@]} -eq 0 ] ||
    die "missing tools; install them from the Debian repositories with:
    sudo apt install ${missing[*]}"
for key in "$OTA_CERT" "$OTA_KEY"; do
    [ -f "$key" ] || die "$key is missing
    It is AOSP's test key, target/product/security/$(basename "$key") in
    https://android.googlesource.com/platform/build (see test-keys/README)."
done

input="$(cd "$(dirname "$input")" && pwd)/$(basename "$input")"
if [ -z "$output" ]; then
    name="$(basename "$input" .zip)"
    output="$DIST_DIR/${name%-sign}-$suffix.zip"
fi
case "$output" in /*) ;; *) output="$ROOT_DIR/$output" ;; esac
[ "$output" != "$input" ] || die "the output would overwrite the input"

log "Reading $(basename "$input")"
device="$(zip_tool device "$input")"
case "$device" in
    a52q|a72q) echo "device: $device" ;;
    "") die "no device= line in the ZIP's build_info.txt; is this a UN1CA ROM ZIP?" ;;
    *) die "the ZIP is for '$device'; this kernel supports a52q and a72q" ;;
esac

# Room for the unsigned and the signed copy, plus a little for boot.img.
mkdir -p "$(dirname "$output")" "$WORK_DIR"
need_kb=$(( 2 * $(stat -c %s "$input") / 1024 + 512 * 1024 ))
free_kb="$(df -Pk "$(dirname "$output")" | awk 'NR == 2 { print $4 }')"
[ "$free_kb" -ge "$need_kb" ] ||
    die "not enough space for $output: need $((need_kb / 1024)) MiB, have $((free_kb / 1024)) MiB"

stock_boot="$WORK_DIR/boot-$device.img"
zip_tool extract "$input" boot.img "$stock_boot"
echo "extracted boot.img"

"$build_script" --device "$device" --ramdisk extract \
    --boot-img "$device=$stock_boot" "${build_args[@]}"

log "Writing $(basename "$output")"
unsigned="$output.unsigned.partial"
signed="$output.partial"
trap 'rm -f "$unsigned" "$signed"' EXIT
zip_tool rebuild "$input" boot.img "$DIST_DIR/$device/boot.img" "$unsigned"

log "Signing with the AOSP test key"
signapk -w "$OTA_CERT" "$OTA_KEY" "$unsigned" "$signed"
zip_tool verify-signed "$unsigned" "$signed" "$OTA_CERT" "$WORK_DIR"
mv -f "$signed" "$output"
rm -f "$unsigned" "$stock_boot"
trap - EXIT

log "Done"
echo "$output"
echo "kernel: $(cat "$DIST_DIR/$device/kernel.release")"
echo "Signed with the AOSP test key (not UN1CA's)."
