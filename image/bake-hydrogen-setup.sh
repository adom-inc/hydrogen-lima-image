#!/usr/bin/env bash
# bake-hydrogen-setup.sh — pre-run Hydrogen's setup cascade at IMAGE BUILD time.
#
# Run as root inside the rootfs (chroot or docker RUN). Each section names
# the setup step it subsumes in
# adom-hydrogen/src-tauri/crates/hydrogen-app/src/setup_steps_macos.rs — keep
# the two in lockstep. With these baked, the runtime cascade reduces to the
# machine/user-specific steps only: ensure-workspace (machinectl import-tar),
# wait-codeserver, set-env-vars (live proxy port), inject-api-key,
# ensure-adom-bridge (host side), start-relay/test-* (relay), claude-auth,
# and welcome.
#
# NOTHING here may require GitHub authentication — this image is public and
# installs on machines with no GitHub identity. Sources used: the public Adom
# wiki, Open VSX, and claude.ai. The adom skills come from the adom-wiki-managed
# installs below (adom-wiki pkg install adom/hydrogen-mac-bootstrap et al. — adom-wiki
# is the official wiki CLI; adompkg is RETIRED and no longer ships in the image).

set -euo pipefail
log() { echo "[bake-hydrogen-setup] $*"; }
as_adom() { runuser -u adom -- bash -lc "$1"; }

WIKI_BASE="${WIKI_BASE:-https://wiki.adom.inc}"
CS=/usr/lib/code-server/bin/code-server

# ── step 15: claude CLI — a SHIM, not a standalone install (v21) ───────────
# John's finding (2026-08-25, verified against the 2.1.218 floor vsix: it
# carries extension/resources/native-binary/claude, ~270MB): the Claude Code
# VS Code extension BUNDLES the full CLI. Baking a second standalone copy
# (~290MB on arm64) doubled it for nothing — v21 ships a tiny wrapper at
# ~/.local/bin/claude that re-resolves the newest installed extension's
# bundled binary ON EVERY RUN, so the nightly extension auto-update chain
# (claude ships 2–3 versions/day) can never break PATH: no symlink to a
# version dir that gets swept, no baked version at all.
# Fallback: a standalone ~/.local/share/claude/versions install (if a user or
# older tooling ever creates one) is used only when no extension bundle exists.
log "step 15: claude CLI shim (extension-bundled binary; no standalone install)"
cat > /tmp/claude-shim.sh <<'CLAUDE_EOF'
#!/usr/bin/env bash
# claude → the CLI bundled inside the newest installed Claude Code extension.
# Re-resolved every invocation (extension auto-updates swap version dirs).
set -u
# sort -V: plain globbing picks 2.1.9 over 2.1.245 lexically.
best=$(ls -1d "$HOME"/.local/share/code-server/extensions/anthropic.claude-code-*/resources/native-binary/claude 2>/dev/null | sort -V | tail -1)
if [ -z "$best" ] || [ ! -x "$best" ]; then
  best=$(ls -1 "$HOME"/.local/share/claude/versions/* 2>/dev/null | sort -V | tail -1)
fi
if [ -z "$best" ] || [ ! -x "$best" ]; then
  echo "claude: no Claude Code extension with a bundled CLI (and no standalone install) found" >&2
  exit 127
fi
exec "$best" "$@"
CLAUDE_EOF
as_adom 'mkdir -p ~/.local/bin && cat /tmp/claude-shim.sh > ~/.local/bin/claude && chmod 0755 ~/.local/bin/claude && head -2 ~/.local/bin/claude | grep -q bash'
rm -f /tmp/claude-shim.sh
as_adom 'grep -q "/.local/bin" ~/.bashrc || printf "export PATH=\"\$HOME/.local/bin:\$PATH\"\n" >> ~/.bashrc'
as_adom 'rm -rf ~/.claude/downloads ~/.local/share/claude'

# ── step 15b: codex CLI shim (v22 — same doctrine as claude) ────────────────
# The Codex extension bundles the FULL codex CLI (extension/bin/linux-<arch>/
# codex, ~229MB, plus its own rg/bwrap/zsh runtime) — verified against the
# 26.5820.60940 linux-arm64 vsix. One shim, zero standalone installs, PATH via
# the same ~/.local/bin. The arch dir is linux-aarch64 OR linux-arm64 OR
# linux-x64 depending on the vsix vintage — glob them all.
log "step 15b: codex CLI shim (extension-bundled binary)"
cat > /tmp/codex-shim.sh <<'CODEX_EOF'
#!/usr/bin/env bash
# codex → the CLI bundled inside the newest installed Codex (openai.chatgpt)
# extension. Re-resolved every invocation (extension updates swap version dirs).
set -u
best=$(ls -1d "$HOME"/.local/share/code-server/extensions/openai.chatgpt-*/bin/linux-*/codex 2>/dev/null | sort -V | tail -1)
if [ -z "$best" ] || [ ! -x "$best" ]; then
  echo "codex: no Codex extension with a bundled CLI found (install the openai.chatgpt extension)" >&2
  exit 127
fi
exec "$best" "$@"
CODEX_EOF
as_adom 'cat /tmp/codex-shim.sh > ~/.local/bin/codex && chmod 0755 ~/.local/bin/codex'
rm -f /tmp/codex-shim.sh
# No standalone codex anywhere: the shim is the only entry point.
as_adom 'rm -rf ~/.local/share/codex ~/.codex/bin 2>/dev/null || true'

