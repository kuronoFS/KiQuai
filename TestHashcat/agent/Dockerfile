FROM nvidia/cuda:12.9.0-base-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV HTP_AGENT_DIR=/opt/hashtopolis-agent
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    bash \
    python3 \
    python3-pip \
    python3-venv \
    unzip \
    p7zip-full \
    procps \
    pciutils \
    ocl-icd-libopencl1 \
    clinfo \
  && rm -rf /var/lib/apt/lists/* \
  && python3 -m pip install --no-cache-dir --break-system-packages requests psutil

WORKDIR /opt/hashtopolis-agent

COPY run-agent.sh /usr/local/bin/run-agent
RUN chmod +x /usr/local/bin/run-agent

ENTRYPOINT ["/usr/local/bin/run-agent"]
