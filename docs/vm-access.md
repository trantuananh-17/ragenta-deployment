# VM access

Two identities, on purpose. Neither one can do the other's job.

| | `<admin user>` | `ragenta-deploy` |
| --- | --- | --- |
| Who uses it | a person, or an agent acting for one | GitHub Actions only |
| sudo | yes | **no** — verified, `sudo` refuses |
| Groups | `sudo`, `docker` | `docker` only |
| Key | `~/.ssh/ragenta-dev` on the operator's machine | `~/.ssh/ragenta-deploy`, and the `SSH_KEY` secret |
| Key options | none | `no-port-forwarding,no-agent-forwarding,no-X11-forwarding` |
| Use it for | nginx, systemd, apt, provisioning, reading `.env` | `git pull`, `docker compose`, nothing else |

The deploy key is in GitHub Secrets; the admin key never is. That is the whole
point of the split: a leaked `SSH_KEY` can be rotated by rewriting one file on
the VM, without touching how people log in.

**`docker` group is still root-equivalent.** A member can mount `/` into a
container. So this separates identities and limits accidents — it is not a
sandbox. Treat both keys as privileged.

## Where things live

```text
/srv/ragenta-deployment/          the clone, owned by ragenta-deploy
├── environments/dev-infra/       datastores for developer machines
│   └── .env                      0600, ragenta-deploy — every dev password
└── environments/staging/         the released image + its own datastores
    └── .env                      0600, ragenta-deploy
/etc/nginx/sites-enabled/         ragenta-staging -> the API on 127.0.0.1:8080
```

It lives in `/srv`, not in anyone's home directory, so no person's account owns
the deployment and deleting a user cannot take it with them.

## Connecting

```bash
# admin: provisioning, nginx, reading .env
ssh -i ~/.ssh/ragenta-dev <admin user>@<host>

# what CI does — only to reproduce a deploy failure by hand
ssh -i ~/.ssh/ragenta-deploy ragenta-deploy@<host>
```

Accept the host key on first use only after checking the fingerprint against the
one recorded for this VM.

## Reaching the datastores from a developer machine

Nothing but SSH is open to the internet; every datastore binds `127.0.0.1` on
the VM. Forward what you need:

```powershell
.\scripts\dev-infra-tunnel.ps1 -VmHost <host> -User <admin user>
```

Then `ragenta-backend`'s `.env` keeps `localhost` URLs. See
[`dev-infra.md`](dev-infra.md).

## Running a script on the VM from Windows

PowerShell adds a BOM and CRLF when piping text into `ssh`, and `bash` fails on
the first line with `$'\r': command not found`. Copy the file, then run it:

```powershell
$s = @'
set -euo pipefail
...
'@
[IO.File]::WriteAllText($p, ($s -replace "`r",""), (New-Object Text.UTF8Encoding $false))
scp -i $key $p <user>@<host>:/tmp/script.sh
ssh -i $key <user>@<host> 'bash /tmp/script.sh'
```

## Rotating the deploy key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ragenta-deploy-new -N "" -C "ragenta-deploy"
# as the admin user, replace the single line in the deploy user's file:
sudo tee /home/ragenta-deploy/.ssh/authorized_keys <<< \
  'no-port-forwarding,no-agent-forwarding,no-X11-forwarding <new public key>'
```

Then update the `SSH_KEY` secret on every GitHub Environment that deploys here —
`dev-infra` in this repository and `staging` in `ragenta-backend` — and run both
deploy workflows to confirm before deleting the old key file.

A secret pasted through the GitHub web form is the usual failure: a private key
must keep its LF line endings and its trailing newline, or the action reports
`handshake failed: attempted methods [none]` and never offers a key at all.
Setting it from the file avoids that:

```powershell
$k = [IO.File]::ReadAllText("$HOME\.ssh\ragenta-deploy") -replace "`r",""
if (-not $k.EndsWith("`n")) { $k += "`n" }
gh secret set SSH_KEY --env <environment> --repo <owner/repo> --body $k
```

## Do not

- Give `ragenta-deploy` sudo. If a deploy needs root, the deploy is doing
  something that belongs in provisioning.
- Put the admin key in GitHub Secrets.
- Copy a `.env` off the VM. Read the value you need over SSH and use it directly.
- Run `docker compose down -v` — that deletes the volumes, which is the data.
