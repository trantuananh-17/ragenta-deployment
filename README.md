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
├── staging.conf           staging vhosts: staging[-<name>].ragenta.cloud -> loopback ports
├── production.conf        the same shape without the prefix; landing is the apex
└── default-deny.conf      444 for any host we do not serve
scripts/
└── dev-infra-tunnel.ps1
docs/
├── dev-infra.md           runbook
└── vm-access.md           who logs in as what, and how to rotate the deploy key
```

## Staging and production

`environments/staging` runs two deployables that release independently. `ragenta-backend` supplies
`api` and `worker` — the same image with different commands — and `ragenta-landing-page` supplies
`landing`. Alongside them sit this environment's own PostgreSQL, Redis, MinIO and Qdrant, which
publish no host ports, so the datastores are reachable only from inside the stack and cannot be
confused with another environment's data.

`landing` gets an explicit `environment:` block rather than the shared `env_file`. It is the most
exposed container in the stack and needs four public values; giving it the whole `.env` would hand
a marketing site the database password, the Stripe key and every provider credential.

`environments/production` is the same file with production defaults in its `.env.example` — docs
off, its own URLs, and a blank `IMAGE_TAG` because nothing has been released to it. The two compose
files are deliberately identical in shape: a difference between them is a difference that would
only be discovered in production.

Each application repository drives its own releases: a `vX.Y.Z` tag (or `vX.Y.Zrc*` for staging)
builds an image, rewrites **only that repository's** `IMAGE_TAG_*` line in the VM's `.env`, and
brings up only the services it owns. `ragenta-backend` pins `IMAGE_TAG_BACKEND`, runs
`docker compose run --rm api node dist/db/migrate.js` first because it owns the schema, and
recreates `api worker`. `ragenta-landing-page` pins `IMAGE_TAG_LANDING_PAGE`, runs no migration,
and recreates `landing`. Neither can move the other's version. Rolling back is re-running that
repository's `deploy.yml` with the previous tag.

## Hostnames

One rule, both environments. The hostname is the repository name with the `ragenta-` prefix
dropped: `ragenta-backend` is served at `backend`. Staging adds a `staging-` prefix, production
uses the bare name, and the marketing site is the **root of its environment** rather than a named
host — `staging.ragenta.cloud` on staging, the apex `ragenta.cloud` in production.

| Repository | Staging | Production |
| --- | --- | --- |
| `ragenta-landing-page` | `staging.ragenta.cloud` | `ragenta.cloud` (+ `www` redirect) |
| `ragenta-backend` (api) | `staging-backend.ragenta.cloud` | `backend.ragenta.cloud` |
| `ragenta-content-backend` | `staging-content-backend.ragenta.cloud` | `content-backend.ragenta.cloud` |
| `ragenta-frontend` | `staging-frontend.ragenta.cloud` | `frontend.ragenta.cloud` |
| `ragenta-admin-frontend` | `staging-admin-frontend.ragenta.cloud` | `admin-frontend.ragenta.cloud` |

Each environment still gets its own machine and its own secrets (ADR-010), but they now share one
registrable domain, and that costs two things. `AUTH_COOKIE_DOMAIN` stays **empty** in both — the
only value spanning an environment's own hostnames is `ragenta.cloud`, which spans the other
environment too. And neither service carries a `*.ragenta.cloud` CORS default any more, because
that pattern matches the other environment's origins; `TRUSTED_ORIGINS` lists exact hostnames.

If two environments ever share a machine, they need different `API_PORT` values and the second one
needs a `HEALTH_URL` variable on its GitHub Environment — the deploy's health check defaults to
port 8080.

## Shared development infrastructure

`environments/dev-infra` runs PostgreSQL, Redis, MinIO and Qdrant on a Linux VM so that no
developer has to keep a local Docker stack running. It runs no application container: the API and
worker still run from `ragenta-backend` on the developer machine.

```bash
git clone <this repo> /srv/ragenta-deployment
cd /srv/ragenta-deployment/environments/dev-infra
cp .env.example .env      # fill every blank
docker compose up -d
```

Ports bind to `127.0.0.1` on the VM by default and are reached through an SSH tunnel:

```powershell
.\scripts\dev-infra-tunnel.ps1 -VmHost <vm-ip> -User <admin user>
```

Full instructions, the direct-IP alternative and its firewall requirements, migrations, backup
and restore: [`docs/dev-infra.md`](docs/dev-infra.md). Who logs in as what, and how to rotate the
deploy key: [`docs/vm-access.md`](docs/vm-access.md).

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