# ── step 15c: Antigravity CLI (agy) + Kimi Code CLI (kimi) — v23 ────────────
# Kyle 2026-09-01: the "set up agent harnesses" first-run stage lets a user pick
# any of Claude / Codex / Antigravity / Kimi and sign each in from a clean UI
# backed by the real CLI in the workspace — so all four must be on PATH in a
# fresh image (claude + codex are the extension-bundled shims above; these two
# have no VS Code extension carrying a CLI, so they are real installs).
#
# Both are STATIC single binaries from the vendors' own install scripts, fetched
# for the bake arch (arm64 rootfs runs native — no Rosetta). Neither needs
# node/npm at runtime. ~/.local/bin is already on PATH (step 15) and we put both
# entry points there ourselves so the runtime `command -v` detection in
# hydrogen-control/agent_harness.rs is one rule.
#   agy  → ~/.local/bin/agy          (installer default). The installer takes ONLY
#           `-d/--dir` (verified 2026-09-01 — v23 bake #1 died on invented
#           --skip-* flags) and ends with `agy install || true`, whose shell-rc
#           edits we don't want in the image: snapshot the rc files around it and
#           put them back.
#   kimi → ~/.kimi-code/bin/kimi     (installer default; KIMI_NO_MODIFY_PATH=1)
#           + symlink ~/.local/bin/kimi
# Network failure here FAILS the bake (no `|| true`): a golden image that silently
# lacks an agent would make the harness stage lie about "installed".
log "step 15c: Antigravity CLI (agy) + Kimi Code CLI (kimi)"
as_adom 'set -e; cd ~; snap=$(mktemp -d); for f in .bashrc .profile .bash_profile .zshrc .zprofile; do [ -e "$f" ] && cp -p "$f" "$snap/$f"; done
  [ -d .config/fish ] && cp -a .config/fish "$snap/fish" || true
  curl -fsSL --retry 5 --retry-all-errors https://antigravity.google/cli/install.sh | bash
  for f in .bashrc .profile .bash_profile .zshrc .zprofile; do
    if [ -e "$snap/$f" ]; then cp -p "$snap/$f" "$f"; elif [ -e "$f" ]; then echo "  (agy installer created ~/$f — removing)"; rm -f "$f"; fi
  done
  if [ -d "$snap/fish" ]; then rm -rf .config/fish && cp -a "$snap/fish" .config/fish; elif [ -d .config/fish ]; then echo "  (agy installer created ~/.config/fish — removing)"; rm -rf .config/fish; fi
  rm -rf "$snap" ~/.cache/antigravity/staging'
as_adom 'test -x ~/.local/bin/agy && ~/.local/bin/agy --version'
as_adom 'curl -fsSL --retry 5 --retry-all-errors https://code.kimi.com/kimi-code/install.sh | KIMI_NO_MODIFY_PATH=1 bash'
as_adom 'test -x ~/.kimi-code/bin/kimi && ln -sfn ~/.kimi-code/bin/kimi ~/.local/bin/kimi && ~/.local/bin/kimi --version'

# Antigravity keeps its OAuth session ONLY in a Secret Service keyring (Linux:
# org.freedesktop.secrets over the D-Bus SESSION bus). It has no plaintext
# fallback, and its container "file-based token" mode is write-only
# (google-antigravity/antigravity-cli#479, #57) — so a headless machine with no
# session bus + keyring daemon forgets the login the moment `agy` exits. The
# one workaround that is reported to work is a real session bus + an UNLOCKED
# gnome-keyring. We have both cheaply: adom already lingers (user@1001.service
# boots with the machine → dbus-user-session gives /run/user/1001/bus), and a
# user unit runs gnome-keyring's secrets component in the foreground, unlocking
# (creating, on first boot) the "login" keyring with an EMPTY password — the
# same posture as every CI recipe for libsecret; the keyring file lives under
# ~/.local/share/keyrings inside the user's own machine, not on the host.
# DBUS_SESSION_BUS_ADDRESS is planted in profile.d so code-server terminals and
# Hydrogen's `bash -lc` exec path (which is how the harness stage drives agy)
# both reach the bus. Packages: dbus-user-session gnome-keyring libsecret-tools
# (apt baseline in image/Dockerfile + scripts/build-rootfs.sh, lockstep).
log "step 15c: session bus + unlocked gnome-keyring for agy credential persistence"
# Every level explicitly (install -d creates PARENTS as root — v23 bake #2 left
# /home/adom/.config root-owned and step 16's code-server EACCES'd on it).
install -d -o adom -g adom -m 0755 /home/adom/.config /home/adom/.config/systemd /home/adom/.config/systemd/user /home/adom/.config/systemd/user/default.target.wants
cat > /home/adom/.config/systemd/user/adom-agent-keyring.service <<'UNIT'
[Unit]
Description=Adom: unlocked gnome-keyring secret service for agent CLIs (Antigravity)
Documentation=https://github.com/google-antigravity/antigravity-cli/issues/57
Requires=dbus.socket
After=dbus.socket

[Service]
Type=simple
# --unlock reads the keyring password from stdin; an empty password creates the
# "login" keyring on first boot and unlocks it on every boot thereafter.
ExecStart=/bin/sh -c 'printf "" | exec /usr/bin/gnome-keyring-daemon --foreground --unlock --components=secrets'
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
UNIT
chown adom:adom /home/adom/.config/systemd/user/adom-agent-keyring.service
ln -sfn ../adom-agent-keyring.service /home/adom/.config/systemd/user/default.target.wants/adom-agent-keyring.service
chown -h adom:adom /home/adom/.config/systemd/user/default.target.wants/adom-agent-keyring.service
cat > /etc/profile.d/adom-agent-keyring.sh <<'PROF'
# Adom: reach the lingering user session bus (dbus-user-session) so Secret
# Service clients (Antigravity CLI) find the unlocked gnome-keyring.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
fi
PROF
chmod 0644 /etc/profile.d/adom-agent-keyring.sh
test -x /usr/bin/gnome-keyring-daemon

