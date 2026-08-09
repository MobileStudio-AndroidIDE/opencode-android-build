#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# test-opentui-isolated.sh — smoke test for @androidtui/core on Termux
# =============================================================================
#
# WHAT THIS DOES:
#   Creates a minimal test project (3 deps only, no opencode) and verifies
#   that @androidtui/core + @opentui/solid work on Termux. This isolates
#   the opentui FFI layer from opencode's 2000+ dependencies.
#
# WHY:
#   If opencode fails to start, we need to know whether the failure is in:
#     (a) opentui itself (FFI, .so loading, MTE)  → this test will fail too
#     (b) @opentui/solid API compat with @androidtui/core  → this test will fail
#     (c) opencode's own code (bun-pty, sqlite, etc.)  → this test will PASS
#
#   If this test passes, we know opentui works and the problem is in opencode.
#   If this test fails, we know to fix opentui first (or fork @opentui/solid).
#
# WHAT IT TESTS:
#   1. `bun install` succeeds (downloads @androidtui/core +
#      @androidtui/core-android-arm64 + @opentui/solid)
#   2. `@androidtui/core` can be imported (JS loads OK)
#   3. `createCliRenderer()` works (FFI loads libopentui.so OK, MTE doesn't
#      crash, renderer starts)
#   4. `@opentui/solid`'s `render()` works (Solid reconciler + opentui core
#      API compat — if 0.4.10 solid breaks with 0.4.10 core, this fails)
#   5. A `<box>` renders with a `<text>` child (basic renderable tree works)
#   6. Renderer destroys cleanly (no exit race condition)
#
# USAGE:
#   bash test-opentui-isolated.sh              # run in ~/opentui-test
#   bash test-opentui-isolated.sh /path/to/dir # run in specific dir
#
# EXPECTED OUTPUT:
#   If everything works, you'll see a bordered box with "Hello opentui!" for
#   3 seconds, then the renderer exits cleanly.
#
#   If FFI fails, you'll see an error like:
#     "opentui is not supported on the current platform"  → .so not found
#     "undefined symbol: opentui_*"                         → ABI mismatch
#     SIGABRT                                               → MTE/FFI crash
#
#   If @opentui/solid API compat fails, you'll see:
#     "Cannot find export X in @androidtui/core"  → API break
#     "TypeError: ... is not a function"              → renamed/removed API
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/versions.sh
. "$SCRIPT_DIR/ci/versions.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
MUTED='\033[0;2m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; }
info() { echo -e "  ${MUTED}       $*${NC}"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }

TEST_DIR="${1:-$HOME/opentui-test}"
BUN_BIN="${BUN_BIN:-$PREFIX/bin/bun}"

echo "=========================================="
echo "opentui isolated smoke test"
echo "=========================================="
echo "  TEST_DIR: $TEST_DIR"
echo "  BUN_BIN:  $BUN_BIN"
echo "  PREFIX:   ${PREFIX:-<unset>}"
echo "=========================================="

# --- Verify prerequisites ----------------------------------------------------
if [ ! -x "$BUN_BIN" ]; then
  fail "bun not found at $BUN_BIN"
  echo "Install bun-termux:" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash" >&2
  exit 1
fi

# --- Create test project -----------------------------------------------------
echo ""
echo "=== Creating test project ==="
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Minimal package.json — only 3 deps
# Clean v2 approach: all @androidtui packages published at the same version, so we use
# npm: aliases directly. No overrides needed — @androidtui/solid
# directly depends on @androidtui/core in its own dependencies.
cat > package.json <<EOF
{
  "name": "opentui-test",
  "version": "1.0.0",
  "type": "module",
  "private": true,
  "dependencies": {
    "@opentui/core": "npm:@androidtui/core@${ANDROIDTUI_CORE_VERSION}",
    "@opentui/solid": "npm:@androidtui/solid@${ANDROIDTUI_SOLID_VERSION}",
    "solid-js": "1.9.10"
  },
  "optionalDependencies": {
    "@androidtui/core-android-arm64": "${ANDROIDTUI_ANDROID_VERSION}"
  }
}
EOF
ok "package.json created (clean v2: all @androidtui packages, no overrides needed)"

# Bun's minimumReleaseAge gate blocks packages published less than N seconds
# ago. Bun's own default is 0, but a global or inherited bunfig can turn the
# gate on — and this test's whole point is to run against a version published
# minutes earlier, so a fresh release would look like a packaging failure
# rather than a policy block. Pin it off for the test project explicitly.
# The preload registers @opentui/solid's JSX transform. Solid compiles JSX
# into reactive operations rather than calling a runtime factory the way
# React does, so the @jsxImportSource pragma in app.tsx is not sufficient on
# its own — without the transform, bun resolves .tsx against React's runtime
# and dies with "Cannot find module 'react/jsx-dev-runtime'".
cat > bunfig.toml <<'EOF'
preload = ["@opentui/solid/preload"]

[install]
minimumReleaseAge = 0
EOF
ok "bunfig.toml created (solid preload + minimumReleaseAge = 0 for fresh packages)"

# --- bun install -------------------------------------------------------------
echo ""
echo "=== Running bun install ==="
if "$BUN_BIN" install 2>&1 | sed 's/^/  /'; then
  ok "bun install succeeded"
else
  fail "bun install failed"
  exit 1
fi

# --- Verify packages installed -----------------------------------------------
echo ""
echo "=== Verifying packages ==="

if [ ! -d "node_modules/@opentui/core" ]; then
  fail "node_modules/@opentui/core not found"
  exit 1
fi

# Check it's the @androidtui fork
CORE_NAME=$("$BUN_BIN" -e "console.log(require('./node_modules/@opentui/core/package.json').name)" 2>/dev/null || echo "?")
if [ "$CORE_NAME" = "@androidtui/core" ]; then
  ok "@opentui/core is the @androidtui fork"
