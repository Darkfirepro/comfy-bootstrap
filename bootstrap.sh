#!/usr/bin/env bash
set -euo pipefail

COMFY_DIR=/workspace/ComfyUI
BOOTSTRAP_DIR=/workspace/bootstrap

# --- REQUIRED: where to fetch bootstrap package ---
: "${BOOTSTRAP_GIT_URL:=https://github.com/Darkfirepro/comfy-bootstrap.git}"     # https://github.com/you/comfy-bootstrap.git OR git@github.com:...
: "${BOOTSTRAP_BRANCH:=main}"

# --- OPTIONAL: webapp repo (private) ---
: "${WEBAPP_GIT_SSH_URL:=}"    # git@github.com:YOU/YOUR_WEBAPP.git
: "${WEBAPP_GIT_BRANCH:=main}"

# --- OPTIONAL: GitHub SSH key (base64 private key) for private repos ---
: "${GIT_SSH_KEY_B64:=}"

# --- OPTIONAL: Models via S3 ---
: "${S3_MODELS_URI:=}"
: "${AWS_DEFAULT_REGION:=ap-southeast-2}"

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

echo "==> [4/8] Install custom nodes (repo + pinned commit)"
mkdir -p "$COMFY_DIR/custom_nodes"
if [[ -f "$BOOTSTRAP_DIR/custom_nodes.lock" ]]; then
  while IFS=$'\t' read -r name url sha; do
    [[ -z "${name:-}" ]] && continue
    target="$COMFY_DIR/custom_nodes/$name"
    if [[ -d "$target/.git" ]]; then
      git -C "$target" fetch --all
    else
      git clone --depth 1 "$url" "$target"
    fi
    git -C "$target" checkout "$sha"
  done < "$BOOTSTRAP_DIR/custom_nodes.lock"
else
  echo "WARNING: custom_nodes.lock not found"
fi

echo "==> [5/8] Install Python deps required by custom nodes (safe-ish)"
python -m pip install -U pip
if [[ -f "$BOOTSTRAP_DIR/custom_nodes_requirements.txt" ]]; then
  # Avoid accidental torch/xformers upgrades; install everything else
  grep -viE '^(torch|xformers|triton)([=<> ].*)?$' "$BOOTSTRAP_DIR/custom_nodes_requirements.txt" \
    | python -m pip install -r /dev/stdin
fi

echo "==> [6/8] Optional: Sync models from S3"
if [[ -n "$S3_MODELS_URI" ]]; then
  mkdir -p "$COMFY_DIR/models"
  aws s3 sync "$S3_MODELS_URI" "$COMFY_DIR/models" --only-show-errors --no-progress
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

echo "==> [8/8] Start everything with supervisord"
cat > /etc/supervisor/conf.d/comfy_web_jupyter.conf <<EOF
[supervisord]
nodaemon=true

[program:comfyui]
directory=$COMFY_DIR
command=python main.py --listen 0.0.0.0 --port 8188
autorestart=true
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr

[program:webapp]
directory=/workspace/webapp
command=/bin/bash -lc "/workspace/venv_webapp/bin/gunicorn -w 2 -b 0.0.0.0:8000 app:app --chdir /workspace/webapp"
autorestart=true
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr
EOF

exec supervisord -c /etc/supervisor/supervisord.conf
