# Troubleshoot Proxmox VE backups to Proxmox Backup Server

## Goal and applicability

This is the incident and recovery companion to [the complete PBS bare-metal setup guide](proxmox-backup-server-from-scratch.md). It documents the failures actually observed during a two-host Proxmox VE to dedicated PBS deployment, explains known root causes, and separates tested workarounds from unresolved hypotheses.

**Environment reported by the operator:** PBS 4.2.8 / Debian 13 and PVE 9.2.10, November 2026. All hostnames, network addresses, usernames, storage names and guest IDs in the examples below are **fictional**. No actual private terminal logs, addresses, disk serial numbers, credentials or certificates appear here.

**Safety:** Do not debug backups by deleting a ZFS pool, wiping a disk, removing PBS chunks, granting cluster-wide Administrator access, changing a global root umask, forcing power-off of running VMs, or disabling TLS verification. A completed `vzdump` task is **not** proof that an external bind mount or application database can be recovered.

## Triage table

| Symptom | Relevant layer | First check |
| --- | --- | --- |
| APT update `401 Unauthorized` | PBS package repository | `apt update`; active subscription source |
| PVE cannot add/connect to PBS | PVE-to-PBS network and TLS | `pvesm status --storage pbs-vault` |
| Authentication or access denied | PBS token/user ACLs | Effective permissions for token on datastore |
| `vzdumptmp` local `Permission denied` | PVE temporary directory and LXC mapping | Caller `umask` and directory modes |
| VM fails in `Stop` backup mode | Guest shutdown and QEMU Guest Agent | `qm config <VMID>` and guest agent |
| CT backup omits files | LXC mount classification | `pct config <CTID>` and backup log |
| Unexpected sparse/rapid progress | Chunk reuse and zero ranges | `vzdump` final statistics |
| PBS Verify says `SKIPPED` | Verified snapshot age | `Ignore verified` and `Outdated after` |
| ZFS says `ONLINE` but HDD has bad history | Media health vs stored-data integrity | ZFS status, historical SMART attributes |
| Backups run into prune/verify | Schedule design | Per-job task start/end times |

## 1. Enterprise repository returns 401

**Observed:** PBS had `pbs-enterprise` enabled but there was no paid subscription, so the APT refresh returned HTTP **401**.

**Confirmed explanation:** that repository is subscription-gated. It is not an error in the backup datastore or API token.

**Solution:** PBS GUI **Administration > Repositories**: disable `pbs-enterprise` and enable `pbs-no-subscription` for a non-subscribed lab. The PBS 4.x documentation uses the Debian 13 `trixie` suite and `pbs-no-subscription` component. Keep the underlying Debian base sources. [1]

On **PBS**:

~~~bash
apt update
proxmox-backup-manager versions
~~~

A successful update is the verification. The no-subscription channel has a different validation policy from enterprise and is not a generic recommendation for production.

## 2. TLS hostname verification failed despite successful shell tests

**Observed:** when attempting to add PBS storage in PVE, hostname verification failed. A separate shell `curl` request using a private-overlay FQDN and an `openssl s_client` hostname check succeeded; the PVE storage error persisted. Configuring the **PBS LAN IP plus the correct certificate fingerprint** then made the PVE storage `active`.

**Confirmed:** the PBS HTTPS service was reachable, the separate FQDN TLS checks passed, and the IP/fingerprint PVE configuration worked. **Not confirmed:** the exact reason why PVE still rejected the earlier hostname-based definition. Do not assert a PVE defect, a definite SAN error or broken DNS without evidence.

On **each PVE host**:

~~~bash
getent hosts pbs.example.invalid
pvesm status --storage pbs-vault
curl -I --connect-timeout 5 --max-time 10 https://pbs.example.invalid:8007/
openssl s_client -connect pbs.example.invalid:8007 -servername pbs.example.invalid -verify_hostname pbs.example.invalid </dev/null
~~~

All hostnames are fictional; substitute your private DNS name. Interpret a `401` or `403` HTTP response separately from TLS or socket failure. Verify the **actual configured PVE Server field**, certificate SANs, PVE storage configuration, per-node DNS and proxy logs.

On **PBS**:

~~~bash
proxmox-backup-manager cert info
openssl x509 -in /etc/proxmox-backup/proxy.pem -noout -dates -subject -issuer -fingerprint -sha256
systemctl is-active proxmox-backup-proxy
~~~

For the observed workaround, enter the LAN IP, datastore, proper token ID/secret and fresh SHA-256 fingerprint in **PVE > Datacenter > Storage > Add > Proxmox Backup Server**. Verify with `pvesm status` on *both* nodes.

