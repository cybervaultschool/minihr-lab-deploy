# MiniHR Lab — Part 2: run it yourself

In Part 1 you connected **someone else's** MiniHR to **your** Entra tenant. The
system was mine, the directory was yours, and the two had to be introduced —
which is why there was a consent screen.

Part 2 removes the introduction. The virtual machine, the application and the
directory all end up in **your** tenant. When everything lives in one tenant, the
machine can ask Microsoft Graph for a token *because it is that machine* — no
client secret, no federated credential, no consent screen.

---

## Start here

**Follow this page.** It is the whole lab, in order, with the commands you run
and what you should see after each one.

Two other documents, for when you want them:

| | |
| --- | --- |
| [docs/lab-guide-part-2.md](docs/lab-guide-part-2.md) | The same steps with the reasoning — what each one creates, what to go and look at in the portal, and the comparison exercise at the end. Read this if you want to understand it rather than just complete it. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | When something fails. Organised by which layer broke. |

---

## Getting it

```bash
git clone https://github.com/cybervaultschool/minihr-lab-deploy.git minihr-lab
cd minihr-lab
```

You clone this twice: once on your own machine, to run the `azure/` scripts, and
once on the VM you are about to build. The repository is public precisely so
that second clone needs no credential — a lab about not storing secrets should
not begin by having you store one on a virtual machine.

---

## What you need

* An Azure subscription you can create resources in
* **Global Administrator** in the same tenant — and if your role is *eligible*
  through PIM, activate it, because eligible is not active
* The `az` CLI, signed in: `az login --tenant <your-tenant-id>`
* The hostname your instructor assigned you

Step 0 checks all of this and refuses to continue if something is missing.

---

## Values you will collect

Keep this open. Each step fills in a line, and later steps need them.

```
Hostname       ______________________________   (from your instructor)
VM public IP   ______________________________   (step 1 prints it)
Client ID      ______________________________   (step 3 prints it)
Tenant ID      ______________________________   (step 3 prints it)
```

---

## Step 0 — Days before the class

Two things to do now. Both take minutes now and cost the whole session if left
until the day.

### 0a. Check that you can do the lab at all

On your own machine:

```bash
az login --tenant <your-tenant-id>
./azure/00-preflight.sh
```

This creates nothing. It only checks the things that can stop you:

* your subscription is active and has credit left
* you are **Global Administrator** — and if PIM says you are *eligible*,
  activate the role, because eligible is not active
* your tenant allows you to register applications
* a 4 GB VM size is actually offered to you **in your region**, with quota

**What you should see:** `Ready. Nothing has been created yet.`

**If a check fails, message your instructor the same day.** Two of them — an
expired subscription, and a tenant that blocks app registrations — cannot be
fixed while the class is running.

### 0b. Ask for your hostname

Send your instructor a short label for yourself, such as `student01`. They will
reply with a hostname like `student01.lab.fortisentinel.org`.

You need it because your MiniHR has to be reachable over HTTPS — Entra will not
send a sign-in back to a plain `http://` address — and a certificate is issued
against a name, not an IP. Your instructor owns the domain those names come
from, so they issue yours.

Write it on the list above. **Step 3** needs it, and in **Step 1** you send
them your VM's IP address so they can point the name at it.

---

## Step 1 — Build the machine

```bash
./azure/01-create-vm.sh
```

Two or three minutes.

> **What you should see:** a public IP address and a *machine identity* GUID.
> Write both down. **Send the IP to your instructor** — they need it to point
> your hostname at you.

That GUID is a new service principal in your directory representing this
machine. Look it up while you wait: **Entra admin center → Enterprise
applications → All applications → Application type: Managed Identities**. Open
it and look for *Certificates & secrets*. There isn't one.

---

## Step 2 — Give the machine permission

```bash
./azure/02-grant-graph.sh
```

> **What you should see:** `Granted.`, then a row of dots, then
> `visible in the directory`.

The dots are the script waiting for Entra to agree with itself. The permission
exists the moment the call returns, and the token service can take minutes to
catch up — testing during that gap fails in a way that looks exactly like a
missing permission. Let it wait.

---

## Step 3 — Register the sign-in application

```bash
./azure/03-signin-app.sh --hostname <your-hostname>
```

> **What you should see:** an application ID and a tenant ID printed, and the
> client secret written to `.signin-secret` — **not** printed. Write down the two
> IDs.

This is the one secret in the lab. It is written to a file rather than shown
because a secret echoed to a terminal lives in your scrollback, your screenshots
and your shell history.

---

## Step 4 — Start it

Wait for your instructor to confirm your hostname points at your IP.

```bash
scp .signin-secret azureuser@<your-vm-ip>:~/signin-secret
ssh azureuser@<your-vm-ip>
```

Then, **on the VM**:

```bash
git clone https://github.com/cybervaultschool/minihr-lab-deploy.git minihr-lab
cd minihr-lab

export MINIHR_HOSTNAME=<your-hostname>
export MICROSOFT_CLIENT_ID=<from step 3>
export MICROSOFT_TENANT_ID=<from step 3>

bash vm/bootstrap.sh
```

> **What you should see:** images pulled, containers started, and your URL.

If it says your hostname does not resolve yet, that is the script protecting
you — starting early burns Let's Encrypt attempts for that name, and enough
failures lock you out for the rest of the day. Wait and run it again.

---

## Step 5 — Prove it works

```bash
bash vm/healthcheck.sh
```

Five checks, in order: containers, certificate, sign-in configuration, whether
the worker can get a token, and whether that token carries the permission.

> **What you should see:** every line `[ ok ]`, ending with
> `Everything answers.`
>
> `ROLES  NONE` means the grant from step 2 has not propagated yet. Wait a few
> minutes, run it again.

Work down from the **first** failure. A later layer cannot work while an
earlier one is broken, so anything after the first failure is an echo of it.

---

## Step 6 — Use it

Open `https://<your-hostname>`, sign in with your Entra account, create an
organization, then open **Entra Integration** and choose
**Use this machine's managed identity**.

Notice what you are not asked for: no tenant ID, no client ID, no secret, no
consent screen. Click **Test connection**, then run a **Joiner** exactly as you
did in Part 1.

> **What you should see:** a real user account appear in your own directory.

---

## Step 7 — Take it down

**Not optional.** Auto-shutdown stops the compute; it does not stop the bill. A
stopped VM still has a disk and a public IP, and both are charged.

```bash
./azure/99-destroy.sh
```

Then, later that day:

```bash
az group show -n rg-minihr-lab
```

> **What you should see:** `ResourceGroupNotFound`. Anything else is still
> costing you money.

---

## The one secret you kept, and why

| | Signing in (you, in a browser) | Provisioning (the worker, at 3am) |
| --- | --- | --- |
| Permission type | Delegated | Application |
| Who is present | A human | Nobody |
| How it proves identity | A client secret | Being the machine |
| What expires | The secret, in a year | Nothing |

Both are in your tenant. Both call the same API. Only one of them put an
appointment in somebody's calendar.

Being able to say *why* that column needed a secret — and the other did not —
is the point of the exercise. [The guide](docs/lab-guide-part-2.md#part-7--the-comparison)
works through it.

---

## When it breaks

[docs/troubleshooting.md](docs/troubleshooting.md), organised by which layer
failed. The three that catch most people:

* **Sign-in fails with a redirect URI error** — the registered URI and the one
  sent must match exactly, including scheme and no trailing slash
* **`ROLES  NONE`** — the permission has not propagated; this is not a 403 and
  should not be debugged like one
* **You rebuilt the VM** — it has a *new* identity, so re-run
  `./azure/02-grant-graph.sh`
