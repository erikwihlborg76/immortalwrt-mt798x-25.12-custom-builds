#!/bin/sh
# Run the patched converter with a native ucode interpreter and isolated modules.
set -eu

[ "$#" -eq 2 ] || { echo "Usage: $0 OPENWRT_SOURCE UCODE_BINARY" >&2; exit 1; }
repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source_dir="$(CDPATH= cd -- "$1" && pwd)"
ucode_bin="$2"
converter="$source_dir/package/mtk/applications/mtwifi-cfg-ucode/files/usr/share/ucode/mtwifi/converter.uc"
definitions="$source_dir/package/mtk/applications/mtwifi-cfg-ucode/files/usr/share/schema/mtwifi/dat-defs.json"
[ -f "$converter" ] && [ -f "$definitions" ] || { echo 'Patched converter/schema not found' >&2; exit 1; }
[ -x "$ucode_bin" ] || { echo "Native ucode interpreter not executable: $ucode_bin" >&2; exit 1; }

mkdir -p "$repo_dir/logs/converter"
test_root="$(mktemp -d "$repo_dir/logs/converter/test.XXXXXX")"
mkdir -p "$test_root/modules/mtwifi"
cp "$converter" "$test_root/modules/mtwifi/converter.uc"
cp "$definitions" "$test_root/definitions.json"
# The real converter runs unchanged. Only its schema path and datconf dependency
# are isolated; these tests cover emitted fields, not native DAT file I/O.
cat > "$test_root/modules/mtwifi/defaults.uc" <<'UCODE'
import { readfile } from 'fs';
export const defs = json(readfile(TEST_DEFINITIONS));
UCODE
cat > "$test_root/modules/datconf.uc" <<'UCODE'
export function set_indexed_value(value, index, item) {
    let values = split(value || "", ";");
    while (length(values) <= index)
        push(values, "");
    values[index] = "" + item;
    return join(";", values);
}
UCODE

"$ucode_bin" -L "$test_root/modules" -D "TEST_DEFINITIONS=$test_root/definitions.json" "$repo_dir/tools/test-mtwifi-converter.uc"
printf 'Converter fixtures: %s\n' "$test_root"
