#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Full cross-language golden CI for the standalone potok-m-protocol repository.
#
# The four committed golden frames are pinned here once. The committed C
# harness (stm32/tests/golden_harness.c, built on generated/protocol.h), the
# generated Python codec and the Rust library are each evaluated from their own
# source and compared against those bytes, so a silent divergence in any one
# language fails the check. The C harness is committed, not written to a temp
# directory at CI time.
#
# Modes (default: all): all | self-test | license | yaml | c | python | rust
set -euo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$SELF_DIR/../.." && pwd)
WORKFLOW="$ROOT/.github/workflows/cross-language.yml"
HARNESS="$SELF_DIR/golden_harness.c"

GOLD_REQ="4d5034127bf1536502011200cdcccc3dcdcc4cbe33335340c3f51c41000000000000c0bf00004841000050c0000030420080f742bffec67f"
GOLD_REP="505234127d0006ffc8010100c549"
GOLD_LOWREQ="544c34127bf15365020112000100feff03000400fbff06000700f8ff09000a000b00f4ff0d000e000a2b"
GOLD_LOWREP="524c34127d0006ffc801012a0000fd1b"

fail=0

bad() {
    printf 'FAIL %s\n' "$*" >&2
    fail=$((fail + 1))
}

expect_hex() {
    local label=$1 got=$2 want=$3
    if [ "$got" = "$want" ]; then
        printf 'ok   %s\n' "$label"
        return 0
    fi
    printf 'FAIL %s\n  got  %s\n  want %s\n' "$label" "$got" "$want" >&2
    fail=$((fail + 1))
    return 1
}

self_test() {
    if ! bash -n "$SELF_DIR/check_golden.sh"; then
        bad "self-test: shell syntax invalid"
    fi
    local name length hexval
    for spec in "REQ:56:$GOLD_REQ" "REP:14:$GOLD_REP" \
                "LOWREQ:42:$GOLD_LOWREQ" "LOWREP:16:$GOLD_LOWREP"; do
        name=${spec%%:*}
        length=${spec#*:}; length=${length%%:*}
        hexval=${spec#*:}; hexval=${hexval#*:}
        if [ "${#hexval}" -ne "$((length * 2))" ]; then
            bad "self-test: $name fixture has wrong byte length"
            continue
        fi
        if [[ ! $hexval =~ ^[0-9a-f]+$ ]]; then
            bad "self-test: $name fixture is not lowercase hex"
            continue
        fi
        printf 'ok   self-test %s fixture (%d bytes)\n' "$name" "$length"
    done
    local corrupt="${GOLD_REQ:0:${#GOLD_REQ}-2}00"
    if [ "$corrupt" = "$GOLD_REQ" ]; then
        corrupt="${GOLD_REQ:0:${#GOLD_REQ}-2}ff"
    fi
    if (expect_hex "self-test corruption" "$corrupt" "$GOLD_REQ" >/dev/null 2>&1); then
        bad "self-test: comparator accepted a corrupted frame"
    else
        printf 'ok   self-test detects a golden mismatch\n'
    fi
}

license() {
    local file line spdx='SPDX-License''-Identifier'
    for file in "$SELF_DIR/check_golden.sh" "$HARNESS" "$WORKFLOW"; do
        if [ ! -f "$file" ]; then
            bad "missing file: $file"
            continue
        fi
        if ! head -n 3 "$file" | grep -Fq 'SPDX-License-Identifier: GPL-3.0-or-later'; then
            bad "missing GPL SPDX header: $file"
        fi
        while IFS= read -r line; do
            case "$line" in
                *"SPDX-License-Identifier: GPL-3.0-or-later"*) ;;
                *) bad "foreign license declaration in $file: $line" ;;
            esac
        done < <(grep -F "$spdx" "$file" || true)
        if grep -Eq '^[[:space:]]*(//|#|/\*)[[:space:]]*Copied from' "$file"; then
            bad "imported code marker in $file"
        fi
    done
    if [ "$fail" -eq 0 ]; then
        printf 'ok   GPL headers, no foreign code\n'
    fi
}

