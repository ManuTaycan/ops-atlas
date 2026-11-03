# Provision a Proxmox LXC with OpenTofu and recover from the first deployment failures

## Goal and applicability

Build a reproducible, disposable Linux container from configuration instead of rebuilding its operating system manually. This guide follows a real homelab case from a read-only API connection through an unsuccessful create, state inspection, network correction, ACL repair and a successful deployment.

**Completed milestone:** OpenTofu created and started one unprivileged Debian LXC on an existing Proxmox node. The operator supplied a successful apply transcript and a screenshot showing container uptime.

**Not completed:** an Ansible-managed Nginx installation, verified IPv4/SSH access to the guest, application health checks, persistent-data recovery, a durable delete-and-recreate permission model, or a one-click deployment interface. The name `nginx` describes the intended workload, not an installed service.

The accompanying [OpenTofu example](../../examples/proxmox-lxc/README.md) is a sanitized, parameterized reconstruction of the successful configuration. It is not a live connection to the original environment. Read its existing-state instructions before using it to manage an already-created container.

### Evidence and naming convention

All infrastructure names, user/token names, network names, IDs, addresses and key material in this article are fictional examples or placeholders. No original screenshot, complete terminal log, personal email address, public SSH key or token secret is included.

The operator's supplied outputs reported these versions; this is an observation, not a claim that they are the latest versions or a general compatibility certification:

| Component | Version reported in the case | Evidence and limit |
| --- | --- | --- |
| Proxmox VE UI | 9.2.10 | Visible in the supplied screenshots |
| Management OS | Ubuntu, `resolute` repositories | APT output; no independent OS inventory was collected |
| OpenTofu | 1.13.2, Linux amd64 | `tofu version` output |
| Provider | `bpg/proxmox` 0.120.0 | Successful provider installation in `tofu init` |
| Ansible Core | 2.20.1 | Installed; no application playbook was run |
| Git | 2.53.0 | Installed version output |
| Container template | Debian 13, artifact revision `13.1-2`, amd64 | Template identifier in the successful plan |

The example retains `~> 0.120.0`, allowing compatible patch releases within that constraint. Preserve the original dependency lockfile to reproduce the exact installed provider. Public documentation can describe a different provider release; do not confuse a documentation check with a test of every release.

## Symptoms and context

The initial idea involved Kubernetes, OpenTofu, Ansible and possibly a test domain controller. The actual requirement was narrower: replace a broken VM or container from a maintained blueprint, then restore its configuration and application automatically.

The first implementation therefore separated the responsibilities:

| Layer | Chosen approach | Status in this case |
| --- | --- | --- |
| Management | A Linux management VM with OpenTofu, Git and Ansible | Available |
| Infrastructure | OpenTofu and the community-maintained `bpg/proxmox` provider | One container deployed |
| Guest configuration | Ansible over SSH | Planned, not performed |
| Application | Nginx as an intentionally disposable first workload | Not installed yet |
| Deployment interface | A later job or UI, potentially Semaphore | Deferred |
| Data protection | Separate backup server and application restore process | Deferred; no recovery guarantee |
| Kubernetes / domain controller | Not needed for this first milestone | Out of scope |

The target node had limited memory, so the first workload was reduced from a full VM to an unprivileged LXC with one core, 512 MiB RAM, 256 MiB swap and an 8 GiB root disk. These are the chosen lab values, not universal sizing guidance. Existing application containers were not imported into the new OpenTofu project.

```text
Editor / SSH client
        |
        v
Linux management VM
  OpenTofu + Git + Ansible installed
        |
        | HTTPS API with a dedicated token
        v
Existing Proxmox node
  Existing bridge + existing datastores + downloaded Debian template
        |
        v
One new unprivileged LXC
  Debian running; application automation still pending
```

## Prerequisites and permissions

### Separate the execution locations

The case involved three shells. Mixing their output caused an actual configuration error.

| Location | Appropriate tasks |
| --- | --- |
| Local workstation | Open SSH / VS Code, edit repository files |
| Management Linux VM | `tofu`, `git`, `ansible`, key generation and API requests |
| Proxmox node, administrator shell | `pct`, `pveum`, inspecting bridges and storage |

