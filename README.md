# Jiffy Generic Sandbox

The default sandbox image for Jiffy: Node.js, Python, and Go via `mise` +
`uv`, plus `gh`/`glab`/`tea` and the OpenCode coding agent. Selected by
Worker for any repository that doesn't match a more specific,
language-dedicated sandbox (see the Worker repo's ADR, item 11,
`SANDBOX_DETECTION` / `SANDBOX_IMAGE_MAP`).

## Design

- **One version manager, not three.** `mise` replaces the previous
  `nvm` + `gvm` combination — a single tool, single config format, and
  it reads existing `.nvmrc`/`.tool-versions` files directly. `uv` stays
  for Python, unchanged, since it's already the fastest and most
  standard tool for that specifically.
- **Pinned at build time, not resolved at every run.** Default
  versions (Node/Python/Go) are baked into the image via the `Dockerfile`
  `ARG`s, not fetched as "latest" when a container starts. This keeps
  retries and re-runs reproducible, and matches the image's own
  semantic-version tag (e.g. `jiffy-sandbox:1.2.3`) actually meaning
  something. Updating a default version is a deliberate act: bump the
  `ARG`, rebuild, retag.
- **Version resolution priority**, implemented in `entrypoint.sh`:
  1. The project's own structured config (e.g. `package.json`'s
     `engines.node`) — checked deterministically by the script.
  2. An explicit mention in the task text (e.g. "use Node 22") — left to
     the code agent's own judgment; reliably parsing free text isn't a
     job for a shell script.
  3. The image's pinned default otherwise.
- **The agent reads its own instructions from disk.** Rather than
  reading file content into a shell variable and passing it as CLI
  text (which would depend on unconfirmed `opencode` CLI details), the
  entrypoint's `opencode run` prompt is just a short pointer: "read
  your role from `/etc/jiffy/system-prompt.md`, then read the task from
  `$JIFFY_TASK_FILE`." The agent uses its own file tools to read both.
  This sidesteps any CLI argv-size or flag ambiguity entirely — there's
  no length limit to worry about, since the actual task content never
  passes through the shell or the CLI invocation at all.
- **`system-prompt.md` is a fixed, generic role description** — "you're
  a developer, read the code carefully, complete the task fully," the
  same for every task — baked into the image since it never varies.
  This is separate from a project's own `AGENTS.md` (project-specific
  conventions, read directly by the agent from the mounted repo).

## Layout

- `Dockerfile` — the image itself
- `entrypoint.sh` — version resolution, pre-setup script, agent
  invocation, result reporting (see inline comments for the exact flow)
- `system-prompt.md` — the fixed, generic system prompt baked into the
  image at `/etc/jiffy/system-prompt.md`

## Environment variables (set by Worker)

| Variable | Purpose |
|---|---|
| `JIFFY_REPO_DIR` | Where the repo is mounted (`/workspace`) |
| `JIFFY_TASK_FILE` | Path to the composed task content |
| `JIFFY_RESULT_FILE` | Path this script writes its JSON result to |
| `OPEN_API_BASE_URL` / `OPEN_API_KEY` | Optional LLM provider settings, forwarded through if the operator configured `SANDBOX_ENV_PASSTHROUGH` on Worker |
| `OPENCODE_MODEL` | Optional `provider/model` override; if unset, OpenCode's own `opencode.json` default applies |

The system prompt is not passed via an environment variable — it's the
static `/etc/jiffy/system-prompt.md` baked into the image (see Design).

## Known open points

- `system-prompt.md`'s exact wording is a reconstruction based on a
  description of the previous system's prompt ("you're a developer,
  read the code carefully, complete the task fully"), not a verbatim
  recovery — adjust the wording as needed.
- PR-URL extraction (grepping the latest commit message) is a
  placeholder heuristic, not a real contract with the agent yet.
- `glab`/`tea` are installed via `go install ...@latest` rather than a
  pinned version, since they're sandbox tooling rather than something
  the agent's task output depends on — an intentional, narrower
  exception to "always pin". Pin these too once specific versions are
  decided.
