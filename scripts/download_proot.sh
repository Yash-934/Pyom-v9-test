#!/bin/bash
# =============================================================
# download_proot.sh
# Downloads proot static binaries and places them in assets/bin/
# Run this BEFORE flutter build apk
# =============================================================

set -e

ASSETS_BIN="$(dirname "$0")/../assets/bin"
mkdir -p "$ASSETS_BIN"

# ── Fetch latest proot release tag from GitHub API ─────────────────
echo "🔍 Fetching latest proot release info..."
LATEST_JSON=$(curl -s --max-time 15 "https://api.github.com/repos/proot-me/proot/releases/latest" 2>/dev/null || echo "")

if [ -n "$LATEST_JSON" ]; then
    TAG=$(echo "$LATEST_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tag_name',''))" 2>/dev/null || echo "")
    echo "✅ Latest proot tag: $TAG"
    
    # Get download URLs from the release
    AARCH64_URL=$(echo "$LATEST_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('assets', []):
    name = a['name'].lower()
    if 'aarch64' in name or ('arm64' in name and 'proot' in name):
        print(a['browser_download_url'])
        break
" 2>/dev/null || echo "")

    X86_URL=$(echo "$LATEST_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('assets', []):
    name = a['name'].lower()
    if 'x86_64' in name and 'proot' in name:
        print(a['browser_download_url'])
        break
" 2>/dev/null || echo "")
fi

# ── Try to download aarch64 (ARM64 — most Android phones) ──────────
echo ""
echo "📥 Downloading proot for aarch64 (ARM64)..."
AARCH64_OK=false

TRY_URLS_AARCH64=(
    "$AARCH64_URL"
    "https://github.com/proot-me/proot/releases/download/v5.4.0/proot-aarch64"
    "https://github.com/proot-me/proot/releases/download/v5.3.0/proot-aarch64"
    "https://raw.githubusercontent.com/AndronixApp/AndronixOrigin/master/repo/aarch64/proot"
    "https://github.com/termux/proot-rs/releases/latest/download/proot-rs-aarch64-linux-android"
)

for URL in "${TRY_URLS_AARCH64[@]}"; do
    [ -z "$URL" ] && continue
    echo "  Trying: $URL"
    if curl -fsSL --max-time 60 -o "$ASSETS_BIN/proot-arm64" "$URL" 2>/dev/null; then
        SIZE=$(stat -c%s "$ASSETS_BIN/proot-arm64" 2>/dev/null || stat -f%z "$ASSETS_BIN/proot-arm64" 2>/dev/null || echo 0)
        if [ "$SIZE" -gt "10000" ]; then
            chmod +x "$ASSETS_BIN/proot-arm64"
            echo "  ✅ Downloaded! Size: $SIZE bytes"
            AARCH64_OK=true
            break
        else
            echo "  ❌ File too small ($SIZE bytes), trying next..."
            rm -f "$ASSETS_BIN/proot-arm64"
        fi
    fi
done

if [ "$AARCH64_OK" = false ]; then
    echo "❌ Could not download proot-arm64 from any source!"
    echo "   Manual fix: Download proot-aarch64 from https://github.com/proot-me/proot/releases"
    echo "   Place it as: assets/bin/proot-arm64"
    exit 1
fi

# ── Try to download x86_64 (emulators) ─────────────────────────────
echo ""
echo "📥 Downloading proot for x86_64 (optional — for emulator support)..."
TRY_URLS_X86=(
    "$X86_URL"
    "https://github.com/proot-me/proot/releases/download/v5.4.0/proot-x86_64"
    "https://github.com/proot-me/proot/releases/download/v5.3.0/proot-x86_64"
    "https://raw.githubusercontent.com/AndronixApp/AndronixOrigin/master/repo/x86_64/proot"
)

for URL in "${TRY_URLS_X86[@]}"; do
    [ -z "$URL" ] && continue
    if curl -fsSL --max-time 60 -o "$ASSETS_BIN/proot-x86_64" "$URL" 2>/dev/null; then
        SIZE=$(stat -c%s "$ASSETS_BIN/proot-x86_64" 2>/dev/null || stat -f%z "$ASSETS_BIN/proot-x86_64" 2>/dev/null || echo 0)
        if [ "$SIZE" -gt "10000" ]; then
            chmod +x "$ASSETS_BIN/proot-x86_64"
            echo "  ✅ Downloaded x86_64 too!"
            break
        else
            rm -f "$ASSETS_BIN/proot-x86_64"
        fi
    fi
done

echo ""
echo "========================================"
echo "✅ proot binaries ready in assets/bin/:"
ls -lh "$ASSETS_BIN/"
echo "========================================"
echo ""
echo "Now run:  flutter build apk --release"