# ── step 16: install-claude-ext ────────────────────────────────────────────
# PINNED, never latest: newer extension builds can be incompatible with
# code-server's Node (2.1.179–2.1.212 crash → blank Claude panel; baking latest
# 2.1.212 in v11 hung every fresh install, 2026-07-17). 2.1.218 fixed the
# navigator crash — verified live 2026-07-24 under code-server 4.100.3 (activates,
# renders, full send/receive). LOCKSTEP: this pin must match CLAUDE_CODE_PIN in
# adom-hydrogen setup_steps_macos.rs (the runtime enforcement) — bump both
# together after verifying a new version renders.
EXT_ARCH="$(dpkg --print-architecture 2>/dev/null || echo arm64)"; [ "$EXT_ARCH" = "amd64" ] && EXT_ARCH=x64
# v22 (Kyle 2026-08-26): bake the CURRENT extension, not the historical floor.
# The 2.1.218 floor exists in the RUNTIME converge (setup_steps_macos.rs), which
# still removes the known-broken 2.1.179-2.1.212 range and can roll forward —
# the bake just starts fresh installs at latest so the first boot needs no
# marketplace round-trip. Resolve latest for the arch from Open VSX.
CLAUDE_EXT_PIN="$(curl -fsSL "https://open-vsx.org/api/Anthropic/claude-code/linux-${EXT_ARCH:-arm64}" | jq -r '.version')"
echo "$CLAUDE_EXT_PIN" | grep -Eq '^[0-9]+\.' || { echo "bake: could not resolve latest claude-code version" >&2; exit 1; }
log "step 16: Claude Code extension (Open VSX, CURRENT ${CLAUDE_EXT_PIN}, auto-update OFF (silent ext updates blank the panel))"
# Install from the exact .vsix, NOT `ext@version`: code-server's CLI has been seen
# resolving/updating to LATEST despite the @pin (v12 bake attempt 1). A local file
# install can only install what's in the file. The extension is PLATFORM-SPECIFIC —
# resolve the linux-<arch> target's download URL via the Open VSX API (the bare
# /file/ URL guess 404s; the namespace is capitalized "Anthropic").
as_adom "curl -fsSL 'https://open-vsx.org/api/Anthropic/claude-code/linux-${EXT_ARCH}/${CLAUDE_EXT_PIN}' | jq -r '.files.download' | xargs curl -fsSL -o /tmp/claude-code-pin.vsix"
# EXTENSIONS_GALLERY → dead endpoint: without it code-server's CLI consults the
# marketplace during ANY install (even a local vsix, even with autoUpdate=false in
# settings) and silently updates to latest — reintroducing the incompatible build.
as_adom "EXTENSIONS_GALLERY='{\"serviceUrl\":\"https://127.0.0.1:1\"}' $CS --install-extension /tmp/claude-code-pin.vsix --force 2>&1 | tail -2"
as_adom "$CS --list-extensions --show-versions 2>/dev/null | grep -qi \"claude-code@${CLAUDE_EXT_PIN}\""

# ── step 16b: Codex (openai.chatgpt) extension — CURRENT, baked (v22) ───────
# Kyle 2026-08-26: Codex is a first-class agent in the product but nothing
# installed it on mac (the workspace-updater daemon that used to add it is
# DISARMED on macOS, and its wiki manifest page is gone) — fresh containers
# had no Codex at all. Marketplace-only (NOT on Open VSX); the vspackage
# endpoint serves the vsix GZIP-WRAPPED. The extension BUNDLES the full codex
# CLI (extension/bin/linux-<arch>/codex) — the shim step below puts it on
# PATH, so baking the extension is the ONLY codex install (no standalone, no
# duplicate).
log "step 16b: Codex extension (marketplace, current)"
CODEX_ARCH="linux-arm64"; [ "${EXT_ARCH}" = "x64" ] && CODEX_ARCH="linux-x64"
CODEX_VER="$(curl -fsSL -m 30 -X POST 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' \
    -H 'Content-Type: application/json' -H 'Accept: application/json;api-version=3.0-preview.1' \
    -d '{"filters":[{"criteria":[{"filterType":7,"value":"openai.chatgpt"}]}],"flags":950}' \
    | jq -r '.results[0].extensions[0].versions[0].version')"
echo "$CODEX_VER" | grep -Eq '^[0-9]+\.' || { echo "bake: could not resolve codex extension version" >&2; exit 1; }
curl -fsSL -m 600 "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/openai/vsextensions/chatgpt/${CODEX_VER}/vspackage?targetPlatform=${CODEX_ARCH}" -o /tmp/codex.vsix.gz
gunzip -f /tmp/codex.vsix.gz
as_adom "EXTENSIONS_GALLERY='{\"serviceUrl\":\"https://127.0.0.1:1\"}' $CS --install-extension /tmp/codex.vsix --force 2>&1 | tail -2"
rm -f /tmp/codex.vsix
as_adom "$CS --list-extensions --show-versions 2>/dev/null | grep -qi 'openai.chatgpt@'"
log "  codex extension ${CODEX_VER} baked"

# ── step 16c: Kimi Code + Google Antigravity extensions — CURRENT, baked (v24)
# Kyle 2026-09-01: "i also don't see the kimi code/antigravity code-server
# extensions, weren't they supposed to be baked into the golden image?" — v23
# baked only the two CLIs (step 15c); the harness stage signs a user into an
# agent whose editor UI then wasn't there. Same install pattern as 16/16b
# (exact vsix, dead EXTENSIONS_GALLERY, --list-extensions verify).
#   kimi → moonshot-ai.kimi-code, Open VSX, PLATFORM-SPECIFIC (linux-<arch>),
#          engines ^1.100.0 (code-server 4.100.x = VS Code 1.100 — satisfied;
#          bump CSV in build-rootfs.sh before the ext floor moves). The
#          extension BUNDLES agent-core and does NOT spawn the `kimi` CLI —
#          it shares ~/.kimi-code (credentials/, config.toml) with it, so the
#          harness stage's `kimi login` signs both in at once.
#   agy  → Google.google-antigravity, marketplace-only (NOT on Open VSX),
#          universal vsix, vspackage GZIP-WRAPPED like codex. At activation it
#          resolves its backend at ~/.gemini/bin/agy and, if missing/old, pulls
#          it from the same antigravity-cli-auto-updater manifests the 15c
#          installer used — so we symlink the baked ~/.local/bin/agy there:
#          one binary, no first-run download, one keyring session.
log "step 16c: Kimi Code + Antigravity extensions (current)"
KIMI_EXT_PIN="$(curl -fsSL "https://open-vsx.org/api/moonshot-ai/kimi-code/linux-${EXT_ARCH}" | jq -r '.version')"
echo "$KIMI_EXT_PIN" | grep -Eq '^[0-9]+\.' || { echo "bake: could not resolve latest kimi-code extension version" >&2; exit 1; }
as_adom "curl -fsSL 'https://open-vsx.org/api/moonshot-ai/kimi-code/linux-${EXT_ARCH}/${KIMI_EXT_PIN}' | jq -r '.files.download' | xargs curl -fsSL -o /tmp/kimi-code.vsix"
as_adom "EXTENSIONS_GALLERY='{\"serviceUrl\":\"https://127.0.0.1:1\"}' $CS --install-extension /tmp/kimi-code.vsix --force 2>&1 | tail -2"
as_adom "rm -f /tmp/kimi-code.vsix; $CS --list-extensions --show-versions 2>/dev/null | grep -qi \"moonshot-ai.kimi-code@${KIMI_EXT_PIN}\""
log "  kimi-code extension ${KIMI_EXT_PIN} baked"
AGY_EXT_VER="$(curl -fsSL -m 30 -X POST 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' \
    -H 'Content-Type: application/json' -H 'Accept: application/json;api-version=3.0-preview.1' \
    -d '{"filters":[{"criteria":[{"filterType":7,"value":"Google.google-antigravity"}]}],"flags":950}' \
    | jq -r '.results[0].extensions[0].versions[0].version')"
