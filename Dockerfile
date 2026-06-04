ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

ARG NODE_MAJOR=22
ARG BUN_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest
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

# 5. Install Antigravity CLI (agy) via the official installer
# (Includes a safe fallback in case the external link requires specific host context or is not reachable)
RUN (curl -fsSL https://antigravity.google/cli/install.sh | bash && cp /root/.local/bin/agy /usr/local/bin/agy && chmod +x /usr/local/bin/agy) || echo "Antigravity CLI setup skipped or requires manual auth"

# 6. Install Herdr CLI via the official installation script
RUN curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR=/usr/local/bin sh

# 7. Install Oh My Pi (omp) CLI via the official installation script
RUN curl -fsSL https://omp.sh/install | PI_INSTALL_DIR=/usr/local/bin sh -s -- --binary

# 8. Configure the SSH daemon
RUN mkdir /var/run/sshd && \
    # Secure defaults: No root login, enable pubkey, disable password logins
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    # Disable PasswordAuthentication to force secure SSH key authentication
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/#KbdInteractiveAuthentication yes/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config && \
    # Disable StrictModes to prevent SSH from rejecting host-mounted authorized_keys files
    echo "StrictModes no" >> /etc/ssh/sshd_config

# Build argument to customize the SSH username (defaults to dev)
ARG USERNAME=dev

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

# Install Oh My Zsh for Zsh user (unattended installation)
USER ${USERNAME}
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
USER root

# Create .ssh directory and ensure correct ownership
RUN mkdir -p /home/${USERNAME}/.ssh && \
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh && \
    chmod 700 /home/${USERNAME}/.ssh

# Create an in-container backup command that writes directly to the host /backups mount.
RUN cat > /usr/local/bin/backup <<'EOF' && chmod +x /usr/local/bin/backup
#!/bin/bash
set -euo pipefail

SANDBOX="${SANDBOX_NAME:-vibebox}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
NAME="${1:-}"

if [ -z "$NAME" ]; then
  FILENAME="${SANDBOX}-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
else
  SANITISED=$(echo "$NAME" | tr -cd "a-zA-Z0-9_-")
  if [ -z "$SANITISED" ]; then
    echo "ERROR: Backup label must contain at least one letter, number, underscore, or dash."
    exit 1
  fi
  FILENAME="${SANDBOX}-backup-${SANITISED}.tar.gz"
fi

mkdir -p /backups

# Archive is root-relative so it can carry home plus persisted system folders.
# HOME_REL strips the leading slash (e.g. home/dev) so tar members are clean.
HOME_REL="${HOME#/}"

echo "=============================================="
echo "         Creating Sandbox Backup"
echo "=============================================="
echo "Sandbox: $SANDBOX"
echo "Saving $HOME, /etc, /opt, /usr/local to /backups/$FILENAME..."

# System folders are root-owned, so tar runs under sudo. --warning=no-file-changed
# keeps a live-system race (exit 1) from aborting the script; exit >1 is fatal.
set +e
sudo tar \
  --warning=no-file-changed \
  --exclude="$HOME_REL/.cache" \
  --exclude="$HOME_REL/.npm" \
  --exclude="$HOME_REL/.local/share/Trash" \
  -czf "/backups/$FILENAME" \
  -C / \
  "$HOME_REL" etc opt usr/local
RC=$?
set -e
if [ "$RC" -gt 1 ]; then
  echo "ERROR: tar failed with exit code $RC."
  exit "$RC"
fi

# Hand the archive back to the user so retention pruning needs no privileges.
sudo chown "$(id -u):$(id -g)" "/backups/$FILENAME"

find /backups -maxdepth 1 -type f -name "${SANDBOX}-backup-*.tar.gz" -mtime +"$RETENTION_DAYS" -delete

SIZE=$(du -h "/backups/$FILENAME" | cut -f1)
echo "Backup created successfully."
echo "File Size: $SIZE"
echo "Retention: deleted ${SANDBOX} backups older than ${RETENTION_DAYS} days."
echo "=============================================="
EOF

# Create an in-container update command.
RUN echo '#!/bin/bash\n\
echo "=============================================="\n\
echo "       Updating Sandbox Software Suite        "\n\
echo "=============================================="\n\
echo "1/5 Creating automatic safety backup..."\n\
backup "auto-before-update"\n\
echo ""\n\
echo "2/5 Updating system packages (APT)..."\n\
sudo apt-get update && sudo apt-get upgrade -y\n\
echo ""\n\
echo "3/5 Cleaning up old, unnecessary files..."\n\
# Autoremove orphaned packages and clear APT package download caches to save container space\n\
sudo apt-get autoremove -y && sudo apt-get clean\n\
echo ""\n\
echo "4/5 Updating global NPM CLIs..."\n\
sudo npm update -g\n\
echo ""\n\
echo "5/5 Updating Bun..."\n\
sudo bun upgrade || true\n\
echo ""\n\
echo "=============================================="\n\
echo "System packages updated and container pruned successfully."\n\
echo "Saved safety backup with label: auto-before-update"\n\
echo "=============================================="' > /usr/local/bin/update && \
    chmod +x /usr/local/bin/update

# Create an in-container 'launch' command that launches tmux and runs herdr inside it
RUN echo '#!/bin/bash\n\
SESSION_NAME="${SANDBOX_NAME:-vibebox}"\n\
if ! command -v tmux >/dev/null 2>&1; then\n\
  echo "Error: tmux is not installed."\n\
  exit 1\n\
fi\n\
if ! command -v herdr >/dev/null 2>&1; then\n\
  echo "Error: herdr is not installed."\n\
  exit 1\n\
fi\n\
if [ -n "$TMUX" ]; then\n\
  exec herdr\n\
fi\n\
tmux has-session -t "$SESSION_NAME" 2>/dev/null\n\
if [ $? -ne 0 ]; then\n\
  tmux new-session -d -s "$SESSION_NAME" "herdr"\n\
fi\n\
exec tmux attach-session -t "$SESSION_NAME"' > /usr/local/bin/launch && \
    chmod +x /usr/local/bin/launch

# Expose default SSH port inside container
EXPOSE 22

# Start the SSH daemon in the foreground
CMD ["/usr/sbin/sshd", "-D"]
