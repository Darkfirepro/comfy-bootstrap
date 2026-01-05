#!/usr/bin/env bash
set -euo pipefail

COMFY_DIR=/workspace/ComfyUI
BOOTSTRAP_DIR=/workspace/bootstrap

# Make git fail instead of prompting for credentials
export GIT_TERMINAL_PROMPT=0

# --- REQUIRED: where to fetch bootstrap package ---
: "${BOOTSTRAP_GIT_URL:=https://github.com/Darkfirepro/comfy-bootstrap.git}"
: "${BOOTSTRAP_BRANCH:=main}"

# --- OPTIONAL: webapp repo (private) ---
: "${WEBAPP_GIT_SSH_URL:=}"     # git@github.com:YOU/YOUR_WEBAPP.git
: "${WEBAPP_GIT_BRANCH:=main}"

# --- OPTIONAL: GitHub SSH key (base64 private key) for private repos ---
: "${GIT_SSH_KEY_B64:=}"

# --- OPTIONAL: Models via HuggingFace ---
: "${HF_ENABLE:=0}"             # set to 1 to enable HF download
: "${HF_TOKEN:=}"               # HF access token (DO NOT hardcode; pass via env)
: "${HF_TRANSFER:=1}"           # speeds up downloads on many setups (optional)

echo "==> [1/8] SSH setup (only if key provided)"
if [[ -n "${GIT_SSH_KEY_B64}" ]]; then
  SSH_DIR="${HOME}/.ssh"
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  echo "$GIT_SSH_KEY_B64" | tr -d '\r' | base64 -d > "$SSH_DIR/id_ed25519"
  chmod 600 "$SSH_DIR/id_ed25519"
  ssh-keyscan -t rsa,ed25519 github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
  chmod 600 "$SSH_DIR/known_hosts"
  cat > "$SSH_DIR/config" <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
  chmod 600 "$SSH_DIR/config"
fi

echo "==> [2/8] Clone/update bootstrap repo"
if [[ -z "$BOOTSTRAP_GIT_URL" ]]; then
  echo "ERROR: BOOTSTRAP_GIT_URL is not set"
  exit 1
fi

if [[ -d "$BOOTSTRAP_DIR/.git" ]]; then
  git -C "$BOOTSTRAP_DIR" fetch --all
  git -C "$BOOTSTRAP_DIR" reset --hard "origin/$BOOTSTRAP_BRANCH"
else
  rm -rf "$BOOTSTRAP_DIR"
  git clone --depth 1 --branch "$BOOTSTRAP_BRANCH" "$BOOTSTRAP_GIT_URL" "$BOOTSTRAP_DIR"
fi

echo "==> [3/8] Restore workflows + user settings"
mkdir -p "$COMFY_DIR/user/default"
if [[ -f "$BOOTSTRAP_DIR/workflows.tgz" ]]; then
  tar -xzf "$BOOTSTRAP_DIR/workflows.tgz" -C "$COMFY_DIR/user/default" || true
fi
if [[ -f "$BOOTSTRAP_DIR/user_settings.tgz" ]]; then
  tar -xzf "$BOOTSTRAP_DIR/user_settings.tgz" -C "$COMFY_DIR/user" || true
fi
if [[ -f "$BOOTSTRAP_DIR/extra_model_paths.yaml" ]]; then
  cp "$BOOTSTRAP_DIR/extra_model_paths.yaml" "$COMFY_DIR/extra_model_paths.yaml"
fi

echo "==> [3.5/8] Restore custom_nodes snapshot (NO_GIT packs)"
if [[ -f "$BOOTSTRAP_DIR/custom_nodes_snapshot.tgz" ]]; then
  echo "Extracting $BOOTSTRAP_DIR/custom_nodes_snapshot.tgz -> /workspace/ComfyUI"
  tar -xzf "$BOOTSTRAP_DIR/custom_nodes_snapshot.tgz" -C /workspace/ComfyUI
else
  echo "WARNING: custom_nodes_snapshot.tgz not found, skipping snapshot restore"
fi

echo "==> [4/8] Install custom nodes (repo + pinned commit) + deps"
mkdir -p "$COMFY_DIR/custom_nodes"
python -m pip install -U pip

if [[ -f "$BOOTSTRAP_DIR/custom_nodes.lock" ]]; then
  while IFS=$'\t' read -r name url sha; do
    [[ -z "${name:-}" ]] && continue

    target="$COMFY_DIR/custom_nodes/$name"
    echo "----> $name"

    if [[ -d "$target/.git" ]]; then
      git -C "$target" fetch --all
    else
      git clone "$url" "$target"
    fi

    git -C "$target" checkout "$sha"
    git -C "$target" submodule update --init --recursive || true

    if [[ -f "$target/requirements.txt" ]]; then
      python -m pip install -r "$target/requirements.txt"
    fi

    if [[ -f "$target/pyproject.toml" || -f "$target/setup.py" ]]; then
      python -m pip install -e "$target" || true
    fi

  done < "$BOOTSTRAP_DIR/custom_nodes.lock"