echo "$AGY_EXT_VER" | grep -Eq '^[0-9]+\.' || { echo "bake: could not resolve antigravity extension version" >&2; exit 1; }
curl -fsSL -m 600 "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/Google/vsextensions/google-antigravity/${AGY_EXT_VER}/vspackage" -o /tmp/agy-ext.vsix.gz
gunzip -f /tmp/agy-ext.vsix.gz
as_adom "EXTENSIONS_GALLERY='{\"serviceUrl\":\"https://127.0.0.1:1\"}' $CS --install-extension /tmp/agy-ext.vsix --force 2>&1 | tail -2"
rm -f /tmp/agy-ext.vsix
as_adom "$CS --list-extensions --show-versions 2>/dev/null | grep -qi 'google.google-antigravity@'"
as_adom 'install -d -m 0755 ~/.gemini ~/.gemini/bin && ln -sfn ~/.local/bin/agy ~/.gemini/bin/agy && ~/.gemini/bin/agy --version'
log "  antigravity extension ${AGY_EXT_VER} baked (+ ~/.gemini/bin/agy → ~/.local/bin/agy)"

# ── step 16d: Adom Agent Bar extension — OURS, baked (v25) ──────────────────
# Kyle 2026-09-02: title-bar buttons that open a NEW Claude Code / Codex /
# Kimi tab (Antigravity: sidebar, it has no tab command). Source lives in
# hydrogen-macos/vscode-agent-bar/ (docs/features/ui/agent-bar.md); the vsix
# is checked in here at image/adom-agent-bar/ and staged at /tmp/adom-agent-bar
# (Dockerfile COPY / build-rootfs.sh) — no network, nothing to resolve. The
# buttons render in the title bar only because settings.json below sets
# workbench.editor.editorActionsLocation=titleBar (the extension would set it
# itself on first activation, but baking it avoids a settings write at boot).
log "step 16d: Adom Agent Bar extension (local vsix)"
AGENT_BAR_VSIX="$(ls /tmp/adom-agent-bar/adom-agent-bar-*.vsix 2>/dev/null | sort -V | tail -1)"
[ -f "$AGENT_BAR_VSIX" ] || { echo "bake: /tmp/adom-agent-bar/adom-agent-bar-*.vsix not staged" >&2; exit 1; }
cp "$AGENT_BAR_VSIX" /tmp/agent-bar.vsix && chmod 0644 /tmp/agent-bar.vsix
as_adom "EXTENSIONS_GALLERY='{\"serviceUrl\":\"https://127.0.0.1:1\"}' $CS --install-extension /tmp/agent-bar.vsix --force 2>&1 | tail -2"
rm -f /tmp/agent-bar.vsix
as_adom "$CS --list-extensions --show-versions 2>/dev/null | grep -qi 'adom.adom-agent-bar@'"
log "  adom-agent-bar extension baked ($(basename "$AGENT_BAR_VSIX"))"
# workbench.js rewrites (same file Hydrogen bundles and re-applies at launch,
# so the two never drift): (1) keep the bar alive with NO editor open — VS Code
# only builds editor/title actions for a group with an active editor, so the
# row vanished when the last tab closed (Kyle 2026-09-02: "i want them to stay
# open"); (2) never let code-server's startup hang on its PWA service-worker
# registration — in Hydrogen's WKWebView that await can wedge forever and VS
# Code's window-resize→layout contribution is created only after it ("code-
# server doesn't resize" on fresh installs, Kyle 2026-09-03). The script bumps
# product.json's `commit` + the client's baked copy in lockstep — code-server
# serves the bundle under /stable-<commit>/ with a 1y max-age, so the bump is
# what makes already-loaded clients fetch the patched file. NOMATCH =
# code-server upgrade changed a minified shape → fail the bake, refresh the regex.
WB=/usr/lib/code-server/lib/vscode/out/vs/code/browser/workbench/workbench.js
PATCH_OUT="$(/usr/lib/code-server/lib/node /tmp/adom-agent-bar/patch-workbench.cjs "$WB" 2>&1)" \
  || { echo "bake: workbench patch failed: $PATCH_OUT" >&2; exit 1; }
grep -q hydrogenEmptyGroupEditorActions2 "$WB" || { echo "bake: workbench.js lacks the gen-2 empty-group marker" >&2; exit 1; }
grep -q hydrogenSwStartupRace "$WB" || { echo "bake: workbench.js lacks the service-worker marker" >&2; exit 1; }
rm -f "$WB.orig"   # pristine copy is pointless in an image (11 MB); Hydrogen's launch ensure keeps one on live machines
rm -rf /tmp/adom-agent-bar
log "  workbench patch: $(echo "$PATCH_OUT" | tr '\n' ' ')"
# CSP: code-server's page policy is `connect-src 'self' ws: wss: https:` (a literal in
# server-main.js) — Hydrogen's workbench script (clean_activity_bar, runtime/macos.rs)
# must reach the host control API over plain http on loopback to follow Claude
# sign-in. Widen to loopback-any-port; mirrors the launch-time ensure exactly.
SM=/usr/lib/code-server/lib/vscode/out/server-main.js
python3 - "$SM" <<'PY' || { echo "bake: server-main.js CSP literal not found" >&2; exit 1; }
import sys
p=sys.argv[1]; s=open(p).read()
a="connect-src 'self' ws: wss: https:;"; b="connect-src 'self' ws: wss: https: http://127.0.0.1:* http://localhost:*;"
if b in s: sys.exit(0)
if a not in s: sys.exit(1)
open(p,'w').write(s.replace(a,b,1))
PY
grep -qF "http://127.0.0.1:* http://localhost:*" "$SM" || { echo "bake: CSP widen did not apply" >&2; exit 1; }
log "  csp: connect-src widened to loopback http"

