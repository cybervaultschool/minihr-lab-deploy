# MiniHR Lab — Part 2: run it yourself

In Part 1 you connected **someone else's** MiniHR to **your** Entra tenant. The
system was mine, the directory was yours, and the two had to be introduced —
which is why there was a consent screen.

Part 2 removes the introduction. The virtual machine, the application and the
directory all end up in **your** tenant. When everything lives in one tenant, the
machine can ask Azure for a Microsoft Graph token *because it is that machine* —
no client secret, no federated credential, no consent screen.

By the end you will have deployed a real service, given it an identity, and
provisioned users into your own directory with **nothing to rotate** in the
provisioning path.

## The one secret you will still have, and why

You will create exactly one client secret, for **signing in to the web app**.
That is not an oversight — it is the lesson.

|                        | Signing in (you, in a browser) | Provisioning (the worker, at 3am) |
| ---------------------- | ------------------------------ | --------------------------------- |
| Permission type        | Delegated                      | Application                       |
| Who is present         | A human                        | Nobody                            |
| How it proves identity | Client secret                  | The machine it runs on            |
| What expires           | The secret                     | Nothing                           |

Notice which column had to have a secret. Being able to say *why* is the point
of the exercise.

## Getting it

```bash
git clone https://github.com/cybervaultschool/minihr-lab-deploy.git minihr-lab
cd minihr-lab
```

You clone this twice: once on your own machine, to run the `azure/` scripts,
and once on the VM you are about to build. The repository is public precisely
so that second clone needs no credential — a lab about not storing secrets
should not begin by having you store one on a virtual machine.

## Order of work

| Step | Script | What it does |
| ---- | ------ | ------------ |
| 0 | `azure/00-preflight.sh` | Checks your subscription, roles, quota and region **before** creating anything |
| 1 | `azure/01-create-vm.sh` | Resource group, VM with a system-assigned identity, firewall, auto-shutdown, budget alert |
| 2 | *(instructor)* | Your hostname is pointed at the VM's IP |
| 3 | `azure/02-grant-graph.sh` | Grants the machine's identity `User.ReadWrite.All`, then waits until it is real |
| 4 | `azure/03-signin-app.sh` | Registers the sign-in application and its one secret |
| 5 | `vm/bootstrap.sh` | On the VM: Docker, generated secrets, certificate, start |
| 6 | `vm/healthcheck.sh` | Proves each layer separately, so a failure names itself |
| 7 | `azure/99-destroy.sh` | **Deletes everything.** Not optional — it is what stops the bill |

Run them in order. Every script is safe to run twice.

## Before you start

* An Azure subscription you can create resources in
* **Global Administrator** in the same tenant (Privileged Role Administrator is
  enough for step 3, but you need to create app registrations too)
* `az` CLI signed in: `az login --tenant <your-tenant-id>`
* The hostname your instructor assigned you

Run `azure/00-preflight.sh` first. It checks all of the above and refuses to go
on if something is missing, which is much cheaper than finding out in step 5.

## Cost

A B2s VM is roughly USD 30/month **if left running**. Auto-shutdown stops the
compute every evening, but a stopped VM still has a disk and a public IP.

**The only thing that stops the bill entirely is `azure/99-destroy.sh`.** Run it
when the lab is finished, then run it again a day later to confirm the resource
group is really gone.
