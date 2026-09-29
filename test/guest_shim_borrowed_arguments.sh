#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
SOURCE="$REPO_ROOT/GuestFrameworks/.generated/StoreKit/SKRequest.m"
OUTPUT_DIR=${LC32_BORROWED_ARGUMENT_TEST_OUTPUT:-"$REPO_ROOT/tmp/tests/guest-shim-borrowed-arguments"}
GUEST_SDK=${LC32_GUEST_SDK:-"$REPO_ROOT/tmp/iPhoneOS10.3.sdk"}

if [ "$(uname -s)" = Linux ]; then
    GUEST_CC="$THEOS/toolchain/linux/iphone/bin/clang"
else
    GUEST_CC=$(xcrun --find clang)
fi

if [ ! -f "$SOURCE" ]; then
    echo "Generated shims are missing; run make -C GuestMakefile generate-shims" >&2
    exit 1
fi
mkdir -p "$OUTPUT_DIR"

# Compile the real forwarding method. The control restores strong parameters
# so the same compiler must demonstrate the unwanted ownership operations.
sed 's/ __unsafe_unretained//g' "$SOURCE" > "$OUTPUT_DIR/SKRequest-strong-control.m"
for optimization in 0 2; do
    for mode in borrowed strong-control; do
        input="$SOURCE"
        if [ "$mode" = strong-control ]; then
            input="$OUTPUT_DIR/SKRequest-strong-control.m"
        fi
        "$GUEST_CC" -target armv7s-apple-ios10.3 -mthumb \
            -isysroot "$GUEST_SDK" -O"$optimization" \
            -fobjc-arc -fblocks -fmodules \
            -fmodules-cache-path="$OUTPUT_DIR/modules" \
            -Wno-nullability-completeness \
            -I"$REPO_ROOT/include" -I"$REPO_ROOT/GuestFrameworks" \
            -S -emit-llvm "$input" \
            -o "$OUTPUT_DIR/$mode-O$optimization.ll"
    done
done

python3 - "$OUTPUT_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
ownership = re.compile(r'@(?:llvm\.)?objc[._](?:retain\w*|release\w*|storeStrong)\(')


def delegate_body(path):
    source = path.read_text()
    match = re.search(
        r'^define[^\n]*@"(?:\\01)?-\[SKRequest setDelegate:\]"[^\n]*\{\n(.*?)^\}',
        source, re.M | re.S)
    if match is None:
        raise SystemExit(f'Missing SKRequest.setDelegate: implementation in {path}')
    return match.group(1)


for optimization in (0, 2):
    borrowed = delegate_body(root / f'borrowed-O{optimization}.ll')
    control = delegate_body(root / f'strong-control-O{optimization}.ll')
    if ownership.search(borrowed):
        raise SystemExit(f'Borrowed delegate acquired ARC ownership at -O{optimization}')
    if not ownership.search(control):
        raise SystemExit(f'Strong control did not exercise ARC ownership at -O{optimization}')
    if '@LC32InvokeHostSelector(' not in borrowed:
        raise SystemExit(f'Borrowed delegate stopped forwarding at -O{optimization}')
    print(f'ARMv7s ARC delegate forwarding -O{optimization}: PASS '
          '(no temporary guest ownership; strong control exercises ownership)')
PY