A shell prompt such as `PS ...>` or `root@...#` is not a command to paste into `main.tf`. Proxmox commands must not be run on the management VM simply because both systems are Linux.

### Inventory before creating anything

On the intended Proxmox node, determine the real bridge and available storage rather than assuming `vmbr0` exists:

```bash
ip -br link
pvesm status
pct list
qm list
```

The UI paths are **Node > System > Network**, the node's storage views, and the cluster resource tree. Check VM/container ID uniqueness across the cluster, not only on this node. A datastore appearing under **Datacenter > Storage** does not prove that it is usable on the target node or has enough capacity.

For the examples below only, assume:

| Purpose | Fictional value |
| --- | --- |
| Target node | `example-pve-a` |
| Container ID | `19001` |
| Guest hostname | `example-web-a` |
| Existing Linux bridge | `vmbr-example` |
| Root filesystem datastore | `example-lvm` |
| Template datastore | `example-templates` |
| Read-only user/token | `example-audit@pve!reader` |
| Deployment user/token | `example-deploy@pve!builder` |
| API endpoint | `https://pve.example.invalid:8006/` |

None of these names is a runnable description of the original lab. Replace them with privately maintained inputs. Do not create a new bridge merely to match this example.

### Bootstrap access, not cluster-wide administration

An administrator prepares the account, token and ACLs. The deployment token should not be given `Administrator` on `/` to bypass an unexplained 403.

In the case, a dedicated audit account received `PVEAuditor` on `/` for the initial node-list test. A separate deployment account was then used. Privilege Separation was disabled for these dedicated tokens, so each inherited its user's rights. With separation enabled, both user and token ACLs must permit the operation; inspect effective token permissions, not only the GUI's user role. The secret is displayed only when generated. [1]

The successful deployment used the following scoped bootstrap pattern:

| ACL scope | Role used | Why it was included |
| --- | --- | --- |
| `/vms/19001` | `PVEVMAdmin` | Manage this designated disposable guest ID |
| `/storage/example-lvm` | `PVEDatastoreUser` | Allocate and inspect the root-disk storage |
| `/storage/example-templates` | `PVEDatastoreUser` | Access the datastore containing the template |
| `/sdn/zones/localnetwork/vmbr-example` | `PVESDNUser` | Use this local Linux bridge |

These built-in roles are broader than a custom per-operation minimum; the table records the case's working pattern, not a proof of minimal privilege. Storage permissions cover the selected datastores rather than only the new guest. For an SDN VNet, use its actual zone/VNet path instead of assuming the local-bridge path. [1][3]

For a designated disposable ID and already-existing resources, the administrator can apply the corresponding example ACLs on Proxmox:

```bash
pveum acl modify /vms/19001 \
  --users 'example-deploy@pve' --roles PVEVMAdmin
pveum acl modify /storage/example-lvm \
  --users 'example-deploy@pve' --roles PVEDatastoreUser
pveum acl modify /storage/example-templates \
  --users 'example-deploy@pve' --roles PVEDatastoreUser
pveum acl modify /sdn/zones/localnetwork/vmbr-example \
  --users 'example-deploy@pve' --roles PVESDNUser
```

A lab resource pool was created during preparation but was not assigned in the final container configuration. A pool name alone does not restrict this resource or solve its lifecycle permissions. Do not add every existing guest to the lab pool.

**Important limitation:** the per-ID ACL is removed when that container is destroyed. This becomes relevant during the replacement failure below; it prevents claiming an unattended rebuild workflow is already complete. [2]

## Solution: establish the management workflow

### 1. Install and verify the tools on the management VM

The operator installed Ansible, Git, curl, certificate tooling and the QEMU guest agent through the management VM's package manager. OpenTofu was installed from its package repository. For a new machine, follow the current [official Debian/Ubuntu installation procedure][6] rather than reusing an unverified third-party installer.

The relevant package and verification commands are:

```bash
sudo apt update
sudo apt install -y ansible git curl ca-certificates gnupg qemu-guest-agent
ansible --version
git --version
tofu version
```

The final command presumes that the OpenTofu repository installation has already been completed. Do not install automation packages directly onto the Proxmox host for this setup.

