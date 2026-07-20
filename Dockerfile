ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

ARG NODE_MAJOR=22
ARG BUN_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest
ARG CODEBURN_VERSION=latest
ARG PI_CODING_AGENT_VERSION=latest
ARG PYRIGHT_VERSION=latest
ARG TYPESCRIPT_LANGUAGE_SERVER_VERSION=latest
ARG TYPESCRIPT_VERSION=latest
ARG VSCODE_LANGSERVERS_VERSION=latest
ARG YAML_LANGUAGE_SERVER_VERSION=latest
ARG BASH_LANGUAGE_SERVER_VERSION=latest
ARG TAILWIND_LANGUAGE_SERVER_VERSION=latest

# 1. Update package lists and install standard sandbox packages + developer utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    sudo \
    curl \
    git \
    wget \
    nano \
    htop \
    procps \
    tmux \
    rsync \
    build-essential \
    gnupg2 \
    pkg-config \
    zlib1g-dev \
    python3 \
    python3-pip \
    python3-venv \
    ca-certificates \
    iputils-ping \
    unzip \
    zip \
    ripgrep \
    fzf \
    jq \
    zsh \
    && rm -rf /var/lib/apt/lists/*

# 2. Install GitHub CLI (gh) via official repository
RUN mkdir -p -m 755 /etc/apt/keyrings && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && apt-get install -y gh && \
    rm -rf /var/lib/apt/lists/*

# 3. Install Node.js LTS major via NodeSource (required for Claude & Codex CLIs)
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# 4. Standardized Global NPM Installs: Install Claude Code, OpenAI Codex, Pyright, and Lightpanda Browser CLIs
RUN npm install -g \
    @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    @openai/codex@${CODEX_VERSION} \
    bun@${BUN_VERSION} \
    pyright@${PYRIGHT_VERSION} \
    typescript@${TYPESCRIPT_VERSION} \
    typescript-language-server@${TYPESCRIPT_LANGUAGE_SERVER_VERSION} \
    vscode-langservers-extracted@${VSCODE_LANGSERVERS_VERSION} \
    yaml-language-server@${YAML_LANGUAGE_SERVER_VERSION} \
    bash-language-server@${BASH_LANGUAGE_SERVER_VERSION} \
    @tailwindcss/language-server@${TAILWIND_LANGUAGE_SERVER_VERSION} \
    && npm cache clean --force

# 4b. Install codeburn (AI spend tracker) as a tolerated npm global.
# Kept out of the step-4 block so a publish/registry hiccup on this optional tool
# cannot fail a build that already produced the whole core toolchain.
RUN npm install -g codeburn@${CODEBURN_VERSION} || echo "codeburn setup skipped"

# 4c. Install Pi coding agent (npm global). --ignore-scripts per upstream recommendation
# (see https://github.com/earendil-works/pi). Tolerated so a registry hiccup cannot
# fail a build that already produced the whole core toolchain.
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@${PI_CODING_AGENT_VERSION} || echo "Pi setup skipped"

# 5. Install Antigravity CLI (agy) via the official installer
# (Includes a safe fallback in case the external link requires specific host context or is not reachable)
RUN (curl -fsSL https://antigravity.google/cli/install.sh | bash && cp /root/.local/bin/agy /usr/local/bin/agy && chmod +x /usr/local/bin/agy) || echo "Antigravity CLI setup skipped or requires manual auth"

# 6. Install Herdr CLI via the official installation script
RUN (curl -fsSL https://herdr.dev/install.sh | sh && \
     (cp /root/.local/bin/herdr /usr/local/bin/herdr 2>/dev/null || true) && \
     chmod +x /usr/local/bin/herdr 2>/dev/null) || echo "Herdr CLI setup skipped"

# 7. Install RTK (Rust Token Killer) via the official installer.
# Reduces LLM token consumption by 60-90% by filtering/compressing command outputs
# before they reach the agent's context. `onboard` runs `rtk init` per-agent (writes
# per-user config into $HOME, so it cannot be baked into the image — same reason as
# CodeGraph).
RUN (curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh && \
     (cp /root/.local/bin/rtk /usr/local/bin/rtk 2>/dev/null || true) && \
     chmod +x /usr/local/bin/rtk 2>/dev/null) || echo "RTK setup skipped"

# 8. Install Hermes Agent via the official installer.
# Running as root, the installer uses root-mode and lands the binary in /usr/local/bin
# directly; the cp is a fallback in case it takes the per-user (~/.local/bin) path.
RUN (curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash && \
     (cp /root/.local/bin/hermes /usr/local/bin/hermes 2>/dev/null || true) && \
     chmod +x /usr/local/bin/hermes 2>/dev/null) || echo "Hermes Agent setup skipped or requires manual auth"

# 8b. Install Hermes WebUI (web frontend for the Hermes Agent installed in step 8).
# Cloned into /opt (image-managed) so a rebuild updates agent + webui together —
# upstream warns against version skew between the two. Runtime state (sessions,
# pid, logs) lands in ~/.hermes/webui on the persisted home volume. Owned by the
# sandbox user (UID 1000, created later) so `update` can git-pull and ctl.sh can
# run without sudo. Started at container boot by the entrypoint.
RUN (git clone --depth 1 https://github.com/nesquena/hermes-webui.git /opt/hermes-webui && \
     python3 -m venv /opt/hermes-webui/.venv && \
     /opt/hermes-webui/.venv/bin/pip install --no-cache-dir -r /opt/hermes-webui/requirements.txt && \
     chown -R 1000:1000 /opt/hermes-webui) || echo "Hermes WebUI setup skipped"

# 9. Install CodeGraph — last tool step, since `codegraph install` wires itself into
# whichever agent CLIs are present and should see the full set installed above.
# NOTE: `codegraph install` is NOT run here. It writes per-user agent config into $HOME
# (e.g. ~/.claude.json), and $HOME is a persisted volume that masks image content on
# rebuilds — so a build-time run as root would not reach the sandbox user. Run it once
# inside the container instead (documented in README).
# Unlike the single-file binaries above, codegraph is a Node bundle whose launcher
# resolves the bundle relative to its own symlink-resolved path. Copying the launcher
# into /usr/local/bin severs that link, leaving it to exec a nonexistent /usr/local/node.
# So let the installer place both itself, via its own env vars: the bundle in /opt
# (world-readable) rather than the default ~/.codegraph, which as root lands under
# /root (mode 700) and is unreadable by the sandbox user.
RUN (curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | \
       env CODEGRAPH_INSTALL_DIR=/opt/codegraph CODEGRAPH_BIN_DIR=/usr/local/bin sh && \
     chmod -R a+rX /opt/codegraph) || echo "CodeGraph setup skipped"

# 9b. Verify installs so a build cannot silently succeed with tooling missing.
# Hard-fail on the daily-driver tools; loud-warn on the optional CLIs whose
# installers are tolerated above (a network blip shouldn't kill a 10-minute build).
RUN set -e; \
    for t in claude codex bun node gh; do command -v "$t" >/dev/null || { echo "FATAL: $t missing"; exit 1; }; done; \
    for t in agy herdr rtk hermes codegraph codeburn pi; do \
      if ! command -v "$t" >/dev/null; then echo "WARNING: $t not installed (non-fatal)"; \
      elif ! "$t" --version >/dev/null 2>&1; then echo "WARNING: $t installed but fails to run (non-fatal)"; fi; \
    done; \
    [ -x /opt/hermes-webui/ctl.sh ] || echo "WARNING: hermes-webui not installed (non-fatal)"

# Build argument to customize the SSH username (defaults to dev)
ARG USERNAME=dev

# 10. Configure the SSH daemon
RUN mkdir /var/run/sshd && \
    # Secure defaults: No root login, enable pubkey, disable password logins
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    # Disable PasswordAuthentication to force secure SSH key authentication
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/#KbdInteractiveAuthentication yes/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config && \
    # Disable StrictModes to prevent SSH from rejecting host-mounted authorized_keys files
    echo "StrictModes no" >> /etc/ssh/sshd_config && \
    # Let sshd read ~/.ssh/environment, written each boot by the entrypoint. This is the
    # only hook that reaches every session type — login, interactive, `ssh vibebox <cmd>`,
    # and Remote-SSH — and it is shell-agnostic, unlike .zshrc/.bashrc (which are user
    # dotfiles restored from the host manifest, so edits there do not survive).
    # The usual objection (a user setting LD_PRELOAD to escalate) is moot here: the
    # sandbox user already has passwordless sudo, configured below.
    echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config && \
    # Host keys live in the persisted home volume (generated once by the entrypoint) so the
    # sandbox keeps a stable identity across rebuilds without persisting all of /etc.
    printf 'HostKey /home/%s/.vibebox/ssh/ssh_host_ed25519_key\nHostKey /home/%s/.vibebox/ssh/ssh_host_rsa_key\n' "${USERNAME}" "${USERNAME}" >> /etc/ssh/sshd_config

# Create a dedicated custom user with UID/GID 1000 and setup passwordless sudo
# Configures Zsh (/bin/zsh) as the default shell for a consistent macOS developer feel!
RUN set -eux; \
    if getent group 1000 >/dev/null; then \
      EXISTING_GROUP="$(getent group 1000 | cut -d: -f1)"; \
      if [ "$EXISTING_GROUP" != "${USERNAME}" ]; then groupmod -n "${USERNAME}" "$EXISTING_GROUP"; fi; \
    else \
      groupadd -g 1000 "${USERNAME}"; \
    fi; \
    if getent passwd 1000 >/dev/null; then \
      EXISTING_USER="$(getent passwd 1000 | cut -d: -f1)"; \
      if [ "$EXISTING_USER" != "${USERNAME}" ]; then usermod -l "${USERNAME}" -d "/home/${USERNAME}" -m "$EXISTING_USER"; fi; \
      usermod -s /bin/zsh -g "${USERNAME}" -G sudo "${USERNAME}"; \
    else \
      useradd -rm -d "/home/${USERNAME}" -s /bin/zsh -g "${USERNAME}" -G sudo -u 1000 "${USERNAME}"; \
    fi; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" && \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

# Create .ssh directory and ensure correct ownership
RUN mkdir -p /home/${USERNAME}/.ssh && \
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh && \
    chmod 700 /home/${USERNAME}/.ssh

# Install the in-container commands (onboard, backup, update, launch) and the
# entrypoint as real files from scripts/, plus the shared dotfiles manifest.
# Editing these is now editing a shell script — no Dockerfile heredocs.
COPY scripts/ /usr/local/bin/
COPY dotfiles.manifest /usr/local/share/vibebox/dotfiles.manifest
# chmod explicitly — the execute bit does not survive a Windows/git checkout reliably.
RUN chmod +x /usr/local/bin/onboard /usr/local/bin/backup \
             /usr/local/bin/update  /usr/local/bin/launch /usr/local/bin/entrypoint

# Expose default SSH port inside container
EXPOSE 22

# Generate host keys once (into the persisted home volume) then start sshd.
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["/usr/sbin/sshd", "-D"]
