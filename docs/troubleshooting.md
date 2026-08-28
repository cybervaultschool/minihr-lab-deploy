# When it does not work

Find the first thing that is false and fix that one. A later layer cannot work
while an earlier one is broken, so the first failure is usually the only real
one — everything after it is an echo.

`bash vm/healthcheck.sh` tests them in order for you.

---

## The terminal

**`'head' is not recognized` / `'uname' is not recognized` / `'bash' is not
recognized`**
You are in PowerShell or Command Prompt. Every script in this lab is a bash
script and none of them will run there. Close it, open **Git Bash** from the
Start menu, and start again from the top.

This one is worth catching early: `git`, `az` and `ssh` all exist in PowerShell
too, so a tool check can pass there and leave you failing much later on
something that looks unrelated.

**A script runs but every line errors with `
`**
The file has Windows line endings. Re-clone rather than repairing it — this
repository sets `.gitattributes` to prevent it, so a file with CRLF means it
was copied rather than cloned.

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

**"No supported size is available to you"**
Offers restrict which VM sizes you may create, and it varies by region.
`Standard_D2as_v7` is recent and not everywhere yet. Preflight tries older
equivalents and tells you which one works — pass that one on:

```bash
./azure/00-preflight.sh --location westeurope
./azure/01-create-vm.sh --location westeurope --size Standard_D2as_v6
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

**`AADSTS650051: ... has been removed or is configured to use an incorrect
application identifier`**
The ID in your sign-in configuration is not an app registration. Almost always
it is the **managed identity's** client ID, used where the sign-in
application's was wanted.

They are different kinds of object. An app registration can sign a person in,
because there is a credential a browser flow can use. A managed identity
cannot — it has no credential at all, which is exactly why it is good for
provisioning and useless for sign-in. Entra reports the mismatch as a missing
application, because as far as sign-in is concerned there is no such
application.

Check which one you have:

```bash
az ad sp show --id <the-id-from-the-error> --query "{name:displayName, type:servicePrincipalType}" -o yaml
```

`type: ManagedIdentity` means you have the wrong one. The right one is printed
by `03-signin-app.sh`, and you can find it again with:

```bash
az ad app list --display-name "MiniHR Lab sign-in" --query "[0].appId" -o tsv
```

**Sign-in works but the app says the tenant is wrong**
`MICROSOFT_TENANT_ID` in `.env` must be your tenant, not `common`. A
single-tenant registration will not accept `common`.

---

## Employee numbers

**"An account in the directory already carries this employee number, but it is
someone else"**
Working as intended, and worth understanding. Part 1 stamped employee numbers
onto accounts in your tenant; your own MiniHR numbers from the same starting
point and has no way to know that. The number you gave this employee belongs to
somebody else's account.

Either give this employee a number nothing is using, or clear the number from
the account that holds it:

```bash
MSYS_NO_PATHCONV=1 az rest --method GET --url "https://graph.microsoft.com/v1.0/users?\$select=displayName,userPrincipalName,employeeId" --query "value[?employeeId!=null]" -o table
MSYS_NO_PATHCONV=1 az rest --method PATCH --url "https://graph.microsoft.com/v1.0/users/<object-id>" --headers "Content-Type=application/json" --body '{"employeeId":null}'
```

Before this check existed, MiniHR linked them silently and reported success.

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

**`permission denied while trying to connect to the Docker API at
unix:///var/run/docker.sock`**
Not a broken installation. `bootstrap.sh` added you to the `docker` group, and
group membership is only applied when a session starts — so the shell you are
already in does not have it.

Either put `sudo` in front of every `docker` command for now:

```bash
sudo docker compose --env-file .env up -d
```

or start a fresh session, after which you will not need `sudo` again:

```bash
exit
ssh azureuser@<your-vm-ip>
```

This one is worth noticing rather than working around, because a command that
silently did nothing is worse than one that failed: if an earlier `docker
compose up -d` hit this, your containers are still running the old
configuration while the file on disk shows the new one.

**A container is `exited`**

```bash
docker compose --env-file .env logs <service> | tail -50
```

`migrate` exiting **0** is correct — it applies migrations and stops. Any other
service exiting is a real failure.

**Out of memory**
The lab's VM size has 8 GB, which is comfortable for Postgres, the app, the
worker and Caddy together. If you dropped to a smaller size to get around an
availability problem, that is the likely cause.

**The build fails, or the machine seems to freeze during it**
Compiling the application is the heaviest thing that happens on this VM.
`bootstrap.sh` adds 2 GB of swap first for that reason — check it is there:

```bash
swapon --show
free -h
```

If the build was killed with no useful error, that is the kernel out-of-memory
killer, which does not explain itself. Confirm the VM has 8 GB (`free -h`), and
if you built before the swap existed, just run `bash vm/bootstrap.sh` again.

**The build is very slow**
Expected on two cores: it is compiling a whole application. Let it finish — the
result is cached, so you pay this once. If you fell back to a **B-series** size,
it will be slower again: those are burstable, and a long build exhausts the CPU
credits they run on.

---

## Money

**Is it still costing me anything?**

```bash
az group show -n rg-minihr-lab
```

If that returns anything but `ResourceGroupNotFound`, yes. A deallocated VM
still has a disk and a public IP, and both are billed. `./azure/99-destroy.sh`
is the only thing that stops it.
