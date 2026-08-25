# Generic Jiffy sandbox: Node, Python, and Go via mise + uv, git provider
# CLIs, and the OpenCode coding agent. See README.md and
# docs/version-management.md for the reasoning behind the tool choices.
#
# Default language versions are PINNED at build time below — never
# resolved as "latest" when a container starts. To update them, bump the
# ARGs and rebuild with a new image tag (e.g. jiffy-sandbox:1.2.3 ->
# 1.3.0): a deliberate, versioned event, not invisible drift.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq unzip build-essential gnupg \
    && rm -rf /var/lib/apt/lists/*

# --- mise: single polyglot version manager (Node, Go), replacing the
# previous nvm + gvm combination.
ENV MISE_DATA_DIR=/opt/mise
ENV PATH="/opt/mise/shims:/opt/mise/bin:/root/.local/bin:${PATH}"
RUN curl -fsSL https://mise.run | sh

# --- uv: Python package/version manager (unchanged from the previous
# design — already the fastest, most standard choice for this).
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

ARG NODE_DEFAULT_VERSION=22
ARG PYTHON_DEFAULT_VERSION=3.12
ARG GO_DEFAULT_VERSION=1.23

RUN mise use --global node@${NODE_DEFAULT_VERSION} \
 && mise use --global go@${GO_DEFAULT_VERSION}
RUN uv python install ${PYTHON_DEFAULT_VERSION} \
 && uv python pin ${PYTHON_DEFAULT_VERSION}

# --- Git provider CLIs
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# glab and tea are Go CLIs; installing via `go install` avoids having to
# track exact per-arch release-asset URLs. Unlike the language runtimes
# above, these are Worker/sandbox tooling rather than something the
# agent's actual task output depends on, so @latest here is an
# intentional exception to the "always pin" rule — pin these too once
# specific versions are decided.
ENV GOBIN=/usr/local/bin
RUN go install gitlab.com/gitlab-org/cli/cmd/glab@latest \
 && go install code.gitea.io/tea@latest

# --- OpenCode coding agent
RUN npm install -g opencode-ai

WORKDIR /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
