#!/bin/bash
# Total time tracking starts here
SECONDS=0 
LOG_FILE="/workspace/setup_report.log"

# Function to log with timestamp
log_event() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$LOG_FILE"
}

# Use bash explicitly to ensure 'source' and other bash-specific features work
set -euo pipefail

log_event "==> [START] Beginning Blackwell Deployment on RTX 5090"

# 1. Activate the official Blackwell-optimized environment
source /venv/main/bin/activate
log_event "Environment /venv/main activated."

# 2. DEFINE CORRECT PATHS (vastai/comfy:v0.8.2 specific verified paths)
COMFY_DIR=/opt/workspace-internal/ComfyUI  # Verified core path
WEB_DIR=/workspace/webapp
BOOTSTRAP_DIR=/workspace/bootstrap
export GIT_TERMINAL_PROMPT=0

log_event "==> [0/8] Environment check & Force Clean"
# Force kill existing processes to free up GPU memory and ports
pkill -9 python || true
pkill -9 gunicorn || true
log_event "Cleaned existing Python/Gunicorn processes."

# --- Environment Variables (Defaults) ---
: "${WEBAPP_GIT_SSH_URL:=}"
: "${WEBAPP_GIT_BRANCH:=main}"
: "${GIT_SSH_KEY_B64:=}"
: "${HF_ENABLE:=1}"
: "${HF_TOKEN:=}"

log_event "==> [1/8] SSH setup for Private Repos"
if [[ -n "${GIT_SSH_KEY_B64}" ]]; then
    SSH_DIR="${HOME}/.ssh"
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    echo "$GIT_SSH_KEY_B64" | tr -d '\r' | base64 -d > "$SSH_DIR/id_ed25519"
    chmod 600 "$SSH_DIR/id_ed25519"
    ssh-keyscan -t rsa,ed25519 github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
    chmod 600 "$SSH_DIR/known_hosts"
    cat > "$SSH_DIR/config" <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
    chmod 600 "$SSH_DIR/config"
    log_event "SSH keys configured."
fi

log_event "==> [2/8] Extracting Custom Nodes from Snapshot"
# Check for the snapshot and extract it to the verified path
SNAPSHOT="$BOOTSTRAP_DIR/custom_nodes_snapshot.tgz"
if [[ -f "$SNAPSHOT" ]]; then
    log_event "Found snapshot. Extracting to $COMFY_DIR/custom_nodes..."
    mkdir -p "$COMFY_DIR/custom_nodes"
    tar -xzf "$SNAPSHOT" -C "$COMFY_DIR/custom_nodes" --strip-components=1 || log_event "Snapshot extraction warning/error."
else
    log_event "No custom_nodes_snapshot.tgz found, skipping to git logic."
fi

# --- NEW: STEP 2.5 WORKFLOW BACKUP ---
log_event "==> [2.5/8] Restoring workflows"
WORKFLOW_BACKUP="$BOOTSTRAP_DIR/workflows.tgz"
if [[ -f "$WORKFLOW_BACKUP" ]]; then
    # We extract workflows into ComfyUI/user/default/workflows which is standard for the browser
    # Alternatively, extracting to ComfyUI/input if they are images/templates
    log_event "Found workflows.tgz. Extracting to $COMFY_DIR/user/default/workflows..."
    mkdir -p "$COMFY_DIR/user/default/workflows"
    tar -xzf "$WORKFLOW_BACKUP" -C "$COMFY_DIR/user/default/workflows"
else
    log_event "No workflows.tgz found. Skipping workflow restoration."
fi

log_event "==> [2.7/8] Restoring User Settings"
SETTINGS_BACKUP="$BOOTSTRAP_DIR/user_settings.tgz"
if [[ -f "$SETTINGS_BACKUP" ]]; then
    # ComfyUI settings live in the 'user' folder (comfyui_settings.json, etc.)
    log_event "Found user_settings.tgz. Extracting to $COMFY_DIR/user..."
    mkdir -p "$COMFY_DIR/user"
    tar -xzf "$SETTINGS_BACKUP" -C "$COMFY_DIR/user"
else
    log_event "No user_settings.tgz found."
fi

log_event "==> [3/8] Custom Node Requirements & Missing Audio Libs"
# We explicitly add soundfile here to prevent the comfyui-various crash
pip install --no-cache-dir soundfile

if [[ -f "$BOOTSTRAP_DIR/custom_nodes_requirements.txt" ]]; then
    pip install --no-cache-dir -r "$BOOTSTRAP_DIR/custom_nodes_requirements.txt" || true
fi

