# When it does not work

Find the first thing that is false and fix that one. A later layer cannot work
while an earlier one is broken, so the first failure is usually the only real
one — everything after it is an echo.

`bash vm/healthcheck.sh` tests them in order for you.

---

## Before anything exists

**"Subscription state is Disabled" / no credit**
Not fixable during the lab. An expired Azure for Students credit needs a new
subscription or an upgrade, and that takes time. Tell your instructor.

**"You do not appear to hold Global Administrator"**
Two different systems share your login. Being **Owner** of an Azure
subscription says nothing about your role in the **Entra directory**, and
granting a Graph permission is a directory operation.

If your role is *eligible* through PIM, activate it — eligible is not active.
If you are in a corporate tenant, you very likely cannot do Part 2 there; use a
personal or trial tenant instead.

**"No supported 4 GB size is available to you"**
Student offers restrict which VM sizes you may create, per region. Try another:

```bash
./azure/00-preflight.sh --location westeurope
./azure/01-create-vm.sh --location westeurope --size Standard_B2als_v2
```

---

## The machine

**SSH times out**
Two likely causes. Your address changed since you ran `01-create-vm.sh`, which
opened SSH only to the address you had then — re-run it, it is safe. Or your
network blocks outbound port 22, which some campuses do; use the Azure portal's
**Serial console**, or **Run command**, both of which work over HTTPS.

**I deleted and recreated the VM**
It has a **new identity**. The old permission was granted to a principal that no
longer exists, and does not follow. Re-run `./azure/02-grant-graph.sh` — it
reads the current identity every time, which is why re-running is correct
rather than merely harmless.

---

## The certificate

**bootstrap.sh says my hostname does not resolve**
You have not created the A record yet, or DNS has not caught up. Create it in
Cloudflare — type `A`, the subdomain as the name, your VM's IP as the address,
and **proxy status DNS only (grey cloud)** — then wait and run it again. Do not work around this check — repeated certificate failures
for the same name are rate limited, and you can lock yourself out for the day.

**It resolves to a different address than this machine**
Your A record points somewhere else. Two usual causes: you rebuilt the VM and
it has a new address, or the orange proxy is on, in which case you are seeing
Cloudflare's addresses rather than yours. Turn the proxy off, and check your
current address with:

```bash
curl -s https://api.ipify.org
```

**HTTPS does not answer, and Caddy's log mentions the challenge failing**
Let's Encrypt proves you control the name by fetching a file over **port 80**.
If 80 is closed the certificate cannot be issued — and if you close it later,
renewal fails silently about sixty days on. Check the rule exists:

```bash
az network nsg rule list -g rg-minihr-lab --nsg-name minihr-labNSG -o table
```

---

## Signing in

**Sign-in fails with a redirect URI error**
The single most common failure, and always the same cause: the URI the
application sends and the URI registered in Entra differ. They must match
exactly — scheme, host, path, no trailing slash.

```
https://<your-hostname>/api/auth/callback/microsoft
```

Registered under: App registrations, your app, Authentication, Web, Redirect
URIs. `healthcheck.sh` prints what your deployment will send.

**Sign-in works but the app says the tenant is wrong**
`MICROSOFT_TENANT_ID` in `.env` must be your tenant, not `common`. A
single-tenant registration will not accept `common`.

---

## The identity

**`TOKEN  no`**
The container could not reach the instance metadata service. It is unreachable
from a laptop by design — this check only means anything on the VM.

**`ROLES  NONE`**
The token is genuine and carries no permission. Either `02-grant-graph.sh` has
not been run for **this** VM's identity, or the grant has not propagated yet.
Wait a few minutes and re-run the check. This is not a 403 and should not be
debugged like one — nothing is refusing you, the permission simply is not there
yet.

**`GRAPH  no — 403`**
The permission arrived but is not the one needed. Check the assignment is
`User.ReadWrite.All` and its type is **Application**, not Delegated.

---

## The stack

**A container is `exited`**

```bash
docker compose --env-file .env logs <service> | tail -50
```

`migrate` exiting **0** is correct — it applies migrations and stops. Any other
service exiting is a real failure.

**Out of memory**
A 2 GB VM cannot run Postgres, Next.js, a worker and Caddy together. Use a 4 GB
size; this is why `00-preflight.sh` insists on one.

**The build fails, or the machine seems to freeze during it**
Compiling the application is the heaviest thing that happens on this VM.
`bootstrap.sh` adds 2 GB of swap first for that reason — check it is there:

```bash
swapon --show
free -h
```

If the build was killed with no useful error, that is the kernel out-of-memory
killer, which does not explain itself. Confirm the VM has 4 GB (`free -h`), and
if you built before the swap existed, just run `bash vm/bootstrap.sh` again.

**The build is very slow**
B-series VMs are burstable: they accumulate CPU credits while idle and spend
them under load. A long build can exhaust them and be throttled. Let it finish
— it is cached, and you only pay this once.

---

## Money

**Is it still costing me anything?**

```bash
az group show -n rg-minihr-lab
```

If that returns anything but `ResourceGroupNotFound`, yes. A deallocated VM
still has a disk and a public IP, and both are billed. `./azure/99-destroy.sh`
is the only thing that stops it.