The guest-agent service printed a message that its unit could not be enabled in the usual way. That message alone did not establish whether the agent was running. Check `systemctl is-active qemu-guest-agent` and the management VM's guest-agent setting in Proxmox separately. No later output confirmed the agent state; the recorded LXC failures instead identified bridge, syntax and authorization problems.

### 2. Test reachability separately from credentials

The internal-address API request stalled and was interrupted. A private Tailscale path subsequently resolved, completed a TLS handshake and received an API response. This showed a working alternate path; it did **not** identify the cause of the internal-path timeout. No firewall change was proved necessary or carried out in the recorded sequence.

Use a timeout and inspect the HTTP status, not just a possibly empty response body:

```bash
curl --silent --show-error \
  --connect-timeout 5 --max-time 10 \
  --output /dev/null --write-out 'HTTP %{http_code}\n' \
  'https://pve.example.invalid:8006/api2/json/version'
```

The endpoint is the host base URL with port 8006, not the web UI's `#...` navigation fragment. The endpoint must be reachable from the machine actually running OpenTofu.

The observed unauthenticated request returned `401 No ticket`. That response established HTTP/API reachability but not authorization. The successful test path was private overlay-network access, not evidence that the API had been published openly on the Internet.

TLS certificate validation was bypassed with `curl -k` and `PROXMOX_VE_INSECURE=true` during diagnosis. This was a temporary workaround, not a trusted production setting. A displayed certificate issuer is not proof of successful hostname/chain validation. The case did not include a definitive later validation result, so TLS trust remains open. The provider supports endpoint, token and TLS settings through environment variables. [3]

### 3. Set session credentials without putting the token into Git

On the management VM, use the endpoint and credential format supported by the provider. This example keeps verification enabled:

```bash
export PROXMOX_VE_ENDPOINT='https://pve.example.invalid:8006/'
export PROXMOX_VE_INSECURE=false
read -rsp 'API token (USER@REALM!TOKENID=SECRET): ' PROXMOX_VE_API_TOKEN
printf '\n'
export PROXMOX_VE_API_TOKEN

if [ -n "${PROXMOX_VE_API_TOKEN:-}" ]; then
  printf 'Token is set; its validity has not yet been tested.\n'
else
  printf 'Token is missing. Stop before planning.\n'
fi
```

A token's complete input is `USER@REALM!TOKENID=SECRET`, not the secret by itself. `read -s` hides terminal echo; it does not make the value immune to inspection by privileged processes. Avoid printing the variable, enabling shell tracing, or recording verbose authenticated HTTP requests.

For a read-only API check, the following passes the header through curl's standard-input configuration instead of writing the secret literally in shell history:

```bash
printf 'header = "Authorization: PVEAPIToken=%s"\n' "$PROXMOX_VE_API_TOKEN" |
  curl --config - --silent --show-error \
    --connect-timeout 5 --max-time 10 \
    --output /dev/null --write-out 'HTTP %{http_code}\n' \
    "${PROXMOX_VE_ENDPOINT%/}/api2/json/nodes"
```

In the case, the authenticated request returned 200, then the read-only OpenTofu project returned both expected node names. A 200 response on a listing endpoint does not by itself prove every node is visible or that guest creation is authorized. A 401 points toward authentication; a 403 requires examination of the specific operation's rights. Transport/TLS failures need separate diagnosis. API-token header syntax is documented by Proxmox. [1]

### 4. Keep the read-only test in its own directory

The first project contained only the provider, a node-list data source and an output:

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.120.0"
    }
  }
}

provider "proxmox" {}

data "proxmox_virtual_environment_nodes" "cluster" {}