log_event "==> [4/8] Git Sync Custom Nodes from Lockfile"
# Sync/Clone nodes that weren't in the snapshot or need updates
mkdir -p "$COMFY_DIR/custom_nodes"
if [[ -f "$BOOTSTRAP_DIR/custom_nodes.lock" ]]; then
    cat "$BOOTSTRAP_DIR/custom_nodes.lock" | tr -d '\r' | while IFS=$'\t' read -r name url sha; do
        [[ -z "${name:-}" ]] && continue
        target="$COMFY_DIR/custom_nodes/$name"
        log_event "----> Syncing: $name"
        if [[ ! -d "$target/.git" ]]; then git clone "$url" "$target"; fi
        git -C "$target" checkout "$sha"
        if [[ -f "$target/requirements.txt" ]]; then
            pip install --no-cache-dir -r "$target/requirements.txt" || true
        fi
    done
fi

log_event "==> [5/8] Solving Blackwell Dependency Conflicts"
# Force Pillow >= 12.1.0 for rembg/silk stability and downgrade HF-hub for Transformers
pip install --no-cache-dir "pillow<12" "huggingface-hub<1.0"

log_event "==> [6/8] Downloading Models (High Speed Blackwell Transfer)"
if [[ "${HF_ENABLE}" == "1" ]]; then
    pip install -U huggingface_hub hf_transfer >/dev/null 2>&1 || true
    export HF_HUB_ENABLE_HF_TRANSFER=1
    python - <<'PY'
import os, pathlib
from huggingface_hub import snapshot_download
COMFY_MODELS = pathlib.Path("/opt/workspace-internal/ComfyUI/models")
manifest = pathlib.Path("/workspace/bootstrap/models_hf.txt")
token = os.environ.get("HF_TOKEN")

with open(manifest, "r") as f:
    for line in f:
        if not line.strip() or line.startswith("#"): continue
        parts = line.split()
        if len(parts) < 4: continue
        dest_subdir, repo_id, revision, filename = parts[0], parts[1], parts[2], parts[3]
        target_dir = COMFY_MODELS / dest_subdir
        target_dir.mkdir(parents=True, exist_ok=True)
        print(f"----> Downloading {filename} to {target_dir}...")
        snapshot_download(repo_id=repo_id, revision=revision, allow_patterns=[filename],
                          local_dir=str(target_dir), local_dir_use_symlinks=False, token=token)
PY
fi

log_event "==> [7/8] Setting up Racing Cards webapp"
if [[ -n "$WEBAPP_GIT_SSH_URL" ]]; then
    if [[ ! -d "$WEB_DIR/.git" ]]; then
        git clone --depth 1 --branch "$WEBAPP_GIT_BRANCH" "$WEBAPP_GIT_SSH_URL" "$WEB_DIR"
    else
        git -C "$WEB_DIR" pull
    fi
    pip install -r "$WEB_DIR/requirements.txt"
    # Final force of stable versions
    pip install "huggingface-hub<1.0" "pillow>=12.1.0" gunicorn
fi

log_event "==> [8/8] Finalizing Supervisor Config"
# 1. Jupyter on 1111
cat > /etc/supervisor/conf.d/jupyter.conf <<EOF
[program:jupyter]
directory=/workspace
command=/venv/main/bin/jupyter lab --ip 0.0.0.0 --port 1111 --no-browser --allow-root --NotebookApp.token='' --NotebookApp.password=''
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr
EOF

# 2. ComfyUI (8188) - Aggressive Pathing
cat > /etc/supervisor/conf.d/comfyui.conf <<EOF
[program:comfyui]
directory=/opt/workspace-internal/ComfyUI
command=/venv/main/bin/python /opt/workspace-internal/ComfyUI/main.py --listen 0.0.0.0 --port 8188
autostart=true
autorestart=true
startsecs=3
startretries=50
stopasgroup=true
killasgroup=true
stdout_logfile=/var/log/supervisor/comfyui.stdout.log
stderr_logfile=/var/log/supervisor/comfyui.stderr.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
EOF

# 3. Webapp on 8000
cat > /etc/supervisor/conf.d/webapp.conf <<EOF
[program:webapp]
directory=$WEB_DIR
command=/venv/main/bin/gunicorn -w 4 -b 0.0.0.0:8000 app:app
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr
EOF

log_event "Starting Supervisor Daemon..."
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf
sleep 5
supervisorctl update

# FINAL LOGGING
duration=$SECONDS
minutes=$((duration / 60))
seconds=$((duration % 60))

log_event "==> [FINISH] Deployment Complete!"
log_event "Total Setup Time: $minutes minutes and $seconds seconds."

echo "------------------------------------------------"
echo "✅ SUCCESS: Your RTX 5090 is ready."
echo "⏱️ Total Time: $minutes min $seconds sec"
echo "------------------------------------------------"

supervisorctl status
tail -f /var/log/supervisor/supervisord.log