# ── step 3: install-adom-vscode (extension half; binary baked earlier) ────
# `adom-vscode install` drops the .vsix at /tmp + skill + completions but
# does NOT register with code-server (proven 2026-05-31) — register the
# .vsix explicitly, then verify, exactly like the cascade.
log "step 3: adom-vscode extension — NOT baked (slim image)"
# SLIM (Kyle 2026-08-05): the converge (install-hydrogen-skills -> hydrogen-bootstrap postinstall)
# installs + registers the adom-vscode extension at first install. Baking it required
# EXECUTING the x86-64 CLI, which no Rosetta-less bake env (CI docker, plain chroot)
# can do — and it was redundant with the converge anyway.

# ── step configure-vscode: settings.json ──────────────────────────────────
# setup_steps_macos.rs "configure-vscode" payload PLUS the chat/UI disables
# the cloud reference container carries (chat.agent, navigationControl,
# secondary sidebar, copilot/git auth off) — without these the baked
# editor opens VS Code's built-in "Build with Agent" chat panel (caught
# by pup visual test 2026-06-11). Note: NO model pin — Claude Code picks
# the default model itself.
# ⚠ If Hydrogen's runtime configure-vscode step still rewrites settings.json,
# its payload in setup_steps_macos.rs must gain these keys too, or first
# launch resurrects the chat panel.
log "configure-vscode: settings.json"
install -d -o adom -g adom -m 0755 /home/adom/.local/share/code-server/User
cat > /home/adom/.local/share/code-server/User/settings.json <<'SETTINGS'
{
  "security.workspace.trust.enabled": false,
  "security.workspace.trust.untrustedFiles": "open",
  "workbench.startupEditor": "none",
  "workbench.activityBar.location": "default",
  "workbench.activityBar.iconClickBehavior": "toggle",
  "workbench.colorTheme": "Default Dark Modern",
  "workbench.statusBar.visible": false,
  "workbench.navigationControl.enabled": false,
  "workbench.secondarySideBar.visible": false,
  "workbench.secondarySideBar.defaultVisibility": "hidden",
  "workbench.editor.editorActionsLocation": "titleBar",
  "claudeCode.allowDangerouslySkipPermissions": true,
  "claudeCode.initialPermissionMode": "bypassPermissions",
  "claudeCode.preferredLocation": "panel",
  "chat.agent.enabled": false,
  "chat.commandCenter.enabled": false,
  "chat.agentsControl.enabled": false,
  "chat.unifiedAgentsBar.enabled": false,
  "github.copilot.chat.enabled": false,
  "github.copilot.enable": { "*": false },
  "github.gitAuthentication": false,
  "git.autofetch": false,
  "scm.defaultViewMode": "tree",
  "security.trustedDomains": ["*"],
  "workbench.trustedDomains.promptInTrustedWorkspace": false,
  "remote.portsAttributes": { "8821": { "onAutoForward": "silent" } },
  "remote.otherPortsAttributes": { "onAutoForward": "silent" },
  "extensions.autoUpdate": false,
  "extensions.autoCheckUpdates": false
}
SETTINGS
chown adom:adom /home/adom/.local/share/code-server/User/settings.json

# code-server's own update-check nags ("v4.x has been released!") —
# disable via config.yaml (caught by pup visual test 2026-06-11). Hydrogen's
# code-server start command should also pass --disable-update-check.
install -d -o adom -g adom -m 0755 /home/adom/.config/code-server
cat > /home/adom/.config/code-server/config.yaml <<'CSCONF'
bind-addr: 0.0.0.0:8080
auth: none
disable-telemetry: true
disable-update-check: true
CSCONF
chown adom:adom /home/adom/.config/code-server/config.yaml

# ── step configure-vscode: workbench.html IndexedDB state seed ────────────
# One injected script, runs on every page load, seeds VS Code's per-origin
# IndexedDB state:
#   1. trusted domains "*" — suppresses the 'open external website?' dialog
#      (same as the cascade's patch)
#   2. activity bar: unpin Search/SCM/Run-and-Debug + the four agent
#      sidebars (Claude sessions, Codex, Kimi, Antigravity — Kyle 2026-09-03:
#      agents live in tabs via the agent bar, not the sidebar) via
#      workbench.activity.pinnedViewlets2 — replaces the cascade's
#      interactive :8821 hide-activitybar step. Seeded ONCE per profile
#      (adom.activityBarSeeded marker) so a user who deliberately re-pins
#      them is never fought. First-ever paint can race VS Code's startup
#      read — any reload (Hydrogen's setup reloads the iframe anyway) applies it.
log "configure-vscode: workbench.html state seed (trusted domains + activity bar)"
WB=/usr/lib/code-server/lib/vscode/out/vs/code/browser/workbench/workbench.html
python3 - "$WB" <<'PY'
import sys
wb = sys.argv[1]
html = open(wb).read()
SCRIPT = ('<script>(function(){try{var r=indexedDB.open("vscode-web-state-db-global",1);'
 'r.onsuccess=function(e){var d=e.target.result;'
 'try{var t=d.transaction("ItemTable","readwrite");t.objectStore("ItemTable").put(JSON.stringify(["*"]),"http.linkProtectionTrustedDomains")}catch(_){}'
 'try{var t1=d.transaction("ItemTable","readonly");var os1=t1.objectStore("ItemTable");'
 'var sg=os1.get("adom.activityBarSeeded");sg.onsuccess=function(){if(sg.result)return;'
 'var pg=os1.get("workbench.activity.pinnedViewlets2");pg.onsuccess=function(){'
 'var arr=[];try{if(pg.result)arr=JSON.parse(pg.result)}catch(_){}'
 'var ids=["workbench.view.search","workbench.view.scm","workbench.view.debug","workbench.view.extension.codexViewContainer","workbench.view.extension.kimi-sidebar","workbench.view.extension.antigravity-sidebar"];'
 'ids.forEach(function(id){var f=null;for(var i=0;i<arr.length;i++){if(arr[i].id===id)f=arr[i]}'
 'if(f){f.pinned=false}else{arr.push({id:id,pinned:false,visible:false})}});'
 'try{var t2=d.transaction("ItemTable","readwrite");var o2=t2.objectStore("ItemTable");'
 'o2.put(JSON.stringify(arr),"workbench.activity.pinnedViewlets2");o2.put("1","adom.activityBarSeeded")}catch(_){}}}}catch(_){}};'
 'window.__hydrogenTrustedDomains=1;window.__hydrogenAbSeed=1}catch(_){}})();</script>')
