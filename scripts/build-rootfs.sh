#!/usr/bin/env bash
# build-rootfs.sh — build the golden Lima/nspawn rootfs (arm64 Rosetta-hybrid) WITHOUT docker.
#
# chroot-based translation of image/Dockerfile for environments (like the
# Adom cloud container) that have sudo + chroot + mknod but no docker
# daemon, no mount capability, and no user namespaces. Produces the same
# artifact a `docker build` + `docker export` would: a flat rootfs tarball
# for `machinectl import-tar` (systemd-nspawn machine inside an arm64 Lima vz VM).
#
# Keep the steps in lockstep with image/Dockerfile — that file is the
# canonical recipe; this script exists only until CI (with real docker)
# can run it.
#
# Usage:
#   scripts/build-rootfs.sh            # → /tmp/hydrogen-golden-build/adom-golden-v1.tar.gz
#   GOLDEN_VERSION=v2 scripts/build-rootfs.sh

set -euo pipefail
cd "$(dirname "$0")/.."

VER="${GOLDEN_VERSION:-v2}"
# code-server pin. History: 2026-07-17 pinned to 4.100.3 (VS Code 1.100) because VS Code
# 1.101's `navigator is now a global in nodejs` PendingMigration guard crashed the Claude
# Code extension host (blank panel) — THE fresh-install regression of that era. v25
# (2026-09-09, Kyle: "update to the latest version of code-server") moves to 4.136.2 — the
# current Claude Code extension (2.1.26x) no longer trips the guard (proven in the v25
# bake preview). The workbench patch (image/adom-agent-bar/patch-workbench.cjs) carries
# BOTH minified shapes (1.100 and >=1.135). Keep the smoke assert on the exact minor so a
# stray CODE_SERVER_VERSION can't silently bake an untested workbench.
CSV="${CODE_SERVER_VERSION:-4.136.2}"
# (legacy .cloud wiki host reference REMOVED 2026-08-26 — wiki.adom.inc is canonical)
WORK="${WORK:-/tmp/hydrogen-golden-build}"
ROOT="${WORK}/rootfs"
OUT="${WORK}/adom-golden-${VER}-arm64.tar.gz"

mkdir -p "${WORK}"
sudo rm -rf "${ROOT}"
mkdir -p "${ROOT}"

log() { echo "[build-rootfs $(date +%H:%M:%S)] $*"; }

# ── 1. Ubuntu base rootfs (the non-docker equivalent of FROM ubuntu:24.04) ─
BASE_INDEX="https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/"
BASE="$(curl -fsSL "${BASE_INDEX}" | grep -o 'ubuntu-base-24\.04[.0-9]*-base-arm64\.tar\.gz' | sort -uV | tail -1)"
[[ -n "${BASE}" ]] || { echo "could not discover ubuntu-base tarball at ${BASE_INDEX}" >&2; exit 1; }
if [[ ! -f "${WORK}/${BASE}" ]]; then
    log "downloading ${BASE}"
    curl -fL --retry 3 "${BASE_INDEX}${BASE}" -o "${WORK}/${BASE}.part"
    mv "${WORK}/${BASE}.part" "${WORK}/${BASE}"
fi
log "extracting ${BASE}"
sudo tar -xpf "${WORK}/${BASE}" -C "${ROOT}"

# ── 2. chroot plumbing: device nodes, DNS, no-service-start guard ─────────
# We cannot mount /proc or devtmpfs (no CAP_SYS_ADMIN), so create the
# static device nodes apt/dpkg/gpg need. The package set below is chosen
# to survive a /proc-less chroot; anything that genuinely needs /proc
# belongs in CI, not here.
makedev() { [[ -e "${ROOT}/dev/$1" ]] || sudo mknod -m "$5" "${ROOT}/dev/$1" "$2" "$3" "$4"; }
makedev null    c 1 3 666
makedev zero    c 1 5 666
makedev full    c 1 7 666
makedev random  c 1 8 666
makedev urandom c 1 9 666
makedev tty     c 5 0 666
sudo mkdir -p "${ROOT}/dev/pts" "${ROOT}/dev/shm" "${ROOT}/proc" "${ROOT}/sys"

