#!/usr/bin/env bash
# Entrypoint for the generic Jiffy sandbox.
#
# Expects these env vars (set by Worker — see docs/adr in the worker
# repo, "Task execution flow"):
#   JIFFY_REPO_DIR    - where the repo is mounted (fixed: /workspace)
#   JIFFY_TASK_FILE   - path to the composed task content
#   JIFFY_RESULT_FILE - path this script must write the JSON result to
#
# There is a fixed, generic system prompt baked into this image at
# /etc/jiffy/system-prompt.md (see Step 3) — the agent's role
# description, the same for every task. Project-specific instructions
# are separate: the project's own AGENTS.md (if present, at the repo
# root), which the agent reads directly from the mounted working copy.
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
# Rather than reading file content into a shell variable and passing it
# as CLI text (which depended on an unconfirmed opencode CLI detail —
# see the previous revision of this file), the agent is simply told
# where to find its instructions and reads them itself with its own
# file tools. This sidesteps any CLI argv-size/flag question entirely.
system_prompt_file=/etc/jiffy/system-prompt.md

instruction="Read your operating instructions from ${system_prompt_file} and follow them. Then read the complete task from ${JIFFY_TASK_FILE} and execute it."

model_args=()
if [ -n "${OPENCODE_MODEL:-}" ]; then
  model_args=(--model "$OPENCODE_MODEL")
fi

success=true
if ! opencode run "${model_args[@]}" "$instruction" > /tmp/opencode-output.log 2>&1; then
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