if '__hydrogenAbSeed' not in html:
    html = html.replace('</head>', SCRIPT + '</head>')
    open(wb, 'w').write(html)
PY
grep -q __hydrogenTrustedDomains "$WB"
grep -q adom.activityBarSeeded "$WB"

# The IndexedDB seed above is DEFEATED on macOS: Hydrogen's WKWebView loads code-server as a
# cross-origin iframe, whose partitioned third-party IndexedDB never reaches the store
# the trusted-domains validator reads. Hydrogen patches product.json per-launch as the fix,
# but a FRESH image's very first session loads the workbench before that patch+restart
# and keeps the unpatched list in memory — the "open external website?" dialog fires
# exactly once, during first-boot Claude sign-in (Kyle, 2026-07-28). Bake the patch so
# the first byte code-server ever serves is already trusted; Hydrogen's per-launch converge
# then no-ops forever.
python3 - /usr/lib/code-server/lib/vscode/product.json <<'PY'
import json, sys
p = sys.argv[1]
j = json.load(open(p))
a = j.get("linkProtectionTrustedDomains") or []
if "*" not in a:
    a.append("*")
    j["linkProtectionTrustedDomains"] = a
    json.dump(j, open(p, "w"), indent=2)
PY
python3 -c 'import json,sys; sys.exit(0 if "*" in json.load(open("/usr/lib/code-server/lib/vscode/product.json")).get("linkProtectionTrustedDomains", []) else 1)'

# ── step 8: install-hydrogen-skills ──────────────────────────────────────────────
# Builder stages adom-hydrogen/skills/public-facing/{shared,machine} at
# /tmp/hydrogen-skills. Flat install, shared + machine buckets only (never docker/).
log "step 8: Hydrogen self-awareness skills"
if [ -d /tmp/hydrogen-skills ]; then
    count=0
    for bucket in shared machine; do
        for d in /tmp/hydrogen-skills/${bucket}/hydrogen-*/; do
            [ -f "${d}SKILL.md" ] || continue
            name="$(basename "$d")"
            # NOTE: `install -D -o adom -g adom` applies the owner to the FILE
            # only — the parent dir it auto-creates lands root:root (this bake
            # runs as root), leaving adom unable to delete/rename the skill dir.
            # Create the dir explicitly as adom, THEN install the file.
            install -d -o adom -g adom -m 0755 "/home/adom/.claude/skills/${name}"
            install -o adom -g adom -m 0644 "${d}SKILL.md" "/home/adom/.claude/skills/${name}/SKILL.md"
            count=$((count + 1))
        done
    done
    rm -rf /tmp/hydrogen-skills
    log "  installed ${count} Hydrogen skills"
    [ "$count" -gt 0 ]
else
    log "  /tmp/hydrogen-skills not staged — skipping (non-fatal, mirrors the cascade)"
fi

# ── step 10: verify-adom-bridge (CLI half) ───────────────────────────────
# Since the 2026-08 naming migration the Linux CLI is no longer published on
# the wiki — the builder STAGES the freshly built x86-64 binary at
# /tmp/adom-bridge/adom-bridge (built from adom-inc/bridge-macos cli/).
# Wiki version.json (pages/adom-bridge, cli.linux_x86_64.binary_url) is the
# fallback once bridge-macos publishing resumes shipping a Linux CLI.
log "step 10: adom-bridge CLI"
if [ -f /tmp/adom-bridge/adom-bridge ]; then
    install -m 0755 /tmp/adom-bridge/adom-bridge /usr/local/bin/adom-bridge
    rm -rf /tmp/adom-bridge
    log "  staged adom-bridge binary installed"
else
    VJ="$(curl -fsSL "https://wiki.adom.inc/api/v1/pages/adom-bridge/files/version.json")"
    BRIDGE_URL="$(echo "$VJ" | jq -r '.cli.linux_x86_64.binary_url')"
    if [ -z "$BRIDGE_URL" ] || [ "$BRIDGE_URL" = "null" ] \
       || ! curl -fsSL "$BRIDGE_URL" -o /usr/local/bin/adom-bridge 2>/dev/null; then
        echo "bake: no staged /tmp/adom-bridge/adom-bridge and no linux_x86_64 binary in the wiki manifest — stage the CLI (see BRIDGE_CLI_SRC in build-rootfs.sh)" >&2
        exit 1
    fi
fi
chmod 0755 /usr/local/bin/adom-bridge
# A stale ~/.local/bin/adom-bridge (occasionally left by older installers)
# would shadow /usr/local/bin in PATH — remove it.
rm -f /home/adom/.local/bin/adom-bridge
# Exec-verify only when the binary's arch matches the bake env (x86-64 CLI runs
# under Rosetta at RUNTIME; a Rosetta-less bake env can't exec it — file check there).
# e_machine byte: b7=aarch64, 3e=x86-64 (od is coreutils — `file` may be absent)
BIN_MACHINE="$(od -An -tx1 -j18 -N1 /usr/local/bin/adom-bridge | tr -d ' ')"
WANT_MACHINE="$([ "$(uname -m)" = aarch64 ] && echo b7 || echo 3e)"
if [ "$BIN_MACHINE" = "$WANT_MACHINE" ]; then
    as_adom 'adom-bridge --version'
else
    test -s /usr/local/bin/adom-bridge || { echo 'adom-bridge download produced an empty file' >&2; exit 1; }
    log "  adom-bridge staged (x86-64; exec-verify deferred to runtime Rosetta)"
fi