sudo cp /etc/resolv.conf "${ROOT}/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' | sudo tee "${ROOT}/usr/sbin/policy-rc.d" >/dev/null
sudo chmod +x "${ROOT}/usr/sbin/policy-rc.d"

in_root() {
    sudo chroot "${ROOT}" /usr/bin/env -i \
        HOME=/root TERM=xterm LANG=C.UTF-8 \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        DEBIAN_FRONTEND=noninteractive \
        bash -o pipefail -c "$1"
}

# ── 3. apt baseline — keep identical to image/Dockerfile ──────────────────
log "apt baseline"
in_root "apt-get update"
in_root "apt-get install -y --no-install-recommends \
    ca-certificates curl wget git jq unzip zip tar gnupg openssh-client \
    sudo locales build-essential cmake pkg-config libssl-dev \
    nodejs npm python3 python3-pip \
    systemd systemd-sysv cron \
    dbus-user-session gnome-keyring libsecret-tools"

log "github cli"
in_root "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" \
    > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh"

log "code-server ${CSV}"
in_root "curl -fsSL --retry 5 --retry-all-errors \"https://github.com/coder/code-server/releases/download/v${CSV}/code-server_${CSV}_\$(dpkg --print-architecture).deb\" -o /tmp/code-server.deb \
  && dpkg -i /tmp/code-server.deb && rm -f /tmp/code-server.deb"

log "locale"
in_root "sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen"

# ── 3b. x86-64 multiarch (Rosetta-hybrid; arm64/Lima adaptation) ──────────
# The Mac runtime boots this arm64 rootfs as a systemd-nspawn machine inside a
# Lima vz VM with Rosetta binfmt enabled, so x86-64 Adom CLIs run translated.
# The rootfs must carry the x86-64 glibc/loader for those binaries to load.
# Rosetta itself is provided by the host vz VM, NOT baked into the rootfs.
log "x86-64 multiarch (Rosetta-hybrid)"
# ports.ubuntu.com (the arm64 base's archive) does NOT carry amd64 — pin the existing
# deb822 stanzas to arm64 and add archive.ubuntu.com as an amd64-only source, or the
# post-add-architecture `apt-get update` fails with "index files failed to download".
in_root "sed -i '/^Components:/a Architectures: arm64' /etc/apt/sources.list.d/ubuntu.sources"
in_root "printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu/\nSuites: noble noble-updates noble-security\nComponents: main universe\nArchitectures: amd64\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' > /etc/apt/sources.list.d/amd64.sources"
in_root "dpkg --add-architecture amd64 && apt-get update \\
  && apt-get install -y --no-install-recommends libc6:amd64 libstdc++6:amd64 zlib1g:amd64"

# ── 4. adom user (uid/gid 1001 = cloud container parity) ──────────────────
log "adom user"
in_root "groupadd -g 1001 adom \
  && useradd -m -u 1001 -g 1001 -s /bin/bash adom \
  && echo 'adom ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/adom \
  && chmod 0440 /etc/sudoers.d/adom \
  && mkdir -p /home/adom/project && chown adom:adom /home/adom/project"

# LOCKSTEP with image/Dockerfile (John 2026-06-15):
# (a) enable LINGER for adom so user@1001.service starts at boot, not lazily on first login —
#     otherwise the user session races on-demand startup → degraded + flaky logins.
# (b) drop the pam_lastlog.so line (module absent in the slim base → "faulty module" on every login).
in_root "mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/adom"
in_root "for f in /etc/pam.d/login /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do [ -f \"\$f\" ] && sed -i 's/^\([[:space:]]*session[[:space:]].*pam_lastlog\.so.*\)\$/# \1  # removed: module absent in slim image/' \"\$f\" || true; done; true"