**Important future breakage:** replacing the certificate changes its fingerprint. Pinned clients then need a coordinated update. A publicly trusted certificate can avoid explicit pinning **only if** correct hostname/DNS validation is configured and tested. File-based certificates obtained with `tailscale cert` do not automatically install/renew themselves in PBS's proxy paths. This lifecycle was not finished in the original case. [2][3]

## 3. Token exists but datastore access fails

**Check, not a confirmed separate incident:** PBS token privileges are intersected with the parent user's rights. A token with no effective datastore privileges can authenticate but fail when creating backups. `DatastoreBackup` is the narrowly scoped role for backup/restore of **owned** backup groups. [4]

On **PBS**, inspect before changing ACLs:

~~~bash
proxmox-backup-manager acl list
proxmox-backup-manager user permissions 'backupwriter@pbs!pve-cluster' --path /datastore/vault-demo
~~~

When confirmed missing, grant to **both**:

~~~bash
proxmox-backup-manager acl update /datastore/vault-demo DatastoreBackup --auth-id 'backupwriter@pbs'
proxmox-backup-manager acl update /datastore/vault-demo DatastoreBackup --auth-id 'backupwriter@pbs!pve-cluster'
~~~

Then verify effective permissions and repeat a targeted backup. Never publish the API token secret or assign blanket admin permission to suppress a 403. The observed source deployment ultimately had functioning scoped permissions; there was **no distinct confirmed 403 root-cause episode** for this PBS connection.

## 4. LXC `vzdumptmp` Permission denied: confirmed shell umask

### Symptoms and root cause

A manual `vzdump` of an **unprivileged LXC** failed locally inside `lxc-usernsexec` while attempting to read the generated `pct.conf` at a path similar to:

~~~text
/var/tmp/vzdumptmp<JOB_ID>_<CTID>/etc/vzdump/pct.conf
OS error 13: Permission denied
~~~

The operator's interactive root shell had **`umask 0027`**. PVE temporary directories were effectively `root:root` **750** and config files **640**; the unprivileged backup client's mapped UID could not traverse/read the tree. Moving the temporary directory did not solve the problem. With `umask 022` local to that command, the backup succeeded.

On the relevant **PVE** node:

~~~bash
umask
# If the failed task's directory still exists:
namei -l /var/tmp/vzdumptmp<JOB_ID>_<CTID>/etc/vzdump/pct.conf
~~~

**Verified one-off workaround**:

~~~bash
cd /
( umask 022; vzdump 201 --storage pbs-vault --mode snapshot )
~~~

Use `--mode stop` instead for the selected application's consistency/downtime policy. The subshell prevents changing the interactive parent shell or global security defaults. This workaround succeeded in the source case.

**Do not** chmod all temporary directories or change the host's global umask to solve one interactive command. Crucially, the **PVE GUI Run now** backup job subsequently worked for the same unprivileged container because it did **not** inherit the interactive shell's restrictive umask. For automation, inspect the process/service-specific environment before changing persistent settings.

This confirmed mechanism concerns **local PVE filesystem access**, not remotely missing PBS permissions. Treat other `Permission denied` errors separately.

## 5. VM backup fails because Linux guest does not shut down

### What happened

The second PVE host used a single **Stop** job for its VMs and LXC. Five guests backed up, but one **running** Linux VM failed:

~~~text
QEMU Guest Agent is not running
VM quit/powerdown failed - got timeout
qm shutdown ... --timeout 600 ... exit code 255
~~~

The VM config contained `agent: 1`, but the guest agent did not respond. Thus **enabled in PVE** was not the same as **installed and functioning inside the guest**. The shutdown timer expired after 600 seconds, causing `TASK ERROR` for the overall job, although earlier and later guests completed successfully. The actual cause of guest non-response to ACPI/shutdown was not established.

### Workaround tested

A targeted **Snapshot** backup on PVE completed successfully:

~~~bash
cd /
( umask 022; vzdump 301 --storage pbs-vault --mode snapshot )
~~~

It included the VM disk and EFI data but warned:

~~~text
skipping guest filesystem freeze - agent configured but not running?
~~~

Accordingly, do not describe this as agent-frozen or database/application-consistent: it is at most **crash-consistent**. The operator then changed the entire second-node **scheduled** job from Stop to **Snapshot**. **No subsequent complete scheduled run after that change was supplied**.

### Repair plan (not tested to completion)

On PVE:

~~~bash
qm status 301
qm config 301
# Once guest-side agent is installed and started:
qm agent 301 ping
~~~

