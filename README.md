# ragenta-deployment

Docker Compose stacks, environment templates and operational scripts for Ragenta.
No Kubernetes, Helm or Argo CD (ADR-008).

```text
.github/workflows/
├── check.yml              gate on every PR and push to main
└── deploy-dev-infra.yml   applies environments/dev-infra to the VM
environments/
├── dev-infra/             shared development datastores on one VM
├── staging/               released backend image + its own datastores
└── production/            same shape as staging, its own machine and secrets
proxy/
├── staging.conf           nginx in front of the staging API
└── production.conf        nginx in front of the production API
scripts/
└── dev-infra-tunnel.ps1
docs/
└── dev-infra.md           runbook
```

## Staging and production

`environments/staging` runs the released `ghcr.io/trantuananh-17/ragenta-backend:vX.Y.Z` image as
two services — `api` and `worker`, the same image with different commands — alongside its own
PostgreSQL, Redis, MinIO and Qdrant. Those datastores publish no host ports, so the stack is
reachable only through the API and cannot be confused with another environment's data.

`environments/production` is the same file with production defaults in its `.env.example` — docs
off, its own URLs, and a blank `IMAGE_TAG` because nothing has been released to it. The two compose
files are deliberately identical in shape: a difference between them is a difference that would
only be discovered in production.

`ragenta-backend`'s release pipeline drives both: a `vX.Y.Z` tag (or `vX.Y.Zrc*` for staging)
builds an image, rewrites `IMAGE_TAG` in the VM's `.env`, runs
`docker compose run --rm api node dist/db/migrate.js`, then `docker compose up -d`. Rolling back is
re-running `deploy.yml` with the previous tag.

Each environment gets its own machine, secrets and domain (ADR-010). If two ever share a machine,
they need different `API_PORT` values and the second one needs a `HEALTH_URL` variable on its
GitHub Environment — the deploy's health check defaults to port 8080.

## Shared development infrastructure

`environments/dev-infra` runs PostgreSQL, Redis, MinIO and Qdrant on a Linux VM so that no
developer has to keep a local Docker stack running. It runs no application container: the API and
worker still run from `ragenta-backend` on the developer machine.

```bash
git clone <this repo> ~/ragenta-deployment
cd ~/ragenta-deployment/environments/dev-infra
cp .env.example .env      # fill every blank
docker compose up -d
```

Ports bind to `127.0.0.1` on the VM by default and are reached through an SSH tunnel:

```powershell
.\scripts\dev-infra-tunnel.ps1 -VmHost <vm-ip> -User ubuntu
```

Full instructions, the direct-IP alternative and its firewall requirements, migrations, backup
and restore: [`docs/dev-infra.md`](docs/dev-infra.md).

## CI

`check.yml` runs on every pull request and push to `main`: no real `.env` is tracked, every
Compose file renders, every variable it interpolates is documented in the matching `.env.example`,
and the operator scripts parse.

`deploy-dev-infra.yml` pulls this repository on the development VM and reconciles the containers
when `environments/dev-infra/**` changes on `main`, or on manual dispatch. It reads
`SSH_HOST`, `SSH_USER`, `SSH_KEY` and the `DEPLOY_PATH` variable from the `dev-infra` GitHub
Environment, and self-skips with a notice while they are unset — so it is harmless before a VM
exists. The VM's own `.env` is never touched by a deploy.

## Rules

- Only `.env.example` is committed. Real `.env` files and secrets live on the VM.
- Staging and production are fully isolated from each other and from dev-infra (ADR-010).
- Environments pin exact image tags; `latest` is never what staging or production runs.
- Migrations are an explicit deploy step owned by `ragenta-backend`, never a container entrypoint.