# ── 5. Adom CLIs from the public wiki static path ──────────────────────────
log "adom CLIs"
# v22: fetch the CLIs from the MAIN wiki's page-file API (canonical, same
# x86-64 binaries) — the legacy .cloud static host 502'd for an hour on
# 2026-08-26 and stalled the bake; it is now only the FALLBACK. Path shapes
# differ per page: adom-vscode + adom-parts-search keep theirs under bin/.
in_root "set -e; \
  fetch() { curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 \"https://wiki.adom.inc/api/v1/pages/\$1?org=adom\" -o \"\$2\"; }; \
  fetch adom-cli/files/adom-cli /usr/local/bin/adom-cli; \
  fetch adom-vscode/files/bin/adom-vscode /usr/local/bin/adom-vscode; \
  fetch adom-parts-search/files/bin/adom-parts-search /usr/local/bin/adom-parts-search; \
  for b in adom-mouser adom-digikey adom-jlcpcb adom-gchat; do \
      fetch \"\${b}/files/\${b}\" \"/usr/local/bin/\${b}\"; \
  done; chmod 0755 /usr/local/bin/adom-*"

# ── 6. host-internal alias + bootstrap updater ─────────────────────────────
# No /etc/wsl.conf: a systemd-nspawn machine boots systemd as PID1 directly;
# the WSL-only wsl.conf (default user, systemd toggle) does not apply.
log "configs"
sudo install -m 0755 image/init-host-internal.sh "${ROOT}/etc/init-host-internal.sh"
sudo install -D -m 0755 image/bootstrap.sh "${ROOT}/opt/adom/bootstrap.sh"
in_root "chown -R adom:adom /opt/adom"

# ── 7. bake the Hydrogen setup steps ────────────────────────────────────────────
# SLIM IMAGE (Kyle 2026-08-05): Hydrogen skills + wiki-managed skill layers are NOT
# baked — the install cascade (install-hydrogen-skills) pulls them fresh from the
# wiki on every install. The image keeps only the static layer (OS, code-server
# pin, extensions, CLIs). bake-hydrogen-setup.sh steps self-skip when unstaged.

# (workspace-updater daemon: NOT staged — Hydrogen ensures it per-launch via
#  ensure_workspace_updater; the bake block self-skips.)

# adom-bridge CLI (x86-64 linux, runs under Rosetta in the machine) — staged
# for step 10 of bake-hydrogen-setup.sh. Built from adom-inc/bridge-macos cli/
# (cargo build --release --target x86_64-unknown-linux-gnu). REQUIRED since
# the wiki no longer publishes a Linux CLI binary.
BRIDGE_CLI_SRC="${BRIDGE_CLI_SRC:-${HOME}/project/bridge-macos/cli/target/x86_64-unknown-linux-gnu/release/adom-bridge}"
sudo rm -rf "${ROOT}/tmp/adom-bridge"
if [[ -f "${BRIDGE_CLI_SRC}" ]]; then
  sudo mkdir -p "${ROOT}/tmp/adom-bridge"
  sudo install -m 0755 "${BRIDGE_CLI_SRC}" "${ROOT}/tmp/adom-bridge/adom-bridge"
else
  echo "build-rootfs: BRIDGE_CLI_SRC not found (${BRIDGE_CLI_SRC}) — bake will fail at step 10 unless the wiki manifest carries a linux CLI" >&2
fi

# Adom Agent Bar extension (ours; vsix checked into image/adom-agent-bar/,
# built from hydrogen-macos/vscode-agent-bar/build.sh) — staged for bake step 16d.
sudo rm -rf "${ROOT}/tmp/adom-agent-bar"
sudo mkdir -p "${ROOT}/tmp/adom-agent-bar"
sudo install -m 0644 "$(dirname "$0")"/../image/adom-agent-bar/adom-agent-bar-*.vsix \
  "$(dirname "$0")"/../image/adom-agent-bar/patch-workbench.cjs "${ROOT}/tmp/adom-agent-bar/"

