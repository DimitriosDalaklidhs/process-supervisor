# Process Supervisor (Bash) — Docker & Kubernetes

A lightweight Linux **process supervisor written in Bash**, containerized with Docker and deployed on Kubernetes.  
This project demonstrates **process supervision, PID 1 behavior, signal handling, and real-world container/Kubernetes debugging**.

The original supervisor runs on bare metal Linux. This repository extends it to run correctly in **Docker** and **Kubernetes**, without changing the core logic.

---

## What This Project Demonstrates

From a cloud / DevOps perspective, this repository shows:

- Running a **non-trivial workload** (a process supervisor, not a hello-world app)
- Correct **Docker image construction** for process-based workloads
- **PID 1 semantics** and signal handling
- Correct use of **ENTRYPOINT vs CMD vs Kubernetes command/args**
- Kubernetes **Deployment lifecycle**
- Debugging common Kubernetes failures:
  - `ImagePullBackOff`
  - `RunContainerError`
  - `CrashLoopBackOff`
  - `exec: "start": executable file not found`
- Clean, minimal, **operator-quality YAML**
- Use of **Kustomize** for modern Kubernetes workflows

This YAML reflects debugging and iteration.

---

## Repository Structure
├── supervisor.sh # Bash process supervisor

├── my_worker.py # Example worker process

├── configs/

│ └── example.conf # Supervisor configuration

├── Dockerfile # Container image definition

└── k8s/

├── deployment.yaml # Kubernetes Deployment

└── kustomization.yaml # Kustomize entrypoint

---

## Docker


The Dockerfile is intentionally minimal:

- Uses a **slim base image**
- Explicitly installs `bash` (required for the supervisor)
- Cleans package caches to keep the image small
- Runs the supervisor as PID 1
- Leaves argument control to Kubernetes

```dockerfile
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app

RUN chmod +x /app/supervisor.sh

# Default command; Kubernetes overrides args as needed
CMD ["/app/supervisor.sh"]


---

## Docker

### Why this Dockerfile matters

The Dockerfile is intentionally minimal but correct:

- Uses a **slim base image**
- Explicitly installs `bash` (required for the supervisor)
- Cleans package caches to keep the image small
- Runs the supervisor as PID 1
- Leaves argument control to Kubernetes

```dockerfile
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app

RUN chmod +x /app/supervisor.sh

# Default command; Kubernetes overrides args as needed
CMD ["/app/supervisor.sh"]

This setup works both locally and inside Kubernetes.
```

 ### Build the image

```bash
docker build -t process-supervisor:local .
```

# Kubernetes


The Kubernetes Deployment is intentionally simple and readable:

- Uses apps/v1

- Correct label/selector matching

- Single replica (appropriate for a demo)

- Explicit command and args to avoid ENTRYPOINT ambiguity

- No reliance on external registries
```yaml
command: ["/app/supervisor.sh"]
args: ["start", "configs/example.conf"]
```

This avoids the common Kubernetes error where arguments are treated as executables.
---
Deploy using Kustomize:

- Kustomize is included even in its minimal form:
```yaml
resources:
  - deployment.yaml
```
This enables a clean, modern deployment workflow:
```bash
kubectl apply -k k8s
```
---
**Running Locally on Kubernetes(kind)**
Because kind runs its own container runtime, the image must be loaded explicitly:
```bash

kind load docker-image process-supervisor:local --name kind
kubectl apply -k k8s
kubectl rollout restart deployment process-supervisor
```
Check status:
```bash
kubectl get pods
kubectl logs -l app=process-supervisor -f
```
---
**TROUBLESHOOTNG NOTES (Real Debugging)**

This project intentionally went through real failure modes,thus ensuring quality,
those include:

- ImagePullBackOff → fixed by loading images into kind

- RunContainerError → fixed by installing missing system dependencies

- exec: "start" error → fixed by explicit command + args

**Permission issues, fixed via chmod at build time**
---
## Author

Dimitrios Dalaklidis is an aspiring backend developer with a strong academic foundation in Informatics and hands-on experience spanning systems programming, containerization, and cloud infrastructure. His work reflects a methodical approach to problem-solving, building expertise from foundational Linux systems through Docker containerization to Kubernetes orchestration.His technical background includes low-level system operations in C, object-oriented application design in Java, process supervision and automation in Bash, and Python scripting for service workloads. Recent projects demonstrate practical experience with container lifecycle management, PID 1 signal handling, Kubernetes deployment patterns, and debugging common failure modes in distributed systems—skills developed through deliberate progression from bare metal implementations to cloud-native deployments.His technical interests center on backend system design, infrastructure reliability, and the construction of maintainable, production-ready software. He actively pursues opportunities to expand his expertise through both academically driven projects and independent research, with particular focus on containerized workloads, orchestration platforms, and the operational aspects of deploying resilient systems that adhere to modern DevOps and software engineering principles.