output "proxmox_nodes" {
  value = data.proxmox_virtual_environment_nodes.cluster.names
}
```

`tofu init` installed the provider. `tofu plan` read the nodes and proposed output values without infrastructure changes. Keep that experiment separate from the container project and switch to the deployment token when creating resources.

Repeated SSH disconnects then caused two distinct errors: first a missing endpoint, later missing credentials. The environment variables belonged to the lost shell; `tofu init` succeeding did not prove that the Proxmox credentials were present. Re-establish the variables in the new shell.

A persistent terminal was recommended as a resilience measure:

```bash
sudo apt install -y tmux
tmux new -As example-iac
```

After reconnecting, `tmux attach -t example-iac` reopens an existing session. This can preserve its processes and shell environment; it does not diagnose or repair the connection resets and does not survive every host/session failure. The case did not establish the reset's cause or confirm that tmux was actually used.

### 5. Download a real template and prepare a public SSH key

On the target node, use **Template storage > CT Templates > Templates** to download the required Debian standard template. Copy its complete volume ID from the UI. A version-looking example filename is not a substitute for a file that exists on that node.

The container's template source and root disk can use different datastores. In this case, a template-capable directory storage held the archive and LVM-thin held the new root disk. The root-disk datastore must support container storage and have capacity. [4]

On the management machine, create a dedicated SSH key only when no suitable key exists. The original case used an unencrypted private key for the lab; do not publish it or silently overwrite an existing key. For a new setup, select an appropriate passphrase/agent arrangement:

```bash
install -d -m 700 "$HOME/.ssh"
# Run only after checking that this key path is not already in use.
ssh-keygen -t ed25519 -f "$HOME/.ssh/example_lab_ed25519"
```

The `.pub` file is read by OpenTofu and provided to the container account initialization. The private key stays on the management machine. Future Ansible access still needs network reachability, an SSH service and authentication verification; providing a key is not that verification.

### 6. Use the example configuration and inspect the plan

The canonical source for the resource is [examples/proxmox-lxc/main.tf](../../examples/proxmox-lxc/main.tf). Do not maintain a second copied resource block in the article. Its companion README explains private inputs and state migration.

The resource requests the observed lab sizing, an unprivileged Debian container, DHCP on `eth0`, the actual existing bridge, the downloaded template, automatic start, and start on host boot. The successful version also enabled `nesting` after a systemd warning. Nesting changes container isolation characteristics; it is not a requirement to install Kubernetes or Docker here. Review that choice for the workload rather than enabling extra features indiscriminately. [2][4]

For a new project, run from its directory:

```bash
umask 077
tofu init
tofu fmt
tofu validate
tofu plan
```

Validate the resource address, target node, guest ID, bridge, template and disk as well as the counts. The first intended create showed `1 to add, 0 to change, 0 to destroy`. A plan is a preview, not permission to overwrite an unrelated guest. `tofu apply` without a saved plan generates a fresh plan for approval; inspect it again. Saved plan files can contain sensitive information and must stay out of this public repository. [5]

## Diagnosis and recovery of the observed failures

### Failure A: the assumed bridge did not exist

The first API create produced a guest configuration and root disk, but the start task failed because the configured bridge was absent. The administrator confirmed that the guest was stopped and that `pct config` still referenced the wrong bridge.

On Proxmox:

```bash
pct status 19001
pct config 19001
ip link show vmbr-example
```

On the management VM, in the matching OpenTofu project:

```bash
tofu state list
```

The case showed the same guest present in Proxmox and its resource address present in state. Therefore an import was not needed. The correct next step was to fix the bridge input, not delete the state, recreate the project, or alter the host's networking to accommodate a guessed name.

The create also emitted a systemd 257/nesting warning. That was separate from the explicit bridge start error. The subsequent successful configuration had nesting enabled, but the evidence does not isolate nesting as the cause of the earlier failure.

### Failure B: terminal output was pasted into `main.tf`

After another connection reset, the configuration contained the disconnect message and a Windows prompt inside `required_providers`. The provider constraint and closing structure were incomplete. OpenTofu reported invalid characters, missing separators and unsupported blocks.

This was a local text/parsing problem. Correcting HCL does not require changing the container or its permissions. Make a private backup, restore the `terraform` header, and run:

```bash
tofu fmt
tofu validate
```

The `provider`, `variable`, `resource` and `output` blocks must be outside the `terraform` block. Only copy the code itself, not shell prompts or terminal output. Do not apply a guessed rewrite while validation still fails.

### Failure C: the partially created guest was marked tainted

After the syntax repair, the plan explicitly said the container was tainted and showed a destroy-then-create replacement. OpenTofu can mark an object tainted after a failure during a multi-step create because complete initialization is uncertain. State presence therefore does not imply that the next plan will update the object in place. [7]

The operator accepted replacement only because this was a new disposable OS container with no application data. The root disk was deleted. For a valuable workload, stop and preserve data before approving replacement. `tofu untaint` is a deliberate recovery decision after verifying the object, not a general way to silence destructive plans. [7]

### Failure D: deletion succeeded, but recreate returned HTTP 403

The next operation deleted the old guest and failed during creation with `Permission check failed`. The administrator then inspected effective token permissions on all relevant paths:

```bash
pveum user token permissions example-deploy@pve builder --path /vms/19001
pveum user token permissions example-deploy@pve builder --path /storage/example-lvm
pveum user token permissions example-deploy@pve builder --path /storage/example-templates
pveum user token permissions example-deploy@pve builder --path /sdn/zones/localnetwork/vmbr-example
pct status 19001
```

The observations were specific: network use and storage permissions were present; the guest-ID path had no effective permissions; the guest configuration no longer existed. The immediate blocker was therefore the missing guest-ID authorization, not proof of a broken token or missing bridge permission.

The administrator restored `PVEVMAdmin` on the designated ID:

```bash
pveum acl modify /vms/19001 \
  --users 'example-deploy@pve' --roles PVEVMAdmin
