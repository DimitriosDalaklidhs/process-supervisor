# Process Supervisor: Docker & Kubernetes

A lightweight process supervisor written in Bash, containerized with Docker and deployed on Kubernetes. Demonstrates process supervision, PID 1 behavior, signal handling, and real world container debugging.

---
## What This Project Demonstrates

- Process supervision and PID 1 semantics in a containerized environment
- Correct Docker image construction for process-based workloads
- Signal handling in Bash
- Proper use of `ENTRYPOINT` vs `CMD` vs Kubernetes `command/args`
- Kubernetes Deployment lifecycle and debugging common failure modes:
  - `ImagePullBackOff`
  - `RunContainerError`
  - `CrashLoopBackOff`
  - `exec: "start": executable file not found`
- Clean, minimal operator-quality YAML
- Kustomize for modern Kubernetes workflows

---

## Project Structure

```
process-supervisor/
├── supervisor.sh          # Bash process supervisor
├── my_worker.py           # Example worker process
├── configs/
│   └── example.conf       # Supervisor configuration
├── Dockerfile             # Container image definition
└── k8s/
    ├── deployment.yaml    # Kubernetes Deployment
    └── kustomization.yaml # Kustomize entrypoint
```

---

## Docker

The Dockerfile is intentionally minimal, not even 10 lines of code: slim base image, explicit `bash` install, cache cleanup, and the supervisor running as PID 1. Argument control is left to Kubernetes.

```dockerfile
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app

RUN chmod +x /app/supervisor.sh

CMD ["/app/supervisor.sh"]
```

**Build:**
```bash
docker build -t process-supervisor:local .
```

---

## Kubernetes

The Deployment uses explicit `command` and `args` to avoid the common Kubernetes error where arguments are treated as executables:

```yaml
command: ["/app/supervisor.sh"]
args: ["start", "configs/example.conf"]
```

**Deploy with Kustomize:**
```bash
kubectl apply -k k8s
```

**Running locally with kind** (image must be loaded into the cluster explicitly):
```bash
kind load docker-image process-supervisor:local --name kind
kubectl apply -k k8s
kubectl rollout restart deployment process-supervisor
```

**Check status:**
```bash
kubectl get pods
kubectl logs -l app=process-supervisor -f
```

---

## Troubleshooting Notes

This project went through real failure modes during development:

- `ImagePullBackOff` : fixed by loading the image into kind before deploying
- `RunContainerError` : fixed by installing missing system dependencies in the Dockerfile
- `exec: "start"` error : fixed by using explicit `command` + `args` in the Deployment
- Permission denied  : fixed via `chmod` at build time

---

## Author

**Dimitrios Dalaklidis**: CS student at the University of Western Macedonia, interested in backend development, systems programming, and cloud infrastructure.  
📧 dalaklidesdemetres@gmail.com