# ── Hydrogen in-machine workspace-updater daemon (Part B of Hydrogen auto-update) ───────
# Staged at /tmp/workspace-updater by the builder (CI sparse-checkout / chroot
# cp from adom-hydrogen main). GUARDED: if absent (pre-merge of
# the auto-update feature branch), skip cleanly so the monthly cron never breaks; once
# the files are on main, the bake installs the daemon so a FRESH image has it
# before Hydrogen's first launch. Hydrogen also bootstraps it into EXISTING machines via
# ensure_workspace_updater every launch — so this bake is purely first-install.
# The daemon's FIRST run installs the Codex VS Code extension, then converges
# the workspace to the wiki manifest (SHA-verified, never-downgrade, surgical).
# Codex is NOT baked — the daemon adds it at runtime.
if [ -f /tmp/workspace-updater/adom-workspace-updater.sh ]; then
    log "workspace-updater daemon (Hydrogen auto-update)"
    # LF-only (source is LF; install preserves bytes). chmod +x the script.
    install -m 0755 /tmp/workspace-updater/adom-workspace-updater.sh /usr/local/bin/adom-workspace-updater
    install -m 0644 /tmp/workspace-updater/adom-workspace-updater.service /etc/systemd/system/adom-workspace-updater.service
    install -m 0644 /tmp/workspace-updater/adom-workspace-updater.timer   /etc/systemd/system/adom-workspace-updater.timer
    # README.md intentionally NOT shipped.
    # HARDEN the timer at bake time so the image is correct regardless of which Hydrogen branch the
    # builder pulled the source from (John 2026-06-15): the updater MUST NOT run during boot.
    # Persistent=true made systemd treat the never-run timer as "missed" on a fresh import and fire
    # it IMMEDIATELY at boot (dpkg -i code-server + ext installs in the core boot path → is-system-
    # running --wait blocked for minutes). Strip any Persistent= and force a 5-min OnBootSec delay.
    sed -i '/^[[:space:]]*Persistent[[:space:]]*=/d' /etc/systemd/system/adom-workspace-updater.timer
    grep -qiE '^[[:space:]]*OnBootSec' /etc/systemd/system/adom-workspace-updater.timer \
        && sed -i 's/^[[:space:]]*OnBootSec[[:space:]]*=.*/OnBootSec=5min/' /etc/systemd/system/adom-workspace-updater.timer \
        || sed -i '/^\[Timer\]/a OnBootSec=5min' /etc/systemd/system/adom-workspace-updater.timer
    # Enable the timer so it fires on first systemd boot (nspawn boots
    # systemd as PID1). `systemctl enable` just writes the wants-symlink (works
    # offline); fall back to the symlink directly if systemctl is absent in
    # the minimal rootfs.
    systemctl enable adom-workspace-updater.timer 2>/dev/null || {
        mkdir -p /etc/systemd/system/timers.target.wants
        ln -sf /etc/systemd/system/adom-workspace-updater.timer \
               /etc/systemd/system/timers.target.wants/adom-workspace-updater.timer
    }
    rm -rf /tmp/workspace-updater
    log "  daemon $(/usr/local/bin/adom-workspace-updater --version 2>/dev/null) installed + timer enabled"
else
    log "workspace-updater not staged — skipping (pre-merge of the auto-update feature branch)"
fi

# ── cron: a first-class scheduling service for anyone in this machine ──────────
# John 2026-06-15: make crontab available to every workspace user out of the box. The `cron`
# package is in the apt baseline; ENABLE cron.service so the daemon runs at boot (systemd=true),
# so `crontab -e` / `crontab -l` and per-user jobs Just Work. `systemctl enable` writes the
# wants-symlink offline; fall back to the symlink directly if systemctl is absent in the chroot.
log "enabling cron.service (crontab available to all machine users)"
systemctl enable cron.service 2>/dev/null || {
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /lib/systemd/system/cron.service \
           /etc/systemd/system/multi-user.target.wants/cron.service 2>/dev/null \
    || ln -sf /usr/lib/systemd/system/cron.service \
              /etc/systemd/system/multi-user.target.wants/cron.service 2>/dev/null || true
}

# ── adom-wiki — the official wiki CLI (successor to the RETIRED adompkg) ────
# Staged at /tmp/adom-wiki by the builder: the NATIVE arm64 build (the same binary
# Hydrogen bundles in the .app and installs at setup via install_adom_wiki_in_workspace),
# so package operations in the machine run natively — no Rosetta. Installed to
# ~/.local/bin/adom-wiki, the exact path the Hydrogen cascade converges (idempotent
# overwrite at runtime keeps it fresh). Default registry is wiki.adom.inc — no
# env pin needed (the ADOMPKG_REGISTRY pin died with adompkg).
if [ -f /tmp/adom-wiki/adom-wiki ]; then
    log "adom-wiki CLI (official wiki package manager)"
    install -d -o adom -g adom -m 0755 /home/adom/.local/bin
    install -o adom -g adom -m 0755 /tmp/adom-wiki/adom-wiki /home/adom/.local/bin/adom-wiki
    rm -rf /tmp/adom-wiki
    log "  $(runuser -u adom -- bash -lc 'adom-wiki --version' 2>/dev/null) installed"
else
    log "adom-wiki not staged — skipping (builder must stage /tmp/adom-wiki/adom-wiki)"
fi

# ── wiki-managed CLIs (adom-wiki pkg apps on wiki.adom.inc/adom) ────────────
# adom-google is a real public `app` package that installs a binary. NOTE: the
# bake runs TOKEN-LESS — every package here MUST be ANONYMOUSLY resolvable on
# wiki.adom.inc. Let failures FAIL the build (no `| tail` mask) — then hard-gate
# that the bins actually landed.
if [ -x /home/adom/.local/bin/adom-wiki ]; then
    WIKI_MANAGED="adom/adom-google"
    log "wiki-managed CLIs: ${WIKI_MANAGED}"
    as_adom "/home/adom/.local/bin/adom-wiki pkg install ${WIKI_MANAGED}"
    for c in adom-google; do
        test -e "/home/adom/.local/bin/${c}" \
            || { echo "bake: adom-wiki pkg install did not produce ~/.local/bin/${c} (anonymous resolve failed?)" >&2; exit 1; }
    done
fi

# ── (SLIM IMAGE, Kyle 2026-08-05) ──────────────────────────────────────────
# The wiki-managed skills layer (adom/hydrogen-mac-bootstrap, adom/core tree, the
# adom/hook auto-updater) is NOT baked: the Hydrogen install cascade installs it all
# fresh from the wiki on every install (install-hydrogen-skills), and a fresh pkg
# install runs every package's install script — so baking it here was pure
# redundancy + drift. adom-wiki CLI + adom-google (not in the cascade tree)
# stay baked above.