# adom-wiki CLI (native arm64; the official wiki package manager — adompkg is
# RETIRED) — staged for the adom-wiki step in bake-hydrogen-setup.sh. Source: the same
# binary adom-hydrogen bundles (scripts/fetch-adom-wiki.sh stages it there).
ADOM_WIKI_SRC="${ADOM_WIKI_SRC:-${HOME}/project/hydrogen-macos/src-tauri/crates/hydrogen-app/resources/adom-wiki/adom-wiki-linux-arm64}"
ADOM_WIKI_CLI_VERSION="${ADOM_WIKI_CLI_VERSION:-1.0.82}"
sudo rm -rf "${ROOT}/tmp/adom-wiki"
sudo mkdir -p "${ROOT}/tmp/adom-wiki"
if [[ -f "${ADOM_WIKI_SRC}" ]]; then
    log "staging adom-wiki from ${ADOM_WIKI_SRC}"
    sudo cp "${ADOM_WIKI_SRC}" "${ROOT}/tmp/adom-wiki/adom-wiki"
else
    log "staging adom-wiki ${ADOM_WIKI_CLI_VERSION} from the wiki (anonymous release asset)"
    curl -fsSL "https://wiki.adom.inc/download/adom/adom-wiki-cli/${ADOM_WIKI_CLI_VERSION}/adom-wiki-linux-arm64" -o /tmp/adom-wiki-dl
    sudo mv /tmp/adom-wiki-dl "${ROOT}/tmp/adom-wiki/adom-wiki"
fi
sudo chmod 0755 "${ROOT}/tmp/adom-wiki/adom-wiki"

# bake-hydrogen-setup.sh pre-runs the Hydrogen setup cascade (claude CLI, Claude Code +
# adom-vscode extensions, VS Code settings, trusted domains, Hydrogen skills,
# adom-bridge CLI, wiki-managed installs via adom-wiki) — shared with Dockerfile.
log "bake Hydrogen setup steps"
sudo install -m 0755 image/bake-hydrogen-setup.sh "${ROOT}/tmp/bake-hydrogen-setup.sh"
in_root "bash /tmp/bake-hydrogen-setup.sh && rm -f /tmp/bake-hydrogen-setup.sh"

# ── 7e. functional claude verification (proot, host side) ─────────────────
# The bun-based claude binary needs /proc, which the chroot lacks — verify
# it with proot binding the host /proc. Then remove any state files the
# run generated: a baked ~/.claude.json would ship one shared anonymous
# telemetry/user ID to every install.
# Prefer a REAL chroot with /proc + /dev bind-mounted — possible on build hosts
# with mount capability (the Lima bake VM), and the closest analog of the nspawn
# runtime. Fall back to proot for mount-less hosts (the cloud container). Note:
# Ubuntu's apt proot SEGFAULTS running the bun-based claude on arm64, so the
# mount path is strongly preferred; the gitlab.io proot binary is x86-64-only.
log "verify claude CLI"
if sudo mount --bind /proc "${ROOT}/proc" 2>/dev/null; then
    sudo mount --bind /dev "${ROOT}/dev"
    CLAUDE_V="$(sudo chroot "${ROOT}" runuser -u adom -- bash -lc 'claude --version' 2>/dev/null | head -1)"
    sudo umount "${ROOT}/dev" "${ROOT}/proc"
else
    if command -v proot >/dev/null 2>&1; then
        PROOT="$(command -v proot)"
    else
        PROOT="${WORK}/proot"
        if [[ ! -x "${PROOT}" ]]; then
            curl -fsSL -o "${PROOT}" https://proot.gitlab.io/proot/bin/proot
            chmod +x "${PROOT}"
        fi
    fi
    CLAUDE_V="$("${PROOT}" -r "${ROOT}" -b /proc -b /dev -w /home/adom \
        /usr/bin/env HOME=/home/adom USER=adom PATH=/usr/local/bin:/usr/bin:/bin \
        /home/adom/.local/bin/claude --version 2>/dev/null | head -1)"
fi
echo "  claude --version → ${CLAUDE_V}"
[[ "${CLAUDE_V}" == *"Claude Code"* ]] || { echo "claude CLI failed functional verification" >&2; exit 1; }
sudo rm -rf "${ROOT}/home/adom/.claude.json" "${ROOT}/home/adom/.claude.json.backup" \
    "${ROOT}/home/adom/.claude/statsig" "${ROOT}/home/adom/.cache"

