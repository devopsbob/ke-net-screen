#!/bin/bash
# Rewrite the SBOM record for unbound when the image ships a source-built
# binary.  syft derives the unbound entry from the dpkg DB, which still holds
# the distro package version, so vulnerability scanners consuming the SBOM
# would assess the wrong resolver.  For every SPDX package entry named
# "unbound" this sets:
#   versionInfo       -> the source tree's configure version
#   downloadLocation  -> git+<origin-url>@<commit>   (SPDX VCS reference)
#   sourceInfo        -> provenance note incl. git describe and the dpkg
#                        record it supersedes
#   externalRefs      -> CPE version field updated; deb purl replaced with a
#                        pkg:github purl pinned to the built commit
# and then refreshes the SBOM file's size/sha1 entry in deployed.json so the
# deploy inventory still verifies.
#
# Usage:
#   scripts/patch-sbom-source-unbound.sh <OUTDIR>
#
# Exits 0 when no SBOM exists (SBOM generation disabled); fails when an SBOM
# exists but carries no unbound entry to patch.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_SRC="$PROJECT_ROOT/vendors/unbound"

OUTDIR="${1:?usage: scripts/patch-sbom-source-unbound.sh <OUTDIR>}"

for cmd in zstd python3 git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd is required by patch-sbom-source-unbound.sh" >&2
    exit 1
  fi
done

UNBOUND_VER="$("$VENDOR_SRC/configure" --version 2>/dev/null | awk 'NR==1{print $NF}')"
UNBOUND_COMMIT="$(git -C "$VENDOR_SRC" rev-parse HEAD)"
UNBOUND_DESCRIBE="$(git -C "$VENDOR_SRC" describe --tags --always 2>/dev/null || echo "$UNBOUND_COMMIT")"
UNBOUND_URL="$(git -C "$VENDOR_SRC" config --get remote.origin.url 2>/dev/null || echo "https://github.com/NLnetLabs/unbound.git")"

if [[ -z "$UNBOUND_VER" || -z "$UNBOUND_COMMIT" ]]; then
  echo "ERROR: could not determine unbound source version/commit from $VENDOR_SRC" >&2
  exit 1
fi

shopt -s nullglob
sboms=("$OUTDIR"/deploy-*/*.sbom.zst)
shopt -u nullglob

if [[ ${#sboms[@]} -eq 0 ]]; then
  echo "[sbom-patch] No SBOM under $OUTDIR/deploy-*/ (SBOM disabled?); nothing to do."
  exit 0
fi

for sbom in "${sboms[@]}"; do
  echo "[sbom-patch] Rewriting unbound entry in $(basename "$sbom"): -> $UNBOUND_VER ($UNBOUND_DESCRIBE)"
  tmp_json="$(mktemp)"
  trap 'rm -f "$tmp_json"' EXIT

  zstd -dcq "$sbom" > "$tmp_json"

  python3 - "$tmp_json" "$UNBOUND_VER" "$UNBOUND_COMMIT" "$UNBOUND_DESCRIBE" "$UNBOUND_URL" <<'PYEOF'
import json
import sys

path, ver, commit, describe, url = sys.argv[1:6]

with open(path) as f:
    doc = json.load(f)

patched = 0
for pkg in doc.get("packages", []):
    if pkg.get("name") != "unbound":
        continue
    old_ver = pkg.get("versionInfo", "unknown")
    pkg["versionInfo"] = ver
    pkg["downloadLocation"] = f"git+{url}@{commit}"
    pkg["sourceInfo"] = (
        "binary built from source by ke-net-screen --source-unbound: "
        f"git {describe} ({commit}); supersedes dpkg record {old_ver}"
    )
    for ref in pkg.get("externalRefs") or []:
        loc = ref.get("referenceLocator", "")
        if ref.get("referenceType") == "cpe23Type" and loc.startswith("cpe:2.3:"):
            parts = loc.split(":")
            if len(parts) > 5:
                parts[5] = ver
                ref["referenceLocator"] = ":".join(parts)
        elif ref.get("referenceType") == "purl":
            ref["referenceLocator"] = f"pkg:github/nlnetlabs/unbound@{commit}"
    patched += 1

if patched == 0:
    print("ERROR: SBOM has no package entry named 'unbound'", file=sys.stderr)
    sys.exit(3)

creators = doc.setdefault("creationInfo", {}).setdefault("creators", [])
tool_id = "Tool: ke-net-screen-patch-sbom-source-unbound"
if tool_id not in creators:
    creators.append(tool_id)

with open(path, "w") as f:
    json.dump(doc, f, separators=(",", ":"))

print(f"[sbom-patch] patched {patched} SBOM package entr{'y' if patched == 1 else 'ies'}")
PYEOF

  zstd -q -f "$tmp_json" -o "$sbom"
  rm -f "$tmp_json"
  trap - EXIT

  # Keep the deploy inventory consistent with the rewritten file.
  deployed_json="$(dirname "$sbom")/deployed.json"
  if [[ -f "$deployed_json" ]]; then
    python3 - "$deployed_json" "$sbom" <<'PYEOF'
import hashlib
import json
import os
import sys

dep_path, sbom_path = sys.argv[1:3]
name = os.path.basename(sbom_path)

with open(dep_path) as f:
    doc = json.load(f)

sha1 = hashlib.sha1()
with open(sbom_path, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        sha1.update(chunk)

updated = False
for entry in doc.get("files", []):
    if entry.get("name") == name:
        entry["size"] = os.path.getsize(sbom_path)
        entry["sha1"] = sha1.hexdigest()
        updated = True

with open(dep_path, "w") as f:
    json.dump(doc, f, indent=4)
    f.write("\n")

state = "updated" if updated else "has no entry (left unchanged)"
print(f"[sbom-patch] deployed.json {state} for {name}")
PYEOF
  fi
done