yaml() {
    local file
    if ! python3 -c 'import yaml' >/dev/null 2>&1; then
        if ! python3 -m pip install --quiet pyyaml; then
            bad "cannot load a YAML parser"
            return 0
        fi
    fi
    for file in "$ROOT"/.github/workflows/*.yml; do
        if [ ! -f "$file" ]; then
            bad "no workflow files found"
            continue
        fi
        if ! python3 - "$file" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), dict):
    sys.exit("workflow must be a mapping with a jobs mapping")
PY
        then
            bad "invalid workflow YAML: $file"
        else
            printf 'ok   YAML parses: %s\n' "${file#"$ROOT"/}"
        fi
    done
}

check_c() {
    if [ ! -f "$HARNESS" ]; then
        bad "missing committed C harness: $HARNESS"
        return 0
    fi
    local dir bin out
    dir=$(mktemp -d)
    bin="$dir/golden_harness"
    if ! cc -std=c11 -Wall -Wextra -Werror "$HARNESS" -o "$bin"; then
        bad "C harness failed to build with -Wall -Wextra -Werror"
        rm -rf -- "$dir"
        return 0
    fi
    if ! out=$("$bin"); then
        bad "C harness exited non-zero"
        rm -rf -- "$dir"
        return 0
    fi
    rm -rf -- "$dir"
    case "$out" in
        *"C golden: OK"*) printf 'ok   C golden harness (generated/protocol.h)\n' ;;
        *) bad "C harness did not report success: $out" ;;
    esac
}

check_python() {
    local gen="$ROOT/generated"
    if [ ! -f "$gen/protocol.py" ]; then
        bad "missing generated Python codec: $gen/protocol.py"
        return 0
    fi
    local out
    if ! out=$(PYTHONPATH="$gen" python3 - <<'PY'
import protocol as p

req = p.Request(
    seq=0x1234, time_us=1_700_000_123, phase=p.Phase.APOGEE,
    version=1, flags=0x12, reserved=0,
    gyro=[0.1, -0.2, 3.3], accel=[9.81, 0.0, -1.5],
    mag=[12.5, -3.25, 44.0], height=123.75, pitot_dp=-321,
)
rep = p.Reply(seq=0x1234, g_pitch=125, g_yaw=-250,
              confidence=200, ai_healthy=1, version=1)
lreq = p.LowlatRequest(
    seq=0x1234, time_us=1_700_000_123, phase=p.Phase.APOGEE,
    version=1, flags=0x12, reserved=0,
    features=[1, -2, 3, 4, -5, 6, 7, -8, 9, 10, 11, -12, 13, 14],
)
lrep = p.LowlatReply(
    seq=0x1234, g_pitch=125, g_yaw=-250, confidence=200,
    ai_healthy=1, version=1, compute_us=42, reserved=[0, 0],
)

for name, data in (
    ("REQ", p.encode_request(req)),
    ("REP", p.encode_reply(rep)),
    ("LOWREQ", p.encode_lowlat_request(lreq)),
    ("LOWREP", p.encode_lowlat_reply(lrep)),
):
    print(f"{name}={data.hex()}")
PY
    ); then
        bad "Python golden harness failed"
        return 0
    fi
    local py_req="" py_rep="" py_lowreq="" py_lowrep="" key value
    while IFS='=' read -r key value; do
        case "$key" in
            REQ) py_req=$value ;;
            REP) py_rep=$value ;;
            LOWREQ) py_lowreq=$value ;;
            LOWREP) py_lowrep=$value ;;
        esac
    done <<< "$out"
    expect_hex "Python request golden bytes" "$py_req" "$GOLD_REQ" || true
    expect_hex "Python reply golden bytes" "$py_rep" "$GOLD_REP" || true
    expect_hex "Python lowlat request golden bytes" "$py_lowreq" "$GOLD_LOWREQ" || true
    expect_hex "Python lowlat reply golden bytes" "$py_lowrep" "$GOLD_LOWREP" || true
}

check_rust() {
    if [ ! -f "$ROOT/Cargo.toml" ]; then
        bad "missing protocol workspace: $ROOT/Cargo.toml"
        return 0
    fi
    local spec target test
    for spec in \
        "protocol_tests:golden_wire_bytes_match_c_and_python" \
        "protocol_tests:committed_golden_fixtures_reencode_byte_identical" \
        "lowlat_tests:lowlat_golden_bytes_match_c_and_python"; do
        target=${spec%%:*}
        test=${spec#*:}
        if (cd "$ROOT" && cargo test -q -p potok-protocol --test "$target" -- --exact "$test"); then
            printf 'ok   Rust golden test %s\n' "$test"
        else
            bad "Rust golden test failed: $test"
        fi
    done
}

mode=${1:-all}
case "$mode" in
    all)
        self_test
        license
        yaml
        check_c
        check_python
        check_rust
        ;;
    self-test) self_test ;;
    license) license ;;
    yaml) yaml ;;
    c) check_c ;;
    python) check_python ;;
    rust) check_rust ;;
    *)
        printf 'usage: %s [all|self-test|license|yaml|c|python|rust]\n' "$0" >&2
        exit 2
        ;;
esac

printf 'check_golden %s: ' "$mode"
if [ "$fail" -eq 0 ]; then
    printf 'OK\n'
else
    printf 'FAILED (%d)\n' "$fail"
fi
exit "$fail"
