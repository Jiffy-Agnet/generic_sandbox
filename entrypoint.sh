#!/usr/bin/env bash
# Entrypoint for the generic Jiffy sandbox.
#
# Expects these env vars (set by Worker — see docs/adr in the worker
# repo, "Task execution flow"):
#   JIFFY_REPO_DIR    - where the repo is mounted (fixed: /workspace)
#   JIFFY_TASK_FILE   - path to the composed task content
#   JIFFY_RESULT_FILE - path this script must write the JSON result to
#
# There is no separate system-prompt file: the project's own AGENTS.md
# (if present, at the repo root) is what the agent reads for
# project-specific instructions.
set -euo pipefail

: "${JIFFY_REPO_DIR:?JIFFY_REPO_DIR is required}"
: "${JIFFY_TASK_FILE:?JIFFY_TASK_FILE is required}"
: "${JIFFY_RESULT_FILE:?JIFFY_RESULT_FILE is required}"

cd "$JIFFY_REPO_DIR"

# --- Step 1: deterministic version resolution from the project's own
# structured config. This is the ONLY version-selection this script
# does itself. If the task text mentions a version some other way
# (e.g. "use Node 22"), that is left entirely to the agent's own
# judgment once it starts — parsing free text reliably is exactly the
# kind of thing better suited to the agent than a brittle regex here.
if [ -f package.json ]; then
  engine_node="$(jq -r '.engines.node // empty' package.json 2>/dev/null || true)"
  if [ -n "$engine_node" ]; then
    echo "package.json engines.node=${engine_node} — switching via mise" >&2
    mise use --path . "node@${engine_node}" \
      || echo "warning: could not install node@${engine_node}, staying on the image default" >&2
  fi
fi
# TODO: add the equivalent structured check for other ecosystems as
# they come up (e.g. a Python project's pyproject.toml requires-python).

# --- Step 2: project-specific pre-setup/entrypoint script, if any —
# this is the sandbox's job, not Worker's (Worker only mounts the repo
# and launches this container).
if [ -f .jiffy/pre-setup.sh ]; then
  echo "running .jiffy/pre-setup.sh" >&2
  bash .jiffy/pre-setup.sh
fi

# --- Step 3: run the code agent.
#
# The task content is handed off via a file path, not stdin/CLI text
# directly, to sidestep a real ambiguity in OpenCode's CLI: some docs
# describe a `--file`/`-f` flag for `opencode run`, others describe the
# prompt as a positional-argument-only, no-stdin interface. To be safe
# regardless of which is accurate for the installed version, this reads
# the full file content into a shell variable and passes it as a single
# quoted positional argument — verify with `opencode run --help` in this
# image and switch to --file if it's actually supported, for cleaner
# handling of very large task content.
task_content="$(cat "$JIFFY_TASK_FILE")"

model_args=()
if [ -n "${OPENCODE_MODEL:-}" ]; then
  model_args=(--model "$OPENCODE_MODEL")
fi

success=true
if ! opencode run "${model_args[@]}" "$task_content" > /tmp/opencode-output.log 2>&1; then
  success=false
fi
report="$(tail -c 4000 /tmp/opencode-output.log || true)"

# Best-effort PR URL extraction from the most recent commit message —
# the agent is expected to leave one there. TODO: firm this up into an
# explicit contract with the agent (e.g. a dedicated marker line) once
# available, rather than relying on a heuristic grep.
pr_url="$(git log -1 --pretty=%B 2>/dev/null | grep -oE 'https://[^ ]+/pull/[0-9]+' | head -n1 || true)"

jq -n \
  --argjson success "$success" \
  --arg report "$report" \
  --arg pr_url "$pr_url" \
  '{success: $success, report: $report, pr_url: $pr_url}' > "$JIFFY_RESULT_FILE"

[ "$success" = "true" ]
