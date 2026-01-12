# 1. The high-performance Blackwell base
FROM vastai/comfy:v0.8.2-cu128-py312

# 2. Maintainer
LABEL maintainer="wennan.he@racingandsports.com"

# 4. Copy your project files
RUN mkdir -p /workspace/bootstrap
COPY . /workspace/bootstrap/
RUN chmod +x /workspace/bootstrap/bootstrap.sh

# 5. Set entrypoint
WORKDIR /workspace
ENTRYPOINT ["/bin/bash", "/workspace/bootstrap/bootstrap.sh"]