# ── 7c. public scrub (shared with image/Dockerfile) ────────────────────────
log "public scrub"
sudo install -m 0755 image/public-scrub.sh "${ROOT}/tmp/public-scrub.sh"
in_root "bash /tmp/public-scrub.sh && rm -f /tmp/public-scrub.sh"

# ── 8. sentinel + version stamp ────────────────────────────────────────────
in_root "mkdir -p /var/lib/adom-bootstrap \
  && date -Iseconds > /var/lib/adom-bootstrap/phase-a-done \
  && echo '${VER}' > /etc/adom-golden-version"

# ── 9. smoke test (chroot analog of the CI smoke step) ────────────────────
log "smoke test"
in_root "set -e; code-server --version; node --version; git --version; \
  test -e /lib64/ld-linux-x86-64.so.2 || { echo 'MISSING x86-64 loader (Rosetta-hybrid glibc)'; exit 1; }; \
  code-server --version 2>/dev/null | grep -qE '^4\\.136\\.' \
      || { echo 'code-server is NOT 4.136.x — only that minor is proven with the workbench patch + the four agent extensions (v25)'; exit 1; }; \
  test -x /etc/init-host-internal.sh; test -x /opt/adom/bootstrap.sh; \
  test -f /var/lib/adom-bootstrap/phase-a-done; cat /etc/adom-golden-version; \
  for b in adom-cli adom-vscode adom-mouser adom-digikey adom-jlcpcb adom-parts-search adom-gchat; do \
      test -x /usr/local/bin/\$b || { echo \"MISSING \$b\"; exit 1; }; done; \
  id adom | grep -q uid=1001; \
  test -x /home/adom/.local/bin/claude \
      || { echo 'MISSING claude CLI shim'; exit 1; }; \
  head -3 /home/adom/.local/bin/claude | grep -q 'bundled inside' \
      || { echo 'claude at ~/.local/bin is not the v21 extension shim'; exit 1; }; \
  ls /home/adom/.local/share/code-server/extensions/anthropic.claude-code-*/resources/native-binary/claude >/dev/null 2>&1 \
      || { echo 'MISSING extension-bundled claude binary (shim would 127)'; exit 1; }; \
  test ! -e /home/adom/.local/share/claude \
      || { echo 'LEAK: standalone claude install still in image (v21 shims to the extension bundle)'; exit 1; }; \
  runuser -u adom -- /usr/lib/code-server/bin/code-server --list-extensions 2>/dev/null | grep -qi '^anthropic.claude-code' \
      || { echo 'MISSING claude-code extension'; exit 1; }; \
  runuser -u adom -- /usr/lib/code-server/bin/code-server --list-extensions 2>/dev/null | grep -qi '^openai.chatgpt' \
      || { echo 'MISSING codex (openai.chatgpt) extension (v22 bakes it)'; exit 1; }; \
  test -x /home/adom/.local/bin/codex \
      || { echo 'MISSING codex CLI shim'; exit 1; }; \
  ls /home/adom/.local/share/code-server/extensions/openai.chatgpt-*/bin/linux-*/codex >/dev/null 2>&1 \
      || { echo 'MISSING extension-bundled codex binary (shim would 127)'; exit 1; }; \
  jq -e '.\"workbench.colorTheme\" == \"Default Dark Modern\"' /home/adom/.local/share/code-server/User/settings.json >/dev/null \
      || { echo 'MISSING dark-mode settings.json'; exit 1; }; \
  jq -e 'has(\"claudeCode.selectedModel\") | not' /home/adom/.local/share/code-server/User/settings.json >/dev/null \
      || { echo 'LEAK: vscode settings pin a model'; exit 1; }; \
  jq -e '.\"chat.agent.enabled\" == false and .\"workbench.navigationControl.enabled\" == false' \
      /home/adom/.local/share/code-server/User/settings.json >/dev/null \
      || { echo 'MISSING chat/agent-UI disables in vscode settings'; exit 1; }; \
  grep -q 'disable-update-check: true' /home/adom/.config/code-server/config.yaml \
      || { echo 'MISSING code-server disable-update-check'; exit 1; }; \
  test -x /usr/lib/systemd/systemd && test -e /sbin/init \
      || { echo 'MISSING systemd (nspawn boots systemd as PID1; no systemd binary → user timer never fires)'; exit 1; }; \
  jq -e '.\"extensions.autoUpdate\" == false and .\"extensions.autoCheckUpdates\" == false' \
      /home/adom/.local/share/code-server/User/settings.json >/dev/null \
      || { echo 'ext auto-update NOT disabled (a silent update to a Node-incompatible claude-code build blanks the panel)'; exit 1; }; \
  runuser -u adom -- /usr/lib/code-server/bin/code-server --list-extensions --show-versions 2>/dev/null \
      | grep -q 'anthropic.claude-code@' \
      || { echo 'claude-code extension missing'; exit 1; }; \
  test -f /etc/profile.d/claude-code-no-autoinstall.sh \
      && grep -q CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL /etc/environment \
      && grep -q CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL /home/adom/.bashrc \
      || { echo 'MISSING CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL (claude CLI will clobber the pinned extension)'; exit 1; }; \
  test \"\$(runuser -u adom -- bash -lc 'echo \$CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL')\" = 1 \
      || { echo 'CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL not exported in a login shell (profile.d not effective)'; exit 1; }; \
  if [ -e /usr/local/bin/adom-workspace-updater ]; then \
      test -x /usr/local/bin/adom-workspace-updater || { echo 'workspace-updater not executable'; exit 1; }; \
      /usr/local/bin/adom-workspace-updater --version 2>/dev/null | grep -qE '^adom-workspace-updater [0-9]+\.[0-9]+' \
          || { echo \"workspace-updater --version malformed: \$(/usr/local/bin/adom-workspace-updater --version 2>/dev/null)\"; exit 1; }; \
      test -L /etc/systemd/system/timers.target.wants/adom-workspace-updater.timer \
          || { echo 'workspace-updater timer not enabled'; exit 1; }; \
      ! grep -qi '^Persistent' /etc/systemd/system/adom-workspace-updater.timer \
          || { echo 'updater timer has Persistent= → fires at boot on a fresh import (dpkg in the boot path)'; exit 1; }; \
      echo 'workspace-updater daemon: baked + timer enabled (no Persistent)'; \
  else echo 'workspace-updater: not baked (pre-merge)'; fi; \
  test -e /var/lib/systemd/linger/adom \
      || { echo 'MISSING adom linger (user@1001 wont start at boot → user-session race → degraded)'; exit 1; }; \
  ! grep -rslE '^[[:space:]]*session[[:space:]].*pam_lastlog\\.so' /etc/pam.d/ >/dev/null \
      || { echo 'pam_lastlog.so still ACTIVE in /etc/pam.d (faulty-module log on every login)'; exit 1; }; \
  echo 'adom user-session: linger enabled + pam_lastlog removed'; \
  test ! -e /home/adom/project/.mcp.json || { echo 'LEAK: bake debris .mcp.json in project'; exit 1; }; \
  test -z \"\$(find /home/adom ! -user adom -print -quit)\" \
      || { echo \"OWNERSHIP: non-adom path under /home/adom: \$(find /home/adom ! -user adom -print -quit)\"; exit 1; }; \
  grep -q adom.activityBarSeeded /usr/lib/code-server/lib/vscode/out/vs/code/browser/workbench/workbench.html \
      || { echo 'MISSING trusted-domains patch'; exit 1; }; \
  test -x /usr/local/bin/adom-bridge || { echo 'MISSING adom-bridge CLI'; exit 1; }; \
  test -x /home/adom/.local/bin/adom-wiki \
      || { echo 'MISSING adom-wiki (official wiki CLI)'; exit 1; }; \
  runuser -u adom -- bash -lc 'adom-wiki --version' >/dev/null 2>&1 || { echo 'adom-wiki --version failed'; exit 1; }; \
  ! test -e /home/adom/.local/bin/adompkg || { echo 'LEAK: retired adompkg still in image'; exit 1; }; \
  ! test -e /etc/profile.d/adompkg.sh || { echo 'LEAK: retired ADOMPKG_REGISTRY profile.d pin'; exit 1; }; \
  ! grep -q 'ADOMPKG_REGISTRY' /etc/environment 2>/dev/null || { echo 'LEAK: ADOMPKG_REGISTRY in /etc/environment'; exit 1; }; \
  for c in adom-google; do \
      test -e /home/adom/.local/bin/\$c || { echo \"MISSING wiki-managed CLI: \$c\"; exit 1; }; \
  done; \
  { test ! -f /home/adom/.claude/settings.json || jq -e 'has(\"model\") | not' /home/adom/.claude/settings.json >/dev/null; } \
      || { echo 'LEAK: settings.json pins a model'; exit 1; }; \
  { test ! -f /home/adom/.claude/settings.json || jq -e '[(.hooks.UserPromptSubmit // [])[] | (.hooks // [])[] | .command // \"\"] \
          | any(contains(\"check-updates\")) | not' /home/adom/.claude/settings.json >/dev/null; } \
      || { echo 'LEAK: legacy stale-detector update hook still registered'; exit 1; }; \
  test -x /home/adom/.local/bin/agy || { echo 'MISSING agy (Antigravity CLI)'; exit 1; }; \
  test -x /home/adom/.local/bin/kimi && test -x /home/adom/.kimi-code/bin/kimi || { echo 'MISSING kimi (Kimi Code CLI)'; exit 1; }; \
  runuser -u adom -- /usr/lib/code-server/bin/code-server --list-extensions 2>/dev/null \
      | grep -qi 'moonshot-ai.kimi-code' || { echo 'MISSING kimi-code extension (v24)'; exit 1; }; \
  runuser -u adom -- /usr/lib/code-server/bin/code-server --list-extensions 2>/dev/null \
      | grep -qi 'google.google-antigravity' || { echo 'MISSING antigravity extension (v24)'; exit 1; }; \
  runuser -u adom -- /usr/lib/code-server/bin/code-server --list-extensions 2>/dev/null \
      | grep -qi 'adom.adom-agent-bar' || { echo 'MISSING adom-agent-bar extension (v25)'; exit 1; }; \
  jq -e '.\"workbench.editor.editorActionsLocation\" == \"titleBar\"' /home/adom/.local/share/code-server/User/settings.json >/dev/null \
      || { echo 'settings.json lacks editorActionsLocation=titleBar (agent bar would sit in the tab strip)'; exit 1; }; \
  grep -q hydrogenEmptyGroupEditorActions /usr/lib/code-server/lib/vscode/out/vs/code/browser/workbench/workbench.js \
      || { echo 'workbench.js lacks the empty-group editor-actions patch (agent bar would hide with no tabs open)'; exit 1; }; \
  jq -e '.hydrogenCacheBust >= 1 and (.commit != .hydrogenOrigCommit)' /usr/lib/code-server/lib/vscode/product.json >/dev/null \
      || { echo 'product.json commit not cache-busted (clients would keep the unpatched workbench.js)'; exit 1; }; \
  test -L /home/adom/.gemini/bin/agy && test -x /home/adom/.gemini/bin/agy \
      || { echo 'MISSING ~/.gemini/bin/agy symlink (antigravity ext would re-download its backend)'; exit 1; }; \
  test -x /usr/bin/gnome-keyring-daemon && test -x /usr/bin/secret-tool || { echo 'MISSING gnome-keyring/libsecret-tools'; exit 1; }; \
  test -L /home/adom/.config/systemd/user/default.target.wants/adom-agent-keyring.service || { echo 'adom-agent-keyring.service not enabled'; exit 1; }; \
  test -f /etc/profile.d/adom-agent-keyring.sh || { echo 'MISSING adom-agent-keyring profile.d'; exit 1; }; \
  echo SMOKE-OK"

# ── 10. cleanup + pack ─────────────────────────────────────────────────────
log "cleanup"
in_root "apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*"
sudo rm -f "${ROOT}/usr/sbin/policy-rc.d" "${ROOT}/etc/resolv.conf"

log "packing ${OUT}"
sudo tar --numeric-owner -C "${ROOT}" -cf - . | gzip -9 > "${OUT}"
sha256sum "${OUT}" | tee "${OUT}.sha256"
du -h "${OUT}"
log "done"
