# ============================================================
# Stage 0: builder (fetch installers, cache configs)
# ============================================================
FROM fedora:40 AS builder

RUN dnf -y install curl ca-certificates unzip git npm && dnf clean all

# Fetch installer scripts (mise + starship)
RUN curl -fsSL https://starship.rs/install.sh -o /tmp/starship-install.sh && \
    curl -fsSL https://mise.run                 -o /tmp/mise-install.sh && \
    chmod +x /tmp/starship-install.sh /tmp/mise-install.sh

# Starship config (enable mise module)
RUN mkdir -p /tmp/etc && cat > /tmp/etc/starship.toml <<'EOF'
format = "$all"
[mise]
disabled = false
EOF

# Nushell base config (loads starship; we’ll append mise & atuin later)
RUN mkdir -p /tmp/etc/nu && cat > /tmp/etc/nu/config.nu <<'EOF'
use std
let-env STARSHIP_SHELL = "nu"
let-env STARSHIP_CONFIG = "/etc/starship.toml"
# starship
starship init nu | save --force ~/.cache/starship/init.nu
source ~/.cache/starship/init.nu
# mise + atuin init snippets appended in later stages
EOF

# Starter mise config
COPY mise.toml /tmp/mise.toml


# ============================================================
# Stage 1: toolbox image
# ============================================================
FROM fedora:40 AS toolbox

ENV DNF_YUM_AUTO_YES=1 DNF_YUM_PACKAGE_PROMPT_TIMEOUT=0 \
    PATH="/root/.local/bin:/usr/local/bin:${PATH}" \
    SHELL=/usr/bin/nu

# ---- Core CLI utilities ----
RUN dnf install -y \
      nu micro \
      fd-find ripgrep fzf jq bat zoxide unzip \
      git curl wget tmux htop strace \
      podman buildah skopeo \
      dnf-plugins-core npm \
      atuin \
    && dnf clean all

# Alias fd → fdfind
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd || true

# lazygit via COPR
RUN dnf copr enable -y atim/lazygit && \
    dnf install -y lazygit && dnf clean all

# ---- Install mise + starship from builder ----
COPY --from=builder /tmp/starship-install.sh /tmp/
RUN /tmp/starship-install.sh -y && rm -f /tmp/starship-install.sh
COPY --from=builder /tmp/mise-install.sh /tmp/
RUN /tmp/mise-install.sh && rm -f /tmp/mise-install.sh

# Configs
COPY --from=builder /tmp/etc/starship.toml /etc/starship.toml
COPY --from=builder /tmp/etc/nu/config.nu /etc/nu/config.nu

# Shell activations: starship + mise + atuin
RUN printf '\n# starship\n eval "$(starship init bash)"\n' >> /etc/bashrc && \
    printf '\n# mise activation\n eval "$(/root/.local/bin/mise activate bash)"\n' >> /etc/bashrc && \
    printf '\n# atuin (bash)\n eval "$(atuin init bash)"\n' >> /etc/bashrc && \
    printf '\n# mise for Nushell\nsource (/root/.local/bin/mise activate nu)\n' >> /etc/nu/config.nu && \
    printf '\n# atuin (nushell)\natuin init nu | save --force ~/.cache/atuin/init.nu\nsource ~/.cache/atuin/init.nu\n' >> /etc/nu/config.nu

# Starter mise config
COPY --from=builder /tmp/mise.toml /root/.mise.toml
RUN install -d -m 0755 /etc/skel && cp /root/.mise.toml /etc/skel/.mise.toml

# ---- Install SST and OpenCode globally ----
RUN npm install -g sst opencode-ai

# ---- Entry ----
RUN printf '%s\n' '#!/bin/sh' \
                 'if [ -f /run/.containerenv ] || grep -q container= /proc/1/environ 2>/dev/null; then exec /usr/bin/nu; fi' \
                 'exec /usr/bin/nu' > /usr/local/bin/entrypoint.sh && \
    chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

LABEL org.opencontainers.image.title="DevOS Toolbox (Nushell + mise + starship + Atuin + SST/OpenCode)"


# ============================================================
# Stage 2: bootc image (bootable OS)
# ============================================================
FROM quay.io/fedora/fedora-bootc:latest AS bootc

ENV DNF_YUM_AUTO_YES=1 DNF_YUM_PACKAGE_PROMPT_TIMEOUT=0 \
    PATH="/root/.local/bin:/usr/local/bin:${PATH}" \
    SHELL=/usr/bin/nu

# ---- Same core utilities ----
RUN dnf install -y \
      nu micro \
      fd-find ripgrep fzf jq bat zoxide unzip \
      git curl wget tmux htop strace \
      podman buildah skopeo \
      dnf-plugins-core npm \
      atuin \
    && dnf clean all

RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd || true
RUN dnf copr enable -y atim/lazygit && dnf install -y lazygit && dnf clean all

# ---- mise + starship + configs from builder ----
COPY --from=builder /tmp/starship-install.sh /tmp/
RUN /tmp/starship-install.sh -y && rm -f /tmp/starship-install.sh
COPY --from=builder /tmp/mise-install.sh /tmp/
RUN /tmp/mise-install.sh && rm -f /tmp/mise-install.sh
COPY --from=builder /tmp/etc/starship.toml /etc/starship.toml
COPY --from=builder /tmp/etc/nu/config.nu /etc/nu/config.nu

# Activations: starship + mise + atuin
RUN printf '\n# starship\n eval "$(starship init bash)"\n' >> /etc/bashrc && \
    printf '\n# mise activation\n eval "$(/root/.local/bin/mise activate bash)"\n' >> /etc/bashrc && \
    printf '\n# atuin (bash)\n eval "$(atuin init bash)"\n' >> /etc/bashrc && \
    printf '\n# mise for Nushell\nsource (/root/.local/bin/mise activate nu)\n' >> /etc/nu/config.nu && \
    printf '\n# atuin (nushell)\natuin init nu | save --force ~/.cache/atuin/init.nu\nsource ~/.cache/atuin/init.nu\n' >> /etc/nu/config.nu

# Starter mise config
COPY --from=builder /tmp/mise.toml /root/.mise.toml
RUN install -d -m 0755 /etc/skel && cp /root/.mise.toml /etc/skel/.mise.toml

# ---- SST + OpenCode globally ----
RUN npm install -g sst opencode-ai

# ---- Example boot-only service ----
RUN mkdir -p /etc/systemd/system
COPY hello-on-boot.service /etc/systemd/system/hello-on-boot.service
RUN systemctl enable hello-on-boot.service || true

# ---- Entry ----
RUN printf '%s\n' '#!/bin/sh' \
                 'if [ -f /run/.containerenv ] || grep -q container= /proc/1/environ 2>/dev/null; then exec /usr/bin/nu; fi' \
                 'exec /usr/bin/nu' > /usr/local/bin/entrypoint.sh && \
    chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

LABEL org.opencontainers.image.title="DevOS BootC (Nushell + mise + starship + Atuin + SST/OpenCode)"
LABEL org.opencontainers.image.description="Bootable OS image built with bootc; dual-use as toolbox base"
