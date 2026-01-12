# 1. The high-performance Blackwell base (Python 3.12 + CUDA 12.8)
FROM vastai/comfy:v0.8.2-cu128-py312

# 2. Maintainer
LABEL maintainer="wennan.he@racingandsports.com"

USER root

# 3. System Prep: Added openssh-client
USER root
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-confdef" \
    --no-install-recommends \
    git \
    supervisor \
    curl \
    dos2unix \
    libgl1 \
    libglib2.0-0 \
    openssh-client && \
    rm -rf /var/lib/apt/lists/*

# 4. Fix Python symlink & Build tools for Essentials/Manager nodes
RUN ln -sf /usr/bin/python3 /usr/bin/python && \
    /venv/main/bin/python -m pip install --upgrade pip "setuptools<60.0.0"

# 5. Copy project files and FIX line endings (CRLF -> LF)
RUN mkdir -p /workspace/bootstrap
COPY . /workspace/bootstrap/
RUN dos2unix /workspace/bootstrap/bootstrap.sh && \
    chmod +x /workspace/bootstrap/bootstrap.sh

# 6. Set entrypoint
WORKDIR /workspace
ENTRYPOINT ["/bin/bash", "/workspace/bootstrap/bootstrap.sh"]