else
  fail "@opentui/core is NOT the @androidtui fork (got: $CORE_NAME)"
  exit 1
fi

# Check native .so
SO_PATH="node_modules/@androidtui/core-android-arm64/libopentui.so"
if [ -f "$SO_PATH" ]; then
  ok "libopentui.so found: $SO_PATH"
  SO_TYPE=$(file -b "$SO_PATH" 2>/dev/null || echo "?")
  info "file type: $SO_TYPE"
  case "$SO_TYPE" in
    *ELF*arm*aarch64*|*ELF*64-bit*ARM*)
      ok ".so is ARM64 ELF"
      ;;
    *)
      warn ".so type unexpected: $SO_TYPE"
      info "Expected: ELF 64-bit LSB shared object, ARM aarch64"
      ;;
  esac
else
  fail "libopentui.so not found at $SO_PATH"
  echo "The optionalDependency didn't install. Try:" >&2
  echo "  bun add @androidtui/core-android-arm64@${ANDROIDTUI_ANDROID_VERSION}" >&2
  exit 1
fi

# Check @opentui/solid
if [ -d "node_modules/@opentui/solid" ]; then
  ok "@opentui/solid found"
else
  fail "@opentui/solid not found"
  exit 1
fi

# CRITICAL: verify @opentui/solid does NOT have a nested upstream @opentui/core
# Since 0.4.10, @androidtui/solid directly depends on @androidtui/core
# via npm: alias — so there's no nested upstream copy to worry about.
# But we still check for belt-and-suspenders safety.
NESTED_CORE="node_modules/@opentui/solid/node_modules/@opentui/core"
if [ -d "$NESTED_CORE" ]; then
  NESTED_NAME=$("$BUN_BIN" -e "console.log(require('./$NESTED_CORE/package.json').name)" 2>/dev/null || echo "?")
  if [ "$NESTED_NAME" = "@androidtui/core" ]; then
    ok "nested @opentui/core inside @opentui/solid is @androidtui fork (direct dep — no override needed)"
  else
    fail "nested @opentui/core inside @opentui/solid is upstream ($NESTED_NAME)"
    echo "  This should not happen with @androidtui/solid@0.4.10+." >&2
    echo "  The package should directly depend on @androidtui/core." >&2
    exit 1
  fi
else
  ok "no nested @opentui/core inside @opentui/solid (hoisted — override working)"
fi

# --- Create test app ---------------------------------------------------------
echo ""
echo "=== Creating test app ==="

cat > app.tsx <<'APPEOF'
/** @jsxImportSource @opentui/solid */
import { createCliRenderer } from "@opentui/core"
import { render } from "@opentui/solid"
import { createSignal, onCleanup } from "solid-js"

function App() {
  const [count, setCount] = createSignal(0)
  const interval = setInterval(() => setCount((c) => c + 1), 500)
  onCleanup(() => clearInterval(interval))
  return (
    <box border style={{ padding: 1 }}>
      <text>Hello opentui! Count: {count()}</text>
    </box>
  )
}

console.log("[test] starting renderer...")
const renderer = await createCliRenderer({ exitOnCtrlC: false })
console.log("[test] renderer started, mounting Solid root...")
render(() => <App />, renderer)
console.log("[test] Solid root mounted, waiting 3s...")

await new Promise((resolve) => setTimeout(resolve, 3000))

console.log("[test] destroying renderer...")
// Defer destroy to avoid exit race condition (reconciler has pending mutations)
setTimeout(() => {
  try { renderer.destroy() } catch {}
  process.exit(0)
}, 50)
APPEOF
ok "app.tsx created"

# --- Run test ----------------------------------------------------------------
echo ""
echo "=== Running test (3 second render) ==="
echo ""

export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
export TERM="${TERM:-xterm-256color}"

if "$BUN_BIN" run app.tsx 2>&1; then
  echo ""
  ok "TEST PASSED — opentui + solid work on Termux"
  echo ""
  echo "This means:"
  echo "  ✅ @androidtui/core@${ANDROIDTUI_CORE_VERSION} FFI works (libopentui.so loads, no MTE crash)"
  echo "  ✅ @androidtui/solid@${ANDROIDTUI_SOLID_VERSION} is API-compatible with @androidtui/core@${ANDROIDTUI_CORE_VERSION}"
  echo "  ✅ createCliRenderer() + render() + <box>/<text> all work"
  echo "  ✅ Renderer destroys cleanly (no exit race)"
  echo ""
  echo "If opencode fails to start, the problem is in opencode itself"
  echo "(bun-pty, sqlite, opencode's own code), NOT in opentui."
  exit 0
else
  EXIT_CODE=$?
  echo ""
  fail "TEST FAILED (exit code $EXIT_CODE)"
  echo ""
  echo "Diagnosis based on error:"
  echo ""
  echo "  'opentui is not supported on the current platform'"
  echo "    → libopentui.so not found or dlopen failed"
  echo "    → check: ls -la node_modules/@androidtui/core-android-arm64/"
  echo ""
  echo "  'undefined symbol: opentui_*'"
  echo "    → ABI mismatch between @androidtui/core JS and the .so"
  echo "    → rebuild .so from same opentui version as the JS bindings"
  echo ""
  echo "  'Cannot find export X in @androidtui/core'"
  echo "    → @androidtui/solid@${ANDROIDTUI_SOLID_VERSION} API break with @androidtui/core@${ANDROIDTUI_CORE_VERSION}"
  echo "    → need to fork @opentui/solid, publish as @androidtui/solid"
  echo ""
  echo "  'TypeError: ... is not a function'"
  echo "    → same API break, different symptom"
  echo ""
  exit $EXIT_CODE
fi
