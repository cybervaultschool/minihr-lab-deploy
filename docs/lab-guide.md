# MiniHR Lab — how it works, and why

### The reasoning behind each step

> **Reference, not a checklist. Run every command from the
> [README](../README.md).**
>
> The commands appear here so each one can be explained beside what it creates.
> Working from both pages is how people end up half-way through two different
> procedures. Read this when the README sends you here, or after you have
> finished.

---

## The idea

You build the machine, in your own tenant. The directory it writes to is the
same directory. And when a machine and a directory are in one tenant, the
machine can ask Azure for a Microsoft Graph token **because it is that
machine**.

No consent screen. No client secret. Nothing to rotate.

> You will still create **one** client secret, for signing in to the web app.
> That is deliberate, and [the comparison](#the-comparison) is about why. Watch
> for it.

---

## Before the day

**Do this before the class.** Every item here takes minutes now and costs the
whole session if discovered at step 5.

```bash
git clone https://github.com/cybervaultschool/minihr-lab-deploy.git minihr-lab
cd minihr-lab
az login --tenant <your-tenant-id>
./azure/00-preflight.sh
```

It creates nothing. It checks:

* your subscription exists, is **Enabled**, and has credit
* you hold **Global Administrator** or **Privileged Role Administrator** — and
  note that being *eligible* for a role through PIM is not the same as having
  activated it
* your tenant allows application registrations
* the lab's VM size is actually offered to your subscription **in your
  region**, and if not, which alternative to use
* you have vCPU quota for it

> **If any check fails, tell your instructor now.** Two of these — an expired
> subscription and a tenant that blocks app registrations — cannot be fixed
> during the lab.

Then choose a hostname — a subdomain of the domain you already have in
Cloudflare, such as `minihr.yourdomain.com`. You create the DNS record itself
once the VM exists and you have an address to point at — the README's Step 2.
If you have no domain of your own, ask your instructor to issue you one from
theirs.

---

## Building the machine

```bash
./azure/01-create-vm.sh
```

Two or three minutes. It creates a resource group, an Ubuntu VM, a firewall
that allows SSH **only from your current address**, an auto-shutdown schedule,
and — the line that matters — a VM with `--assign-identity`.

> **What you should see:** a public IP address and a *machine identity* GUID.
> Record the IP — the DNS record you create next points at it.

*Why this matters.* That GUID is a service principal in your directory. It
represents this machine. Look it up while you wait:

```
Entra admin center → Enterprise applications → All applications
  → Application type: Managed Identities → minihr-lab
```

Open it and look for **Certificates & secrets**. There isn't one. This identity
has no credential — Azure vouches for the machine directly, so there is nothing
to store and nothing to leak.

---

## Giving the machine permission

Being able to prove who you are and being allowed to do something are different
questions. The identity answers the first. This answers the second.

```bash
./azure/02-grant-graph.sh
```

> **What you should see:** `Granted.` then a row of dots, then
> `visible in the directory`.

The dots are not decoration. Entra is eventually consistent: the assignment
exists the instant the call returns, and the token service can take minutes to
agree. Testing during that gap produces a failure that looks exactly like a
missing permission. The script waits so that any failure you see afterwards is
a real one.

*Why this matters.* You just granted `User.ReadWrite.All` as an **application**
permission — the type that acts with nobody signed in. Go and look at it:

```
Enterprise applications → All applications → minihr-lab → Permissions
```

Same API. Same claim value. Same **Type: Application**. The difference is not
in what was granted; it is in what had to be kept.

---

## Registering the sign-in application

```bash
./azure/03-signin-app.sh --hostname student01.lab.fortisentinel.org
```

This one creates a client secret. It writes it to `.signin-secret` with
restrictive permissions rather than printing it, because a secret echoed to a
terminal lives in scrollback, in screenshots, and in your shell history.

> **What you should see:** an application ID, a tenant ID, and a note that the
> secret was written to a file — not the secret itself.

*Why this matters.* Signing in is a different problem from provisioning. A human
is present, a browser is redirected to Entra and back, and the application must
prove it is the application that asked. That proof happens over HTTP from a web
framework, not from Azure's metadata service — so it is a secret, and it has an
expiry date. Hold that thought until [the comparison](#the-comparison).

---

## Starting it

Make sure your hostname resolves to your VM first — `nslookup <your-hostname>`
should return the address the VM was given. In Cloudflare the record must be **DNS
only, grey cloud**: with the orange proxy on, Let's Encrypt's challenge reaches
Cloudflare rather than your machine and no certificate is ever issued.

```bash
scp .signin-secret azureuser@<your-ip>:~/signin-secret
ssh azureuser@<your-ip>
```

Then, on the VM:

```bash
git clone https://github.com/cybervaultschool/minihr-lab-deploy.git minihr-lab && cd minihr-lab
export MINIHR_HOSTNAME=student01.lab.fortisentinel.org
export MICROSOFT_CLIENT_ID=<from step 3>
export MICROSOFT_TENANT_ID=<from step 3>
bash vm/bootstrap.sh
```

`bootstrap.sh` refuses to start if your hostname does not yet resolve to this
machine. That refusal is a feature: Let's Encrypt rate-limits repeated failures
for the same name, so an impatient first start can lock you out of a
certificate for the rest of the day.

It generates the database, session and encryption secrets **on the machine**
with `openssl rand`. Nobody types them, nobody sends them, and there is no
second copy to leak.

> **What you should see:** images pulled, containers started, and a URL.

---

## Proving it, layer by layer

```bash
bash vm/healthcheck.sh
```

"It doesn't work" has at least five meanings here. This gives you one:

1. **Containers** — is anything running at all?
2. **Certificate** — does HTTPS answer, with a certificate a browser trusts?
3. **Sign-in configuration** — does the redirect URI match, exactly?
4. **Identity** — can the **worker container** get a Graph token?
5. **Permission** — does that token carry `User.ReadWrite.All`?

Check 4 runs inside the worker, not on the host. The host having an identity
and the container being able to use it are different claims, and only the
second one matters — the worker is what provisions.

> `ROLES  NONE` means the token is real but carries no permission: the grant
> from step 2 has not propagated. Wait, run it again.

---

## Connecting it to your own directory

Open `https://<your-hostname>`, sign in with your Entra account, and create an
organization.

Then **Entra Integration**. Notice what you are *not* asked for.

Choose **Use this machine's managed identity**.

* No directory (tenant) ID — the machine is already in your tenant
* No application (client) ID — the identity is not an app registration
* No client secret — there is nothing to store
* No consent screen — nobody is crossing a boundary

Click **Test connection**.

> **What you should see:** the directory answered.

Now run a **Joiner**: hire someone, watch the event, run the provisioning job,
and find the account in your directory.

---

## The comparison

This is the part to slow down for. Open both, in two tabs:

| | Sign-in application | The machine's identity |
| --- | --- | --- |
| Where | App registrations | Enterprise applications, Managed Identities |
| Permission | `User.Read`, delegated | `User.ReadWrite.All`, application |
| Who is present | You, in a browser | Nobody, at 3am |
| How it proves identity | A client secret you stored | Being the machine |
| Certificates and secrets | Has one, expiring in a year | Tab does not exist |
| When it expires | Sign-in breaks | Nothing expires |

Both are in your tenant. Both call the same API. One of them put an appointment
in someone's calendar.

**The question worth being able to answer:** the secret in the left-hand column
is not there because nobody bothered to remove it. Why does *that* column need
one, when the right-hand column does not?

> The answer is in what is present at the moment of proof. The worker runs on a
> machine Azure can vouch for. The sign-in flow happens in a browser Azure
> cannot vouch for, and the application has to prove itself over HTTP from
> wherever it happens to be running. Different problem, different mechanism.
>
> It is not permanently unavoidable — Entra can accept a signed assertion
> instead of a secret for sign-in too. Our web framework does not support that
> yet, which is the honest reason it is here.

---

## Taking it down

**Not optional.** Auto-shutdown stops the compute; it does not stop the bill. A
stopped VM still has a disk and a public IP, and both are charged.

```bash
./azure/99-destroy.sh
```

Then, later that day:

```bash
az group show -n rg-minihr-lab
```

`ResourceGroupNotFound` is the answer you want.

Notice what you did **not** have to do: revoke the managed identity's
permission. The grant was made to a principal that no longer exists, so it went
with the machine. That is the same property that made it safe to grant — an
identity that cannot outlive its resource cannot be left behind.

The client secret is different. `99-destroy.sh` deletes the sign-in application
for you, because a live secret pointing at a machine that no longer exists is
exactly the kind of leftover that becomes somebody's incident two years later.

---

## What you should be able to explain now

1. Why no consent screen was needed, and when one would be.
2. What `--assign-identity` actually created, and where to find it.
3. Why `ROLES  NONE` is a different problem from a 403.
4. Why the provisioning path has no secret but the sign-in path does.
5. What a managed identity cannot do once a second tenant is involved.
6. Why "delete the resource group" is a security step, not just a billing one.