Inside a **Debian/Ubuntu-based Linux guest**, when changes and reboot/downtime are approved:

~~~bash
sudo apt update
sudo apt install qemu-guest-agent
systemctl status qemu-guest-agent --no-pager
~~~

Check **PVE > VM > Options > QEMU Guest Agent**, guest virtio channel and whether the agent actually starts; some configurations require rebooting the guest. Other operating systems need their own package instructions. A nonresponsive guest agent **may coexist** with an ACPI shutdown issue, but one does not prove the other. Inspect guest logs and ACPI configuration. Test any graceful `qm shutdown` during a maintenance window; **never immediately force-kill a valuable running VM just to make a backup succeed**. Only mark fixed after appropriate agent, shutdown, backup and recovery checks.

## 6. Successful LXC backup omits a bind-mounted music directory

**Observed:** the media-service CT was backed up, but the log explicitly excluded `mp0` at its music directory because it was a **host bind mount, not a managed PVE backup volume**.

On PVE:

~~~bash
pct config 202
~~~

Inspect each `mpN` entry; compare the backup log's **included** vs **excluded** mount points. An LXC rootfs snapshot is not automatically a backup of host files exposed through bind mounts, NFS mounts or external stores. The mount path may also be absent on a different restore host.

Create an independent backup of the **source data** if required, and test its restore including permissions. **Source-case status: intentionally deferred by the operator.** Do not claim these music files are protected.

## 7. Sparse backup and huge transfer-rate spikes

The PBS protocol sends and reuses chunk data; QEMU backups may skip zero ranges. In the case, a 64 GiB disk could skip tens of GiB and report brief several-GiB/s "read" speeds while writing almost nothing. Another first run took more than 50 minutes.

Read the **final** summary:

- `backup is sparse` describes skipped zero/unallocated ranges, not the size of application files.
- `reused` describes incremental reuse/deduplication, not independent proof that a snapshot will restore.
- Very high progress-read speeds during skipped regions do not measure physical HDD sustained write performance.
- A first full VM backup can be much slower than later runs; timing **must be measured**, not guessed.
- Mirror usable space is approximately that of **one** disk, not both combined.

Use PBS **Datastore > Content**, ZFS pool capacity and final task summaries. Calculate retention with space for changed blocks and headroom.

## 8. PBS Verify says `SKIPPED: recently verified`

**Observed:** the first verification found **two backup groups**, two snapshots per group, verified newly arrived snapshots and skipped the ones already recently verified; it ended **TASK OK / zero errors**.

This is expected with `Ignore verified` enabled and `Outdated after = 30 days`. It is not evidence that a backup was silently lost. Review **Datastore > Verify Jobs** and **Datastore > Content** to ensure namespace scope and age policy match your expectations. [5]

Verification establishes chunk/index integrity at the time of the check; it does not prove restore of a whole guest plus services. Keep a restore test in the operating procedure.

## 9. ZFS scrub is clean but old HDDs remain at risk

**Observed:** the first on-demand scrub finished with `ONLINE`, zero READ/WRITE/CKSUM error counters, `0B repaired` and no known data errors. It finished quickly because only a few GiB were allocated.

This confirms allocated stored blocks were readable/checksummed at that moment. It does **not** prove the surfaces of two 2 TB disks are healthy. In this case an aging Seagate had hundreds of reallocated sectors and previously thousands of pending/offline-uncorrectable sectors. After a **destructive rewrite before the PBS datastore existed**, the pending/uncorrectable counts became zero and a later long self-test passed. The old sector-remap history remained.

**Do not run destructive disk rewrites against an in-use pool** to imitate that outcome. Watch ZFS `DEGRADED`/`FAULTED`, READ/WRITE/CKSUM changes, SMART reallocation increases, pending sectors and failed tests; build an **independent** second copy and replace risky drives as resources permit.

### Specific Samsung HD204UI firmware warning

smartmontools' drive database warns that certain commands may cause data loss with an affected Samsung F4 EG drive. **Patched and unpatched drives show the same firmware revision**. [6]

The source operator backed up `/etc/smartd.conf`, added `/dev/sda -d ignore` **before** the `DEVICESCAN` entry and restarted `smartmontools.service`. The journal then confirmed `/dev/sda` was ignored while **one SATA HDD and the NVMe remained under SMART monitoring**. This is a targeted **temporary risk-reduction choice**, not a firmware repair. It **removes SMART visibility for that disk**, and disk letter mappings can change. **Do not copy `-d ignore` to healthy unrelated disks.** Track the firmware/hardware issue separately.

## 10. Backup, prune, verify and GC can overlap