# ── claude CLI: never auto-install its companion IDE extension ──────────────
# The claude CLI, when run inside a code-server/VS Code terminal, force-installs
# its OWN matching extension version directly to disk — deleting the pinned build
# ("Extensions added from another source", v12 first install 2026-07-17: CLI
# 2.1.212 replaced the pinned 2.1.177 → broken panel). Documented off-switch:
# CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1. Planted THREE ways for full coverage:
#   - /etc/profile.d — every login shell, and (unlike ~/.bashrc) NOT behind
#     Ubuntu's `case $- in *i*) ;; *) return` non-interactive guard;
#   - /etc/environment — PAM sessions;
#   - ~/.bashrc — code-server's integrated terminal (interactive) sources it.
log "claude CLI: disable IDE extension auto-install (profile.d + environment + bashrc)"
printf 'export CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1\n' > /etc/profile.d/claude-code-no-autoinstall.sh
chmod 0644 /etc/profile.d/claude-code-no-autoinstall.sh
grep -q CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL /etc/environment 2>/dev/null \
    || echo 'CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1' >> /etc/environment
as_adom 'grep -q CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL ~/.bashrc || echo "export CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1" >> ~/.bashrc'

# ── FINAL claude-code pin enforcement (must be LAST — after every package install) ──
# Anything above (code-server's own updater at install time, a wiki package's
# postinstall merging settings) can drift the claude-code install. Since 2026-07-27
# (Kyle: auto-update ON; upstream fixed the Node-22 navigator crash) the bake SEEDS
# the floor version and leaves marketplace auto-update enabled — the runtime step in
# adom-hydrogen (setup_steps_macos.rs) only removes the known-broken
# 2.1.179-2.1.212 range. Keep the two in lockstep.
log "final claude-code floor check (${CLAUDE_EXT_PIN}, auto-update OFF)"
as_adom 'node -e "const fs=require(\"fs\");const p=process.env.HOME+\"/.local/share/code-server/User/settings.json\";let s={};try{s=JSON.parse(fs.readFileSync(p,\"utf8\"))}catch(e){};s[\"extensions.autoUpdate\"]=false;s[\"extensions.autoCheckUpdates\"]=false;fs.writeFileSync(p,JSON.stringify(s,null,2))"'
# (auto-update era, 2026-07-27: newer-than-pin builds are legitimate — no sweep.)
as_adom "python3 - '${CLAUDE_EXT_PIN}' <<'PY'
import json, os, sys
pin = sys.argv[1]
p = os.path.expanduser('~/.local/share/code-server/extensions/extensions.json')
try:
    d = json.load(open(p))
    d = [e for e in d if e.get('identifier', {}).get('id') != 'anthropic.claude-code'
         or pin in json.dumps(e)]
    json.dump(d, open(p, 'w'))
except FileNotFoundError:
    pass
PY"
as_adom "$CS --list-extensions --show-versions 2>/dev/null | grep -qi \"claude-code@${CLAUDE_EXT_PIN}\" || EXTENSIONS_GALLERY='{\"serviceUrl\":\"https://127.0.0.1:1\"}' $CS --install-extension /tmp/claude-code-pin.vsix --force 2>&1 | tail -2"
as_adom "V=\$($CS --list-extensions --show-versions 2>/dev/null | grep -i claude-code); echo \"  final: \$V\"; echo \"\$V\" | grep -q \"@${CLAUDE_EXT_PIN}\" && ! echo \"\$V\" | grep -v \"@${CLAUDE_EXT_PIN}\" | grep -q claude-code"
rm -f /tmp/claude-code-pin.vsix

# One Claude icon, not two: the extension manifest declares TWO activity-bar
# containers with the same logo (claude-sidebar shows because Code 1.100 lacks the
# secondary sidebar; claude-sessions-sidebar's context is set unconditionally), and
# Code 1.100 IGNORES `when` on viewsContainers (honors it on views). Drop the
# sessions container, gate its views off, and clear the manifest cache the
# workbench actually reads (mirrors CLAUDE_EXT_PIN_SH in adom-hydrogen).
log "claude-code activity-bar icon dedupe"
as_adom "python3 - <<'PY'
import json, glob, os
for pj in glob.glob(os.path.expanduser('~/.local/share/code-server/extensions/anthropic.claude-code-*/package.json')):
    d = json.load(open(pj))
    c = d.get('contributes', {})
    ab = c.get('viewsContainers', {}).get('activitybar', [])
    if not any(x.get('id') == 'claude-sessions-sidebar' for x in ab):
        continue
    c['viewsContainers']['activitybar'] = [x for x in ab if x.get('id') != 'claude-sessions-sidebar']
    views = c.get('views', {})
    moved = views.pop('claude-sessions-sidebar', [])
    for v in moved: v['when'] = 'false'
    views.setdefault('claude-sidebar', []).extend(moved)
    json.dump(d, open(pj, 'w'), indent=1)
    print('  deduped:', pj)
cache = os.path.expanduser('~/.local/share/code-server/CachedProfilesData/__default__profile__/extensions.user.cache')
if os.path.exists(cache): os.remove(cache)
PY"

# ── tidy ───────────────────────────────────────────────────────────────────
# install.mjs leaves an empty {"mcpServers":{}} at ~/project/.mcp.json —
# visible bake debris in a fresh user's explorer (pup visual test
# 2026-06-11). project-content/{schematics,screenshots} stays: that's the
# intentional Adom workspace convention tools save into.
rm -f /home/adom/project/.mcp.json
rm -f /tmp/adom-vscode-*.vsix /tmp/install-mjs.log
as_adom 'npm cache clean --force >/dev/null 2>&1 || true'

# ── ownership sweep (belt + suspenders) ────────────────────────────────────
# Definitive guarantee that the user's entire home tree is adom-owned. The
# bake runs as root and mixes as_adom / root-side file creation; any tool
# (now or future) that writes a root-owned path under /home/adom would
# silently leave the user unable to delete it (the 'install -D' skill-dir
# trap that shipped in v1-v5 was exactly this). One sweep closes the whole
# class. /home/adom is a user home — nothing in it should be root-owned.
# -h so symlinks (e.g. ~/.local/bin/claude) get their own ownership set,
# not their targets'.
chown -Rh adom:adom /home/adom
log "done"
