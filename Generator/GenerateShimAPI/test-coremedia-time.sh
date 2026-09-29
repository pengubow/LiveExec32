#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/LiveExec32-CoreMediaTime.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

if [ "${SKIP_GENERATOR_BUILD:-0}" != 1 ]; then
    "$SCRIPT_DIR/build.sh"
fi
if ! "$SCRIPT_DIR/GenerateShimObjC" \
        "$SCRIPT_DIR/Tests/coremedia-time.plist" "$TEMP_ROOT/generated" \
        >"$TEMP_ROOT/generate.log" 2>&1; then
    cat "$TEMP_ROOT/generate.log" >&2
    exit 1
fi

python3 - "$TEMP_ROOT/generated" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])


def method(class_name, selector):
    path = next(root.glob(f"*/{class_name}.m"))
    pattern = r"(?m)^(#if 0 // FIXME: has unhandled types\n)?- ([^\n]+) \{\n(.*?)^\}"
    for match in re.finditer(pattern, path.read_text(), re.S | re.M):
        guard, declaration, body = match.groups()
        components = re.findall(r"([A-Za-z][A-Za-z0-9_]*:)", declaration)
        candidate = "".join(components) if components else declaration.split(")", 1)[1]
        if candidate == selector:
            return bool(guard), declaration, body
    raise AssertionError(f"Missing method: {class_name} {selector}")


def enabled(class_name, selector):
    disabled, declaration, body = method(class_name, selector)
    assert not disabled, (class_name, selector)
    assert "unhandled type" not in body, (class_name, selector)
    assert "anonymous struct" not in declaration, declaration
    return declaration, body


for selector in ("startSessionAtSourceTime:", "setMovieFragmentInterval:"):
    declaration, body = enabled("AVAssetWriter", selector)
    assert "(CMTime)guest_arg0" in declaration
    assert "CMTime host_arg0 = guest_arg0;" in body
    assert "LC32HostAggregateArgument(&host_arg0)" in body

declaration, body = enabled("AVAssetWriter", "movieFragmentInterval")
assert declaration.startswith("(CMTime)")
assert "CMTime host_ret = {0};" in body
assert "@selector(movieFragmentInterval), 1)" in body
assert "&host_ret, sizeof(host_ret)" in body
assert "return host_ret;" in body

declaration, body = enabled("AVAssetWriterInputPixelBufferAdaptor",
                            "appendPixelBuffer:withPresentationTime:")
assert "(CMTime)guest_arg1" in declaration
assert "uint64_t host_arg0 = [(__bridge id)guest_arg0 host_self];" in body
assert "CMTime host_arg1 = guest_arg1;" in body
assert "host_arg0, LC32HostAggregateArgument(&host_arg1)" in body
assert "return (char)host_ret;" in body

for selector in ("unknownStruct:", "prefixOnly:", "pointerToTime:"):
    disabled, declaration, body = method("LC32UnknownTimeFixture", selector)
    assert disabled, (selector, declaration)

print("GenerateShimAPI CMTime: arguments, returns, opaque pixel buffers, and unsupported encodings PASS")
PY
