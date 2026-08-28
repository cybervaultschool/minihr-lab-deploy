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

**Run every command from this page.** It is the whole lab, in order.

[docs/lab-guide-part-2.md](docs/lab-guide-part-2.md) explains what each step
creates and why, and has two portal exercises. It is **not a second checklist** —
do not run commands from it. This page tells you when to open it, and those
moments are deliberately placed where you would otherwise be waiting.

[docs/troubleshooting.md](docs/troubleshooting.md) is organised by which layer
failed. Go there when something does not match a **What you should see**.

---

# Before class

**Do this days ahead.** All of it is on your own laptop, and it takes about
twenty minutes. Leaving it to the day is how people lose the session.

## 1. Install the tools

You need four things: **git**, the **Azure CLI**, **ssh** and **scp**. How many
downloads that is depends on your machine.

### Windows — two downloads

1. **[Git for Windows](https://git-scm.com/download/win)** — accept the
   defaults. This is three of the four tools in one: it installs `git`, and it
   gives you **Git Bash**, which is the terminal you will use, and which brings
   `ssh` and `scp` with it.
2. **[Azure CLI](https://aka.ms/installazurecliwindows)** — the MSI installer.

Then open **Git Bash** from the Start menu, and use it for everything in this
lab. **PowerShell and `cmd` cannot run these scripts** — every one of them is a
bash script, and the failure if you try is confusing rather than obvious.

### macOS

```bash
xcode-select --install          # git, if you do not already have it
brew install azure-cli
```

`ssh` and `scp` are already there. If you do not have Homebrew, the Azure CLI
also has a [macOS installer](https://aka.ms/installazuremacos).

### Linux (Ubuntu or Debian)

```bash
sudo apt update && sudo apt install -y git openssh-client
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

### First, check you are in the right terminal

Do this before anything else. It is one command:

```bash
uname -s
```

> **What you should see:** `MINGW64_NT-…` on Windows, `Darwin` on macOS,
> `Linux` on Linux.
>
> **If you see `'uname' is not recognized...`** you are in PowerShell or
> Command Prompt. Close it and open **Git Bash** from the Start menu. Do not
> continue in PowerShell — `git`, `az` and `ssh` all exist there, so the next
> check would pass and you would fail three steps later, on a script that
> cannot run at all.

### Then check the four tools

```bash
git --version
az version
ssh -V
command -v scp
```

> **What you should see:** three versions and a path, none of them
> `command not found`.
>
> **On Windows, if `az` is not found:** close Git Bash and open it again —
> installers change your PATH and an already-open terminal does not notice. If
> it is still missing, try `az.cmd --version`; when that works, use `az.cmd`
> wherever these instructions say `az`.

## 2. Clone this repository

```bash
git clone https://github.com/cybervaultschool/minihr-lab-deploy.git minihr-lab
cd minihr-lab
```

You will clone it **twice**: here, to run the `azure/` scripts, and later on the
VM you build. It is public so that second clone needs no credential — a lab
about not storing secrets should not begin by having you store one on a server.

## 3. Check that you can do the lab at all

```bash
az login --tenant <your-tenant-id>
./azure/00-preflight.sh
```

This creates nothing. It checks the things that can stop you:

* your subscription is active and has credit left
* you are **Global Administrator** in Entra — and if PIM says you are
  *eligible*, activate the role, because eligible is not active
* your tenant allows you to register applications
* the VM size the lab uses is actually offered to you **in your region**,
  with quota for it — and if not, which alternative to pass to the next step

**What you should see:** `Ready. Nothing has been created yet.`

> **One thing it cannot check for you:** Entra Global Administrator is a
> *directory* role and says nothing about your rights over the Azure
> *subscription*. You also need to be able to create resources there —
> Contributor or Owner. They are two different permission systems that happen to
> share a login, and confusing them is the most common surprise in this lab.

**If a check fails, message your instructor the same day.** An expired
subscription and a tenant that blocks app registrations cannot be fixed while
the class is running.
## 4. Choose your hostname

Your MiniHR has to be reachable over HTTPS — Entra will not send a sign-in back
to a plain `http://` address — and a certificate is issued against a **name**,
not an IP address. So you need a name you control.

Pick a subdomain of the domain you already have in Cloudflare, for example:

```
minihr.yourdomain.com
```

Write it in your lab record. You do not create the DNS record yet — that is
Step 2, once you have an IP address to point it at. Step 4 also needs the name,
so decide it now and do not change it later: changing it means a new
certificate and a new redirect URI.

> **No domain of your own?** Tell your instructor before the class and they
> will issue you one from theirs. Everything else works the same.

---

## Your lab record

Keep this somewhere you can copy from. Four values, produced across three steps
and used later, twice on a different machine.

```
Hostname     ______________________________   you choose it, before class
VM public IP ______________________________   Step 1 prints it
Client ID    ______________________________   Step 4 prints it
Tenant ID    ______________________________   Step 4 prints it
```

> **Never write the client secret here**, or in a screenshot, or in a chat
> message. Step 4 puts it in a file for exactly that reason, and Step 5 moves
> the file. You should never see its value.

---

# In class

Each step says where it runs and roughly how long it takes.

## Step 1 — Build the machine

**On your laptop · about 3 minutes**

```bash
./azure/01-create-vm.sh
```

> **What you should see:** a public IP address and a *machine identity* GUID.
> **Record the IP** — Step 2 needs it.

You do not need to record the GUID; nothing later asks for it.

> **It is not a client ID for signing in, and there is no client ID here that
> is.** A managed identity does have one, but nothing in this lab uses it —
> the machine asks Azure for a token without naming which identity it is,
> because it can only be itself. If you put a managed identity's ID into the
> sign-in configuration in Step 4, Entra refuses with **AADSTS650051**: it is
> not an app registration, and no browser can sign in as it.

It is worth looking at while the VM finishes: **Entra admin center → Enterprise
applications → All applications → Application type: Managed Identities**. That
object is your VM. Open it and look for *Certificates & secrets*. There isn't
one.

## Step 2 — Point your hostname at it

**In the Cloudflare dashboard · about 2 minutes, then a short wait**

In your zone, **DNS → Records → Add record**:

| Field | Value |
| --- | --- |
| Type | `A` |
| Name | the subdomain part only, e.g. `minihr` |
| IPv4 address | your VM public IP from Step 1 |
| Proxy status | **DNS only — grey cloud, NOT orange** |
| TTL | Auto |

> ### Proxy status is the one that matters
> Leave it **grey**. With the orange cloud on, Cloudflare answers on its own
> addresses, so Let's Encrypt's challenge reaches Cloudflare instead of your
> machine and the certificate is never issued. The failure looks like a broken
> server rather than a wrong toggle, and people lose an hour to it.

Then check it from your own machine — a record existing and a record reaching
your resolver are different facts:

```bash
nslookup <your-hostname>
```

> **What you should see:** the IP address you recorded in Step 1.
>
> If it resolves to something else, you are seeing a cached answer or you typed
> a different address. Wait a minute and try again.

**Do not start Step 5 until this returns your address.** Certificate attempts
for a name that does not point at you are rate limited, and enough failures
will lock you out for the rest of the day.

## Step 3 — Give the machine permission

**On your laptop · 2 to 10 minutes, mostly waiting**

```bash
./azure/02-grant-graph.sh
```

> **What you should see:** `Granted.`, then a row of dots, then
> `visible in the directory`.

The dots are the script waiting for Entra to agree with itself. The permission
exists the instant the call returns, and the token service can take minutes to
catch up — testing during that gap fails in a way that looks exactly like a
missing permission.

**Do not sit and watch it.** Open a second terminal, `cd` to the same folder and
do Step 4 there; it does not depend on this finishing. If you have time spare,
this is the moment for
[the guide's comparison of a managed identity against an app registration](docs/lab-guide-part-2.md#part-2--give-the-machine-permission).

## Step 4 — Register the sign-in application

**On your laptop · about 1 minute**

```bash
./azure/03-signin-app.sh --hostname <your-hostname>
```

> **What you should see:** an application ID and a tenant ID printed, and a note
> that the client secret was written to `.signin-secret` — **not** printed.
>
> **Record the Client ID and Tenant ID.** Nothing else.
>
> **This Client ID belongs to the app registration just created — not to the
> machine identity from Step 1.** They are different kinds of object and are
> not interchangeable. The registration exists so a *person* can sign in; the
> machine identity exists so a *process* can act with nobody present.

`.signin-secret` is a file in this folder, on this laptop. Leave it exactly
where it is — Step 5 copies it to the VM and then destroys it. It is the one
secret in this lab, and it is handled as a file rather than shown because a
secret echoed to a terminal lives in your scrollback, your screenshots and your
shell history.

## Step 5 — Start it

**Starts on your laptop, then moves to the VM · about 5 minutes**

Copy the secret across, then connect:

```bash
scp .signin-secret azureuser@<your-vm-ip>:~/signin-secret
ssh azureuser@<your-vm-ip>
```

> **First connection:** you will be asked to accept the machine's fingerprint —
> type `yes`. You are not asked for a password: `01-create-vm.sh` put an SSH key
> on your laptop and the matching public key on the VM.
>
> `Permission denied` usually means you are connecting from a different network
> than in Step 1, which locked SSH to the address you had then. Re-run
> `./azure/01-create-vm.sh` — it is safe, and it re-opens the rule for where you
> are now.

> ### You are now on the VM
> **Everything until Step 8 runs there.** Your prompt changes to
> `azureuser@minihr-lab`.

Check the secret arrived, then start:

```bash
ls -l ~/signin-secret

git clone https://github.com/cybervaultschool/minihr-lab-deploy.git minihr-lab
cd minihr-lab

export MINIHR_HOSTNAME=<your-hostname>
export MICROSOFT_CLIENT_ID=<from step 3>
export MICROSOFT_TENANT_ID=<from step 3>

bash vm/bootstrap.sh
```

> **What you should see:** a DNS check passing, Docker installing, images
> pulled, containers started, and your URL.

**Got one of the values wrong?** Re-export it and run `bash vm/bootstrap.sh`
again. It keeps the passwords it generated the first time — regenerating them
would lock you out of your own database — and reuses the sign-in secret
already in `.env`, so you do not need to copy it across a second time.

## Step 6 — Prove it works

**On the VM · about 1 minute**

```bash
bash vm/healthcheck.sh
```

Five checks in order: containers, certificate, sign-in configuration, whether
the worker can get a token, and whether that token carries the permission.

> **What you should see:** every line `[ ok ]`, ending `Everything answers.`
>
> `ROLES  NONE` means the grant from Step 3 has not reached the token service.
> **Retry twice, three minutes apart.** If it is still `NONE` after that, stop
> and tell your instructor — do not keep retrying, it will not fix itself and
> something else is wrong.

Work down from the **first** failure. A later layer cannot work while an earlier
one is broken, so everything after the first failure is an echo of it.

## Step 7 — Use it

**In your browser · about 10 minutes**

Open `https://<your-hostname>`, sign in with your Entra account, create an
organization, then open **Entra Integration** and choose
**Use this machine's managed identity**.

Notice what you are not asked for: no tenant ID, no client ID, no secret, no
consent screen. Click **Test connection**, then run a **Joiner** exactly as you
did in Part 1.

> **What you should see:** a real user account appear in your own directory.

## Step 8 — Take it down

> ### Back on your own laptop
> Leave the VM first (`exit`), and run this from the folder you cloned before
> class. It will not work from the VM — the VM is what it deletes.

**Not optional.** Auto-shutdown stops the compute; it does not stop the bill. A
stopped VM still has a disk and a public IP, and both are charged.

```bash
exit                      # leaves the VM
cd path/to/minihr-lab     # on your laptop
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

Being able to say *why* that column needed a secret — and the other did not — is
the point of the exercise.
[The guide works through it.](docs/lab-guide-part-2.md#part-7--the-comparison)

---

## When it breaks

[docs/troubleshooting.md](docs/troubleshooting.md). The three that catch most
people:

* **Sign-in fails with a redirect URI error** — the registered URI and the one
  sent must match exactly, including scheme and no trailing slash
* **`ROLES  NONE`** — the permission has not propagated; this is not a 403 and
  should not be debugged like one
* **You rebuilt the VM** — it has a *new* identity, so re-run
  `./azure/02-grant-graph.sh`