The configured case schedule was: **node A 02:00 backup**, **node B 03:00 backup**, **PBS prune 04:00**, **verify 05:00**, **GC Sunday 06:00**, and a monthly ZFS scrub timer.

The first node-B backup run took well over 90 minutes. Thus its **03:00** run can overlap the **04:00** prune job, and two old mirrored disks may see competing I/O. This is a **plausible scheduling/throughput hazard**, **not a proven cause** of the shutdown timeout, umask error or other actual incidents.

Record durations over several complete cycles. Move the long backup earlier or move maintenance later with sufficient buffer; if necessary serialize jobs. Verify the post-change schedule before saying the system is fully unattended.

## 11. Restored guest is running but the service is broken

A successful PVE restore reconstructs the **included** guest volumes/configuration, not every external dependency. In an isolated test, inspect:

~~~bash
pct config <RESTORED_ID>
pct status <RESTORED_ID>
# Only after starting an isolated test container:
pct exec <RESTORED_ID> -- systemctl --failed
~~~

For Docker applications, verify `docker ps -a`, health checks, persistent records, databases and application login. Check restored device mappings such as TUN, bridge, IP/MAC, LXC features and missing host bind mounts.

**Observed actual test:** a logging LXC was deliberately backed up, stopped, destroyed, restored under its original ID and restarted; its Docker services returned, and one application service reported **healthy**. This does **not** establish that all other workloads or the PBS OS itself were restored in practice.

## 12. A certificate renews; next backup unexpectedly stops

When PBS's proxy certificate changes, its fingerprint changes. A PVE PBS storage configured with an old pinned fingerprint can fail even if port 8007 is reachable.

A safe coordinated rotation procedure:

1. Review the new cert's hostname, chain, expiry, key matching, and file permissions.
2. Update `/etc/proxmox-backup/proxy.pem` and `proxy.key` securely; the official instructions use owner root, group backup and mode 0640.
3. **Reload** `proxmox-backup-proxy` instead of restarting during running backups. [2]
4. If fingerprint-pinned, update the PVE PBS storage fingerprint and verify `pvesm status` on **each** host, then perform a small backup.
5. Monitor the certificate's next expiry. Tailscale `tailscale cert` certificates written to files **require your own renewal/installation process**. The source case had not yet configured or tested that automation. [3]

A certificate for a tailnet DNS hostname does not automatically validate a bare LAN-IP URL. Preserve a tested approach rather than mixing hostname validation with an unrelated IP.

## 13. “Notified via mail-to-root” but no email received

The source operator explicitly chose **no external email for now**. The task log's `notified via target mail-to-root` line does **not** prove delivery into a human inbox.

When adding alerts, configure/test **PBS > Configuration > Notifications** and **PVE > Datacenter > Notifications** separately. Ensure a PBS `system-mail` event is not filtered out by an incompatible severity-only matcher. A real received test warning is the success condition. Until then, review job failures and SMART/ZFS status manually.

## 14. Evidence, limits and sources

| Result | Status based on operator evidence |
| --- | --- |
| PBS installation and ZFS mirror | Completed; pool/datastore ONLINE |
| LAN IP plus certificate fingerprint | Working PVE storage |
| Unprivileged LXC CLI umask workaround | Backup succeeded |
| Node A job | GUI Run now produced TASK OK |
| Node B first job | Five guests OK; one shutdown failure, overall TASK ERROR |
| Failed VM's standalone snapshot backup | Success, guest freeze skipped |
| Node B job switched to snapshot | Settings changed; **full post-change run not shown** |
| Actual destructive LXC restore | Succeeded and Docker services checked |
| PBS Verify | TASK OK, zero errors |
| First ZFS scrub | ONLINE, 0B repaired, zero errors |
| Monthly scrub timer | Enabled |
| SMART special-case exclusion | Journal proved expected disk count |
| Tailscale certificate renewal / notification delivery / PBS hardware rebuild | **Not tested** |
| External bind-mount data backup | **Explicitly postponed** |

**Source check date: 2026-11-11.** Only publicly shareable, anonymized facts were transcribed from operator evidence. Vendor documentation was checked separately. The author did **not** execute commands against real infrastructure or practically test the fictional examples.

[1]: https://pbs.proxmox.com/docs/installation.html
[2]: https://pbs.proxmox.com/wiki/HTTPS_Certificate_Configuration
[3]: https://tailscale.com/docs/how-to/set-up-https-certificates
[4]: https://pbs.proxmox.com/docs/user-management.html
[5]: https://pbs.proxmox.com/docs/maintenance.html
[6]: https://github.com/mirror/smartmontools/blob/master/drivedb.h