pveum user token permissions example-deploy@pve builder --path /vms/19001
```

The later apply succeeded. No cluster-wide Administrator grant was needed.

**Why this is more than a one-off typo:** Proxmox documents that destroying a container removes its related ACLs and firewall configuration. This is consistent with the previously usable per-ID authorization disappearing after deletion. The transcript did not include an ACL audit trail, but the observed sequence and documented lifecycle behavior explain the hazard. [2]

Setting `purge_on_destroy = false` does **not** preserve those ACL entries: ACL cleanup is distinct from optional cleanup of backup, replication and HA references. A durable rebuild design must handle authorization outside the disposable object's own ACL, for example a separately reviewed pool-based delegation/bootstrap design. That design was not implemented or tested here; do not substitute blanket `/vms` administration as an undocumented shortcut. [2]

## Intended final state and verification

The supplied final apply reported one resource added, none changed and none destroyed, completing creation in approximately 22 seconds. The screenshot showed the newly named container with nonzero uptime. This establishes the infrastructure milestone, not workload availability.

The next verification commands, to be run by the operator on Proxmox, are:

```bash
pct status 19001
pct config 19001
pct exec 19001 -- ip -4 -br address show dev eth0
pct exec 19001 -- ip route
```

Expect a running unprivileged container, the selected bridge, nesting enabled and the intended disk/memory values. Inspect whether DHCP actually supplied an IPv4 address and route. In the supplied screenshot, only an IPv6 link-local address was visible; the screenshot was cropped and did not establish either successful IPv4 DHCP or its failure.

If IPv4 is absent, investigate the actual bridge's DHCP, VLAN and routing conditions before changing the template or inventing a static address. If present, test the management VM's route and SSH access using the dedicated key. API access through the host's Tailscale connection does not automatically give the management VM access to a guest on an arbitrary bridge.

A further `tofu plan` against the same authoritative state should be reviewed for convergence, but a post-success no-change plan was not supplied. Neither were SSH, Ansible or HTTP success outputs. Nginx must not be described as running yet.

## Working in Git and VS Code without losing state

Use the [example README](../../examples/proxmox-lxc/README.md) for the exact file layout and adoption checklist. A Git checkout contains configuration, not the ownership mapping in the original OpenTofu state. The repository deliberately excludes state, local variable files, plan exports and key material; treat these as private even when a public key or private address is not itself a password. State contains resource attributes and may include secrets. [8]

For the operator's existing deployment, the safest immediate editing option is VS Code **Remote - SSH** into the management machine, then **File > Open Folder** for the original working directory. This leaves the working state, local inputs and private key in place. Remote - SSH supports opening a folder and running tools on the remote host. [9]

To put the existing project under this repository later, preserve its authoritative state and `.terraform.lock.hcl`, set all parameterized inputs to their current values, use one active working directory, and review a plan before applying. Do not operate a fresh clone and the old project as independent managers of the same ID. Do not recreate the guest to solve a missing-state problem.

No real lockfile was supplied with the case, so no checksums have been invented. For the existing deployment, reuse and review the real lockfile. For a new deployment, inspect the generated lockfile before committing it. Never commit `terraform.tfstate` alongside it by accident.

## Risks, impact, and recovery

- **Replacement destroys data.** The approved replacement deleted an empty test root filesystem. Recreating the OS does not recover a database, uploads, credentials, encryption keys or application settings. A separate backup server was deferred; that is not a decision that important data can be discarded.
- **A failed apply may still have changed infrastructure.** Check both Proxmox and state after an error. A successful destroy followed by a failed create leaves the service absent; it is not an automatic transaction rollback.
- **Per-ID ACLs do not provide unattended recreation.** Restore scoped rights when diagnosing this case and redesign durable delegation before promoting the workflow. Rechecking only storage or bridge ACLs misses this failure.
- **TLS and guest networking remain incomplete checks.** Temporary certificate bypass and a running guest do not establish trusted API access or application reachability. Firewall defaults were not audited by this exercise.
- **State has one owner.** Back it up privately before migration or recovery. Do not run concurrent writers, edit state JSON by hand, or delete it to force a fresh create. Import is for controlled recovery when the real object exists but the authoritative state is unavailable, not a routine step here.
- **Reverting Git is not restoring data.** A prior `.tf` file can restore a desired configuration; it cannot undo a completed disk deletion. Stop at unexpected destroy/replace actions.

The first next milestone is verified guest networking and SSH, then an idempotent Ansible playbook to install and validate Nginx. Only after the guest-permission lifecycle and state handling are reliable should a disposable rebuild test be repeated and combined into an unattended job. Kubernetes, a domain controller, a backup-server deployment and a deployment UI remain outside this completed case.

## Sources and validation status

Source-check date: **2026-11-03**. Documentation verification supports the cited mechanisms; it is not practical testing of this repository copy.

[1]: https://github.com/proxmox/pve-docs/blob/master/pveum.adoc
[2]: https://github.com/proxmox/pve-docs/blob/master/pct.adoc
[3]: https://bpg.sh/docs/
[4]: https://bpg.sh/docs/resources/virtual_environment_container/
[5]: https://opentofu.org/docs/cli/commands/plan/
[6]: https://opentofu.org/docs/intro/install/deb/
[7]: https://opentofu.org/docs/cli/commands/untaint/
[8]: https://opentofu.org/docs/language/state/sensitive-data/
[9]: https://code.visualstudio.com/docs/remote/ssh

1. [Proxmox user management][1]: scoped roles, token types and API authentication.
2. [Proxmox container toolkit][2]: lifecycle and deletion of container ACL/firewall configuration.
3. [bpg provider documentation][3]: provider authentication and environment variables.
4. [bpg LXC resource documentation][4]: container arguments, storage, features and import form. This is a current reference, not an archived guarantee of the exact installed release.
5. [OpenTofu plan][5]: preview, fresh apply plans and sensitive saved plans.
6. [OpenTofu Debian/Ubuntu installation][6]: package repository setup.
7. [OpenTofu untaint][7]: failed-create taint behavior and deliberate recovery.
8. [Sensitive data in state][8]: state contents and handling.
9. [VS Code Remote - SSH][9]: remote host and folder workflow.

**Practical evidence:** supplied operator transcripts of tool installation, authenticated API read, successful read-only plan, failed and successful container applies, guest configuration/state inspection and effective ACL checks; supplied final screenshot of the running container. The documentation author did not access or execute commands against that infrastructure.

**Public example test status:** reconstructed and parameterized for privacy; not deployed against Proxmox. No assertion is made that external release availability, a fresh install, guest networking, Nginx, application recovery or the complete rebuild workflow was independently tested.

**Editorial checks:** the guide distinguishes observed facts, documented behavior, recommended checks and remaining uncertainty. Public identifiers and raw evidence were removed. Repository-only validation details are recorded in the accompanying pull request.
