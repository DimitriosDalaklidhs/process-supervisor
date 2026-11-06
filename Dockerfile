FROM python:3.12-slim

# procps provides `ps` for the process listing in `status` (the watchdog reads
# /proc directly). bash, setsid and flock (util-linux), GNU env, awk and find
# are already part of the Debian slim base.
RUN apt-get update && apt-get install -y --no-install-recommends \
    procps \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy only what the supervisor needs (no .git, README or manifests).
COPY supervisor.sh my_worker.py ./
COPY configs/ ./configs/

# Run as an unprivileged user; numeric UID so Kubernetes can verify runAsNonRoot.
RUN chmod +x /app/supervisor.sh \
 && groupadd --gid 10001 supervisor \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin supervisor \
 && mkdir -p /app/logs \
 && chown 10001:10001 /app/logs
USER 10001:10001

# The supervisor is PID 1. Arguments to `docker run` or Kubernetes `args`
# replace CMD and are passed to the ENTRYPOINT.
ENTRYPOINT ["/app/supervisor.sh"]
CMD ["start", "configs/example.conf"]
