# Shared development infrastructure on a VM

One Linux VM runs PostgreSQL, Redis, MinIO and Qdrant for development, so no developer has to
keep a local Docker stack running. Applications are **not** deployed here — `pnpm dev:api` and
`pnpm dev:worker` still run on the developer machine and connect over the network.

This is not staging. Staging and production are separate, isolated stacks (ADR-010); never point
either of them at this box, and never put customer data on it.

## 1. Prepare the VM

Ubuntu 22.04/24.04, 2 vCPU / 4 GB RAM is enough to start (Qdrant and PostgreSQL are the memory
consumers).

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # log out and back in
```

## 2. Clone and configure

```bash
git clone <ragenta-deployment remote> ~/ragenta-deployment
cd ~/ragenta-deployment/environments/dev-infra
cp .env.example .env
```

Fill every blank in `.env`. Generate each secret separately:

```bash
openssl rand -base64 32
```

`.env` stays on the VM — it is gitignored and must never be committed.

## 3. Start it

```bash
docker compose up -d
docker compose ps
```

Verify:

```bash
docker compose exec postgres pg_isready -U ragenta -d ragenta
docker compose exec redis redis-cli -a "$REDIS_PASSWORD" ping
```

## 4. Choose how the dev machine reaches it

### Option A — SSH tunnel (default, recommended)

`BIND_ADDRESS=127.0.0.1` means the ports are published only on the VM's loopback, so nothing is
reachable from the internet. The dev machine forwards them over SSH:

```powershell
# from ragenta-deployment on Windows
.\scripts\dev-infra-tunnel.ps1 -VmHost <vm-ip> -User ubuntu
```

Equivalent raw command on any platform:

```bash
ssh -N -L 5432:127.0.0.1:5432 -L 6379:127.0.0.1:6379 \
       -L 9000:127.0.0.1:9000 -L 9001:127.0.0.1:9001 \
       -L 6333:127.0.0.1:6333 ubuntu@<vm-ip>
```

The backend's `.env` then keeps its `localhost` URLs — only the passwords change:

```dotenv
DATABASE_URL=postgresql://ragenta:<POSTGRES_PASSWORD>@localhost:5432/ragenta
REDIS_URL=redis://:<REDIS_PASSWORD>@localhost:6379
```

Stop the local stack first (`docker compose down` in `ragenta-backend`) or the ports clash.

### Option B — direct IP

Only with a firewall that allowlists the developer addresses. Set `BIND_ADDRESS=0.0.0.0` in
`.env`, `docker compose up -d`, and open the ports to specific sources only:

```bash
sudo ufw default deny incoming
sudo ufw allow OpenSSH
for port in 5432 6379 9000 9001 6333; do
  sudo ufw allow from <your-public-ip> to any port $port proto tcp
done
sudo ufw enable
```

Cloud provider security groups have to allowlist the same addresses — `ufw` alone is not enough
on most providers.

Then point the backend at the VM:

```dotenv
DATABASE_URL=postgresql://ragenta:<POSTGRES_PASSWORD>@<vm-ip>:5432/ragenta
REDIS_URL=redis://:<REDIS_PASSWORD>@<vm-ip>:6379
```

Never leave these ports open to `0.0.0.0/0`. Postgres, Redis and Qdrant on a public IP are
scanned and compromised within hours.

## 5. Run migrations

Migrations are owned by `ragenta-backend` and stay an explicit step. From the dev machine, with
the tunnel or direct connection configured:

```bash
pnpm db:migrate
```

## Operations

```bash
docker compose logs -f postgres        # follow one service
docker compose restart redis
docker compose down                    # stop, keep data
docker compose down -v                 # stop and DELETE all volumes
docker compose pull; docker compose up -d   # update images
```

Backup PostgreSQL before anything destructive:

```bash
docker compose exec -T postgres pg_dump -U ragenta ragenta | gzip > ~/ragenta-$(date +%F).sql.gz
```

Restore:

```bash
gunzip -c ~/ragenta-<date>.sql.gz | docker compose exec -T postgres psql -U ragenta -d ragenta
```

## Known limitations

- Images are unpinned (`latest` for MinIO and Qdrant). Pin them to the digests the VM is actually
  running once the ingestion module depends on their behaviour.
- No automated backups. `pg_dump` above is manual; add a cron job when the data starts mattering.
- No TLS on any of these ports. That is exactly why the default is loopback plus an SSH tunnel.