else
  echo "WARNING: custom_nodes.lock not found"
fi

if [[ -f "$BOOTSTRAP_DIR/custom_nodes_requirements.txt" ]]; then
  grep -viE '^(torch|xformers|triton)([=<> ].*)?$' "$BOOTSTRAP_DIR/custom_nodes_requirements.txt" \
    | python -m pip install -r /dev/stdin || true
fi

echo "==> [6/8] Optional: Download models from HuggingFace"
if [[ "${HF_ENABLE}" == "1" ]]; then
  if [[ -z "${HF_TOKEN}" ]]; then
    echo "ERROR: HF_ENABLE=1 but HF_TOKEN is empty. Set HF_TOKEN in env (do not commit it)."
    exit 1
  fi

  export HF_HOME=/workspace/.cache/huggingface
  export HF_HUB_ENABLE_HF_TRANSFER="${HF_TRANSFER}"

  python -m pip install -U huggingface_hub hf_transfer >/dev/null 2>&1 || true

  MANIFEST="$BOOTSTRAP_DIR/models_hf.txt"
  if [[ ! -f "$MANIFEST" ]]; then
    echo "WARNING: $MANIFEST not found, skipping HF download"
  else
    python - <<'PY'
import os, pathlib, re
from huggingface_hub import snapshot_download

COMFY = pathlib.Path("/workspace/ComfyUI/models")
manifest = pathlib.Path("/workspace/bootstrap/models_hf.txt")

token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN")
if not token:
    raise SystemExit("HF token missing. Set HF_TOKEN in env.")

def clean(line: str) -> str:
    return re.sub(r"\s+", "\t", line.strip())

rows = []
with manifest.open("r", encoding="utf-8") as f:
    for raw in f:
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        rows.append(clean(raw).split("\t"))

print(f"Found {len(rows)} HF model entries")

for dest_subdir, repo_id, revision, allow_patterns in rows:
    out_dir = COMFY / dest_subdir
    out_dir.mkdir(parents=True, exist_ok=True)

    patterns = [allow_patterns] if allow_patterns and allow_patterns != "*" else None
    print(f"Downloading {repo_id}@{revision} -> {out_dir} patterns={patterns}")

    snapshot_download(
        repo_id=repo_id,
        revision=revision,
        local_dir=str(out_dir),
        local_dir_use_symlinks=False,
        allow_patterns=patterns,
        token=token,   # IMPORTANT for private repos
    )
PY
  fi
fi

echo "==> [7/8] Pull webapp + create venv (optional)"
if [[ -n "$WEBAPP_GIT_SSH_URL" ]]; then
  WEB_DIR=/workspace/webapp
  VENV_DIR=/workspace/venv_webapp

  if [[ -d "$WEB_DIR/.git" ]]; then
    git -C "$WEB_DIR" fetch --all
    git -C "$WEB_DIR" reset --hard "origin/$WEBAPP_GIT_BRANCH"
  else
    rm -rf "$WEB_DIR"
    git clone --depth 1 --branch "$WEBAPP_GIT_BRANCH" "$WEBAPP_GIT_SSH_URL" "$WEB_DIR"
  fi

  python -m venv "$VENV_DIR"
  source "$VENV_DIR/bin/activate"
  pip install -U pip
  pip install -r "$WEB_DIR/requirements.txt"
  pip install -U gunicorn
  deactivate
fi

echo "==> [8/8] Reload services via existing supervisor (ComfyUI + optional webapp)"

if ! command -v supervisorctl >/dev/null 2>&1; then
  echo "supervisorctl not found. Please restart the instance to reload nodes."
  exit 0
fi

if [[ -n "${WEBAPP_GIT_SSH_URL}" ]]; then
  echo "Setting up supervisor program: webapp"

  cat > /etc/supervisor/conf.d/webapp.conf <<'EOF'
[program:webapp]
directory=/workspace/webapp
command=/bin/bash -lc "/workspace/venv_webapp/bin/gunicorn -w 2 -b 0.0.0.0:8000 app:app --chdir /workspace/webapp"
autostart=true
autorestart=true
startretries=3
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr
EOF
fi

supervisorctl reread || true
supervisorctl update || true
supervisorctl status || true

restart_comfy() {
  supervisorctl restart comfyui 2>/dev/null && return 0
  supervisorctl restart ComfyUI 2>/dev/null && return 0
  supervisorctl restart comfy 2>/dev/null && return 0

  local name
  name="$(supervisorctl status | awk '{print $1}' | grep -i comfy | head -n 1 || true)"
  if [[ -n "$name" ]]; then
    supervisorctl restart "$name" || true
    return 0
  fi
  return 1
}

echo "Restarting ComfyUI..."
restart_comfy || echo "WARNING: Could not identify ComfyUI program name. Check 'supervisorctl status' and restart manually."

if [[ -n "${WEBAPP_GIT_SSH_URL}" ]]; then
  echo "Restarting webapp..."
  supervisorctl restart webapp 2>/dev/null || supervisorctl start webapp 2>/dev/null || true
fi

supervisorctl status || true
echo "Done."
