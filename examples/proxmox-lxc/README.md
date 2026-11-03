# OpenTofu: one unprivileged Debian LXC

This example accompanies the [case guide](../../docs/proxmox/opentofu-lxc-bootstrap.md). It creates the operating-system container only. Despite the resource label `nginx`, it **does not install Nginx**, configure an Ansible inventory, or restore application data.

The resource layout comes from a successful operator-supplied deployment. Real node names, bridge names, IDs, hostnames, addresses and key material have been replaced with required inputs. This parameterized public copy has not been applied to a Proxmox environment. The resource address `proxmox_virtual_environment_container.nginx` is deliberately unchanged for a controlled move of the original state.

## Files

- `main.tf`: provider constraint, required inputs, one container and its ID output.
- `terraform.tfvars.example`: deliberately fictional values; copy to ignored `terraform.tfvars` and edit locally.
- The repository-root `.gitignore`: excludes state, plans, private inputs, key files and editor settings. It does not retroactively untrack files.

## New deployment only

Use Bash on a management Linux machine with OpenTofu installed. Read the guide's ACL and storage prerequisites first. Do not run these steps against an ID already managed elsewhere.

```bash
cd examples/proxmox-lxc
umask 077
cp -n terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. All example environment values need replacement. A public SSH key must already exist at the configured path. Do not commit that key or put its private counterpart in a variable.

For the endpoint, use a DNS name whose certificate is trusted and whose port is reachable from the management machine. The address below is intentionally nonfunctional:

```bash
export PROXMOX_VE_ENDPOINT='https://pve.example.invalid:8006/'
export PROXMOX_VE_INSECURE=false
read -rsp 'Deployment token (USER@REALM!TOKENID=SECRET): ' PROXMOX_VE_API_TOKEN
printf '\n'
export PROXMOX_VE_API_TOKEN
```

Enter the token as input to the prompt, not as a command. Stop if it is empty. Then:

```bash
tofu init
tofu fmt -check
tofu validate
tofu plan
```

For a genuinely new single container, expect `1 to add, 0 to change, 0 to destroy`. Verify the node, ID, template, bridge, storage, SSH public key and root-disk size, not just the counts. Only then run `tofu apply` and inspect its new plan before confirming.

Do not set `PROXMOX_VE_INSECURE=true` as a permanent default. The original case used it temporarily; certificate trust remains a separate task.

## Existing deployment: do not start a second state

A Git clone contains code, **not the state of an existing container**. A new checkout without its original state may plan to create the already-existing ID. Stop; do not run `apply`, delete the container, or remove a state entry to make the error disappear.

The lowest-risk editing path is VS Code Remote - SSH into the original management machine, opening the existing working directory. To move that working directory into this repository checkout later:

1. Stop all OpenTofu operations and choose one authoritative working directory and workspace. Do not operate the old and new directories in parallel.
2. Make a private backup of the entire original directory outside this public checkout. State, state backups and local variables may contain sensitive infrastructure details.
3. In the new checkout, set the required variables to the **same existing** node, container ID, hostname, bridge, datastore, template ID and public-key path. Compare the source configurations.
4. For the original case's default local backend/workspace, copy the authoritative `terraform.tfstate` and existing `.terraform.lock.hcl` into this example directory. Keep state backups private. Do not copy `.terraform/` between machines. A configured remote backend or non-default workspace needs its own migration procedure instead.
5. Run `tofu init` without `-upgrade`, `tofu state list`, `tofu validate`, and `tofu plan`. Confirm the same resource address is tracked. Aim for no infrastructure change; inspect any drift before applying.
6. Retire the old working directory from active use only after the state and plan have been verified. Keep its private recovery copy.

Import is a separate recovery option when the authoritative state cannot be recovered. The provider uses `NODE/ID`, for example `tofu import proxmox_virtual_environment_container.nginx example-pve-a/19001`. Do not import an object still managed by another active state.

No lockfile is supplied here: the operator's real `.terraform.lock.hcl` was not provided. For an existing deployment, preserve it privately until reviewed and then commit the safe lockfile. For a new deployment, review the generated lockfile. Do not invent provider checksums or silently select a different provider version if installation fails.

## Important lifecycle limit

The case grants `PVEVMAdmin` on the specific container ID. Proxmox removes that ID's ACL entries when the container is destroyed. A later recreate can fail with HTTP 403 until an administrator restores the scoped ACL. Setting `purge_on_destroy = false` is **not** a fix for ACL removal. See the guide before attempting a replacement.

This example preserves the successful baseline; it does not implement a durable pool-permission design or a one-click recovery pipeline. It also leaves the successful case's networking/firewall defaults unchanged: that is not a reviewed security policy.

## Editing in VS Code

Clone the task branch locally for documentation work, or clone it on the management machine and open it through Remote - SSH. Use the integrated remote terminal for Linux commands. Keep the existing state on the management machine rather than copying keys and credentials to Windows unnecessarily.

Before publishing edits, run these commands from the repository root:

```bash
git status --short
git check-ignore examples/proxmox-lxc/terraform.tfvars
git diff --cached --check
git diff --cached
```

Only stage reviewed source files. Do not use `git add -f` to override the state/secret exclusions. The [guide](../../docs/proxmox/opentofu-lxc-bootstrap.md) records evidence, limitations, troubleshooting and source links.
