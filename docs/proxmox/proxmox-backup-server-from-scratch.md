# Deploy Proxmox Backup Server on bare metal and protect two Proxmox VE nodes

## Goal and applicability

This is an **end-to-end rebuild runbook**: start with an empty dedicated backup machine, install Proxmox Backup Server (PBS), create a mirrored ZFS datastore, grant scoped backup access, connect two existing Proxmox VE (PVE) nodes, schedule backups and maintenance, verify backup integrity, and **prove recovery by restoring a guest**. It also links to the [failure and troubleshooting reference](proxmox-backup-server-troubleshooting.md), based on problems encountered during the original deployment.

The source case involved **PBS 4.2.8 on Debian 13** and **PVE 9.2.10**, observed in the operator's environment in November 2026. A dedicated physical machine used a roughly 256 GB NVMe for the operating system and two approximately 2 TB SATA disks for a ZFS mirror. These are observations, not minimum hardware requirements or a certification for other versions.

**Read before starting:**

- This repository is public. **All hostnames, network addresses, user names, storage identifiers and guest IDs below are fictional.** Never paste real addresses, credentials, logs, certificate keys or private configuration into this repository.
- Commands labeled **PBS** run as administrator on the dedicated backup machine. Commands labeled **PVE** run on a virtualization host. Do not mix them.
- **Disk creation, OS installation, disk wiping, and destructive restore tests can destroy data.** Identify every disk by model, size and serial locally before choosing it in a destructive UI dialog.
- A ZFS mirror tolerates one disk failure; it **is not an independent second backup copy**. A failed physical PBS server, theft, misconfiguration, ransomware or simultaneous drive failure can still destroy the only copies. Plan an offsite/off-host copy.
- The original disks were aged; one had a history of many remapped and formerly unreadable sectors. Later successful SMART tests and a clean ZFS scrub **did not establish that the drive was healthy**. Never treat rewriting troublesome sectors as a repair or as permission to trust an aging disk.
- The exact real deployment's secrets, certificates, disk serial numbers, private addresses and timestamps are intentionally omitted. Maintain a private inventory and password manager separately.

### Fictional example inventory

| Item | Example to replace privately | Purpose |
| --- | --- | --- |
| Dedicated backup host | `pbs.example.invalid` | PBS, **not** a PVE node or LXC |
| PBS LAN address | `192.0.2.30` | Documentation-only TEST-NET address |
| PVE node A | `pve-a.example.invalid` | Example of important application LXCs |
| PVE node B | `pve-b.example.invalid` | Example of several VMs and an LXC |
| PBS datastore / ZFS pool | `vault-demo` | Example identifier used throughout |
| PVE storage ID | `pbs-vault` | Different from the PBS datastore name |
| PBS backup identity | `backupwriter@pbs!pve-cluster` | Token ID, **not** its secret |
| Backup network | Protected LAN, TCP 8007 | PVE-to-PBS HTTPS |
| Guest IDs | `201`, `202`, `301` etc. | Fictional example guest IDs |

Private inventory should also record: management IP and gateway, DNS, NIC MAC, which physical drive is the **OS disk**, which two drives are the **mirror members**, system clock/time zone, PVE nodes, each guest and data mount, recovery credentials, and the location of a **separate backup of PBS configuration**.

## 1. Install PBS on its own physical machine

### 1.1 Download and prepare the installer

1. Download the current **Proxmox Backup Server ISO** from the [Proxmox downloads page][pbs-installer]. Use the PBS ISO, not the PVE installer. Verify the published checksum of the file you downloaded using the release page's own checksum.
2. Write the ISO to a USB stick with a bootable-image writer. **Writing the image erases the selected USB stick.** Check the destination device carefully.
3. In the server firmware/BIOS, choose the USB installer. Use the graphical installer, or the console installer if the graphical display fails.
4. At the **target disk** page, choose **only the separate NVMe system disk**. In this layout, the two SATA disks must be left untouched for the later ZFS backup pool. An `ext4` OS install is sufficient; the **backup datastore**, not necessarily the OS disk, will use ZFS.
5. Set country, time zone and keyboard. Configure a strong `root` password and the administrative email field required by the installer. The email field does **not** prove external mail delivery.
6. Set hostname/FQDN, static LAN address, prefix/netmask, default gateway and DNS appropriate to **your** network. An example `192.0.2.30` is reserved for documentation and will not work on a normal home LAN.
7. Confirm the selected disks on the installer's final summary **before** accepting the destructive installation. Complete installation, remove USB and reboot.

PBS is based on Debian; the ISO installs the Proxmox kernel, management stack and web GUI. A separate server remains available when a hypervisor is down. Follow the official installer for differences introduced by later PBS versions. [1][2]

### 1.2 First boot and network checks — on PBS

~~~bash
hostnamectl
hostname -f
ip -br addr
ip route
getent hosts pbs.example.invalid
timedatectl status
lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINTS
proxmox-backup-manager versions
systemctl is-active proxmox-backup-proxy
~~~

Confirm that the OS resides on the intended disk; the two data disks have **not** been selected for the OS installation; local DNS agrees with the chosen hostname; and the default gateway and system time are correct. Synchronised clocks are important for backup timestamps and TLS.

Open `https://<YOUR_PBS_LAN_IP>:8007`. Authenticate as `root@pam` with the password set during installation. The default self-signed HTTPS certificate normally causes a browser warning until a trusted certificate or an explicit trust/fingerprint approach is configured. Do not disable TLS entirely.

### 1.3 Enable appropriate package repositories

The source case received **HTTP 401 Unauthorized** when updating against `pbs-enterprise` without a paid subscription. This is a repository entitlement issue, not an indication that the PBS backup service is broken.

Use **Administration > Repositories** to disable the enterprise repository and enable `pbs-no-subscription` for a non-subscribed homelab. The PVE hosts' repositories are separate. For PBS 4.x on Debian 13/Trixie, the vendor-documented Deb822 entry for the no-subscription repository is: [3]

~~~text
# /etc/apt/sources.list.d/proxmox.sources
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
~~~

Ensure the existing `/etc/apt/sources.list.d/pbs-enterprise.sources` stanza is **disabled**, for example with `Enabled: false`; do not leave both repositories active inadvertently. Do not overwrite existing Debian base sources to fix a Proxmox repository error.

On PBS, after reviewing the active sources:

~~~bash
apt update
apt list --upgradable
# Schedule a maintenance window before applying a kernel-changing upgrade.
apt full-upgrade
proxmox-backup-manager versions
~~~

For no-subscription use, Proxmox describes this channel as less extensively validated than enterprise. Reboot if required after reviewed updates and verify the proxy and datastore again.

## 2. Inventory and create the mirrored backup datastore

### 2.1 Check physical media before formatting — on PBS

~~~bash
lsblk -d -o NAME,SIZE,MODEL,TRAN
lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINTS
proxmox-backup-manager disk list
zpool list
~~~

**Do not copy drive names blindly:** `/dev/sda` and `/dev/sdb` are discovery names, not permanent identity guarantees. Check model and local serial numbers (do not publish serial numbers). Make sure neither target disk contains required data, is mounted, or belongs to an existing pool.

The case used one older Samsung SpinPoint F4 EG model and one older Seagate Barracuda model. Historical tests exposed many unreadable/pending sectors on the Seagate; a destructive whole-disk rewrite was performed **before** it was put into the pool and later tests passed. **Do not repeat destructive `badblocks -w`, disk wiping or whole-disk reinitialization on any disk that contains backups.** A passed subsequent self-test does not reset accumulated reallocation history.

The Samsung HD204UI family has a documented firmware issue: certain diagnostic operations may cause data loss under some conditions, and patched/unpatched units report the same firmware revision. Review the exact model's warning before running automated SMART or `hdparm` queries. [9] The original operator eventually excluded this disk from `smartd` monitoring as a conservative temporary choice; this does **not** protect against all firmware behavior or hardware failure.

### 2.2 Create the ZFS mirror through PBS GUI

On PBS: **Administration > Storage/Disks > ZFS > Create** (labels can vary slightly by release).

1. Give the pool a name such as `vault-demo`.
2. Select **both intended SATA backup disks** after checking models and sizes, never the OS NVMe.
3. Choose **Mirror** (not Stripe/RAID0). A two-disk mirror has approximately the usable capacity of **one** disk.
4. Use `ashift = 12` for a normal 4 KiB-sector/advanced-format configuration, if the UI asks. Set compression to `on` or `lz4` according to the displayed defaults.
5. Select **Add as Datastore**, if offered. It creates the PBS datastore together with the pool. If the option is not offered, first create the pool, then choose **Datastore > Add Datastore** and point it to the existing mounted path. **Do not register the same path twice.**
6. Review disk selection again, then create. This **erases the selected data disks**.

The PBS 4.2 CLI offers an equivalent destructive operation, but the GUI is intentionally preferred here because the operator must visually verify disk identity before clicking Create. Vendor CLI syntax is `proxmox-backup-manager disk zpool create <pool> --devices <diskA>,<diskB> --raidlevel mirror --add-datastore true`; never paste placeholders as if they were real disk names. [4]

### 2.3 Verify both layers — on PBS

~~~bash
zpool status -v vault-demo
zpool list vault-demo
zfs list
proxmox-backup-manager datastore list
proxmox-backup-manager datastore show vault-demo
findmnt /mnt/datastore/vault-demo
~~~

Expect a pool `state: ONLINE` with a `mirror-0` containing both drives and `READ WRITE CKSUM` counters of zero. Expect a **separate PBS datastore record** named `vault-demo` at `/mnt/datastore/vault-demo`. A ZFS pool and a PBS datastore are not the same object.

If the pool was created without adding a PBS datastore, the documented creation syntax is `proxmox-backup-manager datastore create vault-demo /mnt/datastore/vault-demo`. **Check that it is not already registered before running this command**, and do not create a new pool over an existing pool merely to add its PBS entry. [4]

## 3. Create a dedicated PBS backup account and API token

Use a PBS account dedicated to writing backups, not `root@pam`. On PBS: **Configuration/Access Control > User Management > Users > Add** (exact grouping differs by UI version).

1. Create a native PBS account such as `backupwriter@pbs`. Keep its credentials out of the repository.
2. Under **API Tokens**, create a token called `pve-cluster` for that account. Its complete example token ID is `backupwriter@pbs!pve-cluster`.
3. **Store the token secret immediately in a password manager.** PBS displays it at generation time, not on demand later.
4. Under **Permissions**, grant **DatastoreBackup** at `/datastore/vault-demo` **to the user and to the token**. PBS token privileges are intersected with their parent user's privileges; giving permission to one alone may be insufficient. This role is suitable for backing up and restoring **owned** backup groups, not general datastore administration. [5]
5. Confirm effective token rights with the command below. It is a **read-only verification**.

On PBS:

~~~bash
proxmox-backup-manager acl list
proxmox-backup-manager user permissions 'backupwriter@pbs!pve-cluster' --path /datastore/vault-demo
~~~

Or, if preferring the documented CLI ACL syntax:

~~~bash
proxmox-backup-manager acl update /datastore/vault-demo DatastoreBackup --auth-id 'backupwriter@pbs'
proxmox-backup-manager acl update /datastore/vault-demo DatastoreBackup --auth-id 'backupwriter@pbs!pve-cluster'
~~~

Keep datastore administration, pruning, verification and GC under appropriate administrative PBS permissions. Neither token credentials nor password should be committed into PVE automation files.

## 4. Connect the datastore to Proxmox VE

### 4.1 Network and TLS

Verify from **each** PVE node that it can reach the PBS LAN address on TCP 8007. Confirm routing, DNS if using a hostname, and certificate trust. A successful HTTPS request from a workstation does not prove reachability from every PVE host.

For a newly installed PBS using its self-signed certificate, obtain its actual SHA-256 certificate fingerprint on **PBS**:

~~~bash
proxmox-backup-manager cert info
openssl x509 -in /etc/proxmox-backup/proxy.pem -noout -fingerprint -sha256
~~~

The fingerprint is a public certificate identifier, **not** the API token secret. Copy it directly from the current server; never reuse a value from a guide or an unrelated host. [6]

### 4.2 Add shared PBS storage — in PVE GUI

On a PVE node: **Datacenter > Storage > Add > Proxmox Backup Server**.

| GUI field | Fictional value or procedure |
| --- | --- |
| ID | `pbs-vault` — PVE's local storage ID |
| Server | PBS LAN IP or a correctly validated DNS name |
| Datastore | `vault-demo` — **PBS's datastore name** |
| Username | `backupwriter@pbs!pve-cluster` |
| Password | The token **secret**, securely entered |
| Fingerprint | SHA-256 fingerprint of the active PBS certificate when pinning is required |
| Nodes | Both intended cluster nodes where reachable |
| Content | Backup |

The real case's initial hostname-based connection failed with a hostname-verification error even after separate `curl` and `openssl` checks passed. Using the PBS **LAN IP plus the correct fingerprint** worked. This is a **case-specific workaround**, not proof of the underlying hostname mismatch. Do not disable verification or assume that a certificate for a tailnet DNS name also matches a bare LAN IP. See [TLS troubleshooting](proxmox-backup-server-troubleshooting.md#connection-failure-tls-hostname-or-fingerprint).

PVE datacenter storage configuration is cluster-wide if the hosts are in one PVE cluster; **adding storage is not the same as creating backup jobs on both nodes**.

On **each** PVE node:

~~~bash
pvesm status --storage pbs-vault
~~~

Expect `active` and plausible capacity. If it is inactive on only one node, investigate that node's route, firewall, storage node restrictions and effective credentials.

### 4.3 Optional: private remote UI with Tailscale

The original setup installed Tailscale natively on PBS and used its private overlay network for administrator access. This is **optional** for PVE-to-PBS backups; the successful PVE backup storage path used **LAN** access.

1. Install Tailscale by following its **current official Linux instructions**, authenticate PBS to the correct tailnet and check `tailscale status` and `tailscale ip -4`.
2. Restrict access with appropriate tailnet ACL/grant policy. Do not expose PBS's management API publicly solely to make it reachable remotely.
3. For a browser-trusted HTTPS hostname, enable **MagicDNS** and **HTTPS certificates** in Tailscale admin settings and request a certificate with `tailscale cert` for the private tailnet hostname. The full name is private environment data; keep it out of public documentation.
4. For a **manual** Tailscale certificate installation, after installing Tailscale from [its documented Linux package instructions](https://tailscale.com/docs/install/linux), run these commands **on PBS**. Replace the demonstrably fictional FQDN with **the real full DNS name shown for your own node**, and do not paste it into public Git:

~~~bash
tailscale up
tailscale status
tailscale ip -4

# Replace with this machine's actual MagicDNS FQDN first.
FQDN='pbs.your-tailnet.ts.net'
umask 077
tailscale cert --cert-file=/root/pbs-tailnet.crt --key-file=/root/pbs-tailnet.key "$FQDN"
openssl x509 -in /root/pbs-tailnet.crt -noout -dates -subject
install -o root -g backup -m 0640 /root/pbs-tailnet.crt /etc/proxmox-backup/proxy.pem
install -o root -g backup -m 0640 /root/pbs-tailnet.key /etc/proxmox-backup/proxy.key
systemctl reload proxmox-backup-proxy
openssl x509 -in /etc/proxmox-backup/proxy.pem -noout -dates -fingerprint -sha256
~~~

**This replaces the active HTTPS certificate**, so any PVE storage with the old fingerprint pin can fail immediately. Perform only in a maintenance window and update/verify PVE trust as part of the same change. Securely remove unused temporary key copies after validation. If you do not need a trusted tailnet HTTPS hostname, skip these steps and keep the functional self-signed/fingerprint approach.

5. If choosing custom PBS TLS certificate files, the PBS proxy reads `/etc/proxmox-backup/proxy.pem` and `/etc/proxmox-backup/proxy.key`. The official PBS guidance uses owner `root`, group `backup`, mode `0640`, then `systemctl reload proxmox-backup-proxy` (reload, not a disruptive restart). Back up existing certificate metadata before changes. [6]
5. Validate the exact hostname and certificate chain from the client. **File-based Tailscale certificates are not installed or renewed automatically by `tailscaled`.** Schedule renewal, secure file installation and proxy reload; then verify the next expiry. **This automatic deployment was not completed or tested in the source case.** [7]
6. **Certificate rotation can invalidate PVE storage fingerprint pins.** If pinned, update the PVE fingerprint before its next scheduled backups; alternately design and test genuine CA + hostname validation without a pinned fingerprint. The source case had not completed this transition.

You can safely skip this section on a LAN-only rebuild; PBS self-signed TLS and a correct pinned fingerprint remain an option.

## 5. Understand what a PVE backup does—and does not include

PVE `vzdump` sends a VM or container backup to PBS. PBS stores deduplicated chunks, metadata and guest configuration; each completed snapshot is identified by **type / guest ID / UTC timestamp**.

- **Stop mode**: temporarily stops a running guest to back it up, then restarts it. Useful when consistency matters and planned downtime is acceptable. A guest that refuses to shut down can cause a job error.
- **Snapshot mode**: can back up a running VM without stopping it. QEMU Guest Agent filesystem freeze, if configured and actually working, may improve guest filesystem consistency. Without working guest integration, do **not** claim application/database consistency. For LXC, assess application state and bind mounts separately.
- **Existing VM snapshots are not automatically included** as standalone snapshots in a PBS backup. A log saying `snapshots found (not included into backup)` is not itself an error.
- **Bind mounts are not ordinary managed PVE disks**: a container `mp0` binding a host directory can be explicitly **excluded** by the backup client. Protect that source separately if its data matters.
- **Docker volumes inside the backed-up LXC root filesystem** are generally included if they are not excluded/mounted externally. Nevertheless, a live MongoDB/OpenSearch/SQLite backup can be inconsistent; plan a clean stop or application-aware dump.
- **Sparse/deduplicated statistics are not total physical data consumed**: a 64 GiB virtual disk can require much less datastore space, while repeated backups can reuse chunks.

Use **PVE > Datacenter > Backup** for scheduled cluster jobs. Leave retention fields **unset in PVE** if the intended policy is maintained centrally by the PBS prune job. If both are set, review how policies interact; do not assume independent retention choices are harmless. [8]

## 6. Schedule one PVE backup job per host

### 6.1 Node A: important application containers

On **PVE > Datacenter > Backup > Add**:

| Field | Value used in source case | Why |
| --- | --- | --- |
| Node | First PVE host | Restrict job to that host |
| Storage | `pbs-vault` | Target the dedicated PBS |
| Schedule | Daily **02:00** | Quiet maintenance period |
| Selection | Explicitly chosen important LXCs | Do not accidentally back up disposable tests |
| Mode | **Stop** | Minimize consistency risk for SQLite and Docker services |
| Retention | Unset | PBS prune job owns policy |
| Enabled | Yes | Actually schedule the job |

The observed source workloads were an automation service with an SQLite database and a logging stack with Docker, MongoDB and OpenSearch data **inside the container root filesystem**. Both were successfully backed up in stop mode. Stopping means planned downtime; size the maintenance window and watch service recovery.

A **GUI Run now** test completed successfully for both containers and restarted them. This is evidence for that run, not evidence that every future scheduled run will succeed. The explicitly selected VM/CT list must be updated when new important guests are added. In the source case a separate disposable test container was deliberately not included.

On the first PVE host, manual one-guest checks may use:

~~~bash
cd /
( umask 022; vzdump 201 --storage pbs-vault --mode stop )
~~~

Replace `201` with a real selected ID, only during an approved downtime window. The subshell's `umask` matters for a specific troubleshooting case; see [the permission failure](proxmox-backup-server-troubleshooting.md#lxc-backup-permission-denied-in-vzdumptmp).

### 6.2 Node B: VMs plus a media application container

Create a **second** job at **Datacenter > Backup > Add**:

| Field | Value / decision |
| --- | --- |
| Node | Second PVE host |
| Storage | `pbs-vault` |
| Proposed schedule in conversation | Daily **03:00**; exact saved setting **not independently confirmed** |
| Selection | **All guests** on this host |
| Initial mode | `Stop`; one running Linux VM refused shutdown |
| **Revised final mode** | **Snapshot** |
| Retention | Unset |
| Enabled | Yes |

During the case's **first full job**, five of six guests backed up successfully. One Linux VM had `agent: 1` in its PVE config but **no responsive QEMU Guest Agent**; stop mode timed out after 600 seconds without shutdown. Its separate `snapshot` backup then succeeded, and the scheduled node-B job was changed to snapshot. **A complete post-change scheduled node-B run was not supplied. Verify it independently.**

A representative manual test on node B is:

~~~bash
cd /
( umask 022; vzdump 301 --storage pbs-vault --mode snapshot )
~~~

The failing guest's output also reported `skipping guest filesystem freeze - agent configured but not running?`. Thus this successful backup is **at best crash-consistent** until guest integration/application consistency is established. Repairing the agent is a separate task; do not force-power-off a live system merely to make a backup succeed. See [guest shutdown failure](proxmox-backup-server-troubleshooting.md#vm-shutdown-timeout-and-qemu-guest-agent).

**Important mount-point omission:** the media LXC's backup explicitly excluded a host bind mount, `mp0`, which provided the music directory. That data **was not** inside the PBS CT archive. Protect it separately when required. The operator consciously deferred this task, so it remains an acknowledged gap.

### 6.3 Check job execution and avoid timing collisions

In PVE, select each new job and use **Run now**. Read the **complete task log**, not just progress percentages; ensure **TASK OK**, that intended guests appear, and that stopped services return.

On each PVE host:

~~~bash
pvesm status --storage pbs-vault
pct list
qm list
~~~

**Schedule warning:** node A was configured for **02:00**; **03:00 was proposed for node B but its saved schedule was not shown**. PBS maintenance was set/reported for **04:00 prune**, **05:00 verify**, and **Sunday 06:00 GC**. Its first node-B run lasted well over an hour and a half. Therefore **03:00 and 04:00 can overlap** during a full/slow backup, and some other jobs may contend for old HDD I/O. These times describe what was configured, **not** a proven contention-free schedule. After measuring multiple real runs, shift jobs into adequately separated windows (or use suitable scheduling/serialization) and verify that the overnight window accommodates both hosts before relying on unattended recovery points.

## 7. Central PBS housekeeping jobs

These settings were chosen for a small daily-backup homelab; they are **not** universal retention or compliance requirements. All examples operate on the **root namespace** and its descendants; verify any namespace scope if you add namespaces later.

### 7.1 Prune — daily at 04:00

PBS GUI: **Datastore > vault-demo > Prune & GC > Prune Jobs > Add**.

| Setting | Case configuration |
| --- | --- |
| Job ID | `prune-vault` (fictional) |
| Datastore | `vault-demo` |
| Namespace | Root; recurse all relevant depths |
| Schedule | Daily **04:00** |
| Keep Last | **2** |
| Keep Daily | **7** |
| Keep Weekly | **4** |
| Keep Monthly | **2** |
| Keep Hourly / Yearly | Unset |

The rules retain different time buckets according to PBS pruning semantics; **they do not mean exactly 2+7+4+2 separate snapshots every day**. Review the prune preview before enabling it. Run the job once and inspect the task log. **Pruning removes backup snapshot references/metadata; GC later removes unreferenced chunks after its safety rules.** [10]

Verify on PBS:

~~~bash
proxmox-backup-manager prune-job list
proxmox-backup-manager prune-job show prune-vault
~~~

### 7.2 Verify — daily at 05:00

PBS GUI: **Datastore > vault-demo > Verify Jobs > Add**.

| Setting | Case configuration |
| --- | --- |
| Job ID | `verify-vault` (fictional) |
| Datastore | `vault-demo` |
| Namespace | Root |
| Schedule | Daily **05:00** |
| Ignore verified | **Enabled** |
| Outdated after | **30 days** |
| Read threads | **1** |
| Verify threads | **2** |

Check using:

~~~bash
proxmox-backup-manager verify-job list
proxmox-backup-manager verify-job show verify-vault
~~~

The observed first manual verification completed with **TASK OK** and **zero errors**. Two backup groups had two snapshots each; the recently verified older snapshots were **SKIPPED**, as configured. This is expected, not missing verification. The 30-day expiry causes old verified snapshots to be reconsidered. A successful verify proves the checked stored data was readable and had valid integrity checks **at that time**; it is not a full disaster-recovery drill. [10]

### 7.3 Garbage collection — Sunday at 06:00

PBS GUI: **Datastore > vault-demo > Prune & GC > Garbage Collection / Schedule > Edit** (or the datastore Options pane, depending on UI release).

Set **Sunday 06:00**. Equivalent documented PBS CLI:

~~~bash
proxmox-backup-manager datastore update vault-demo --gc-schedule 'sun 06:00'
proxmox-backup-manager datastore show vault-demo
~~~

The `gc-schedule` value should be present. The operator reported the GC setup complete; a separate manually executed GC task log was **not** supplied. PBS GC performs its own safe grace-period handling; do not treat it as immediate deletion of all chunks newly orphaned by prune. [10]

## 8. ZFS integrity checks and SMART monitoring

### 8.1 Monthly scrub timer — on PBS

OpenZFS checksums protect **allocated** data. A scrub checks stored blocks across the pool and can reconstruct corrupted data from a healthy mirror copy when possible; it is **not** a destructive bad-sector surface test of 2 TB of free space.

First inspect existing timers:

~~~bash
systemctl list-timers --all 'zfs-scrub*'
~~~

If no monthly scrub timer exists for the backup pool:

~~~bash
TIMER=$(systemd-escape --template=zfs-scrub-monthly@.timer vault-demo)
systemctl enable --now "$TIMER"
systemctl list-timers --all "$TIMER"
~~~

The observed installation created an escaped per-pool timer and scheduled its first run near the start of the next month. Do not assume a timer is already enabled merely because the package is installed. Ensure that monthly scrub I/O does not collide with your busiest backup or verify run.

For an initial on-demand validation:

~~~bash
zpool scrub vault-demo
zpool status -v vault-demo
~~~

Scrubs run asynchronously: the first status output may say `scrub in progress`. Recheck until it says `scrub repaired 0B ... with 0 errors` (the specific numbers can differ) and `errors: No known data errors`. The source case's first scrub finished in **52 seconds**, repaired **0 bytes**, and showed **zero** READ, WRITE and CKSUM counters on both mirror members. At that time only about **6.37 GiB of allocated data** required a scan; it did **not** mean both entire HDD surfaces passed.

### 8.2 SMART daemon and special-case firmware caution

On PBS:

~~~bash
systemctl is-active smartmontools.service
grep -vE '^[[:space:]]*(#|$)' /etc/smartd.conf
journalctl -u smartmontools -n 35 --no-pager
~~~

The initial case configuration used the standard discovery/monitoring pattern:

~~~text
DEVICESCAN -d removable -n standby -m root -M exec /usr/share/smartmontools/smartd-runner
~~~

The logs confirmed both SATA disks and the NVMe were originally discovered. They also contained historical disk errors and changed SMART normalized attributes. **A normalized `Raw_Read_Error_Rate` value change is not itself a count of new bad sectors.** Investigate the actual attributes, pending/uncorrectable counts, temperature and changes in ZFS error counters.

**Exception specific to the documented Samsung F4 EG firmware issue:** because the patch state could not be determined, the operator backed up `/etc/smartd.conf` and added an `ignore` directive **before** the general scan:

~~~text
# Only for the specifically identified potentially affected drive.
# Device names must be rechecked after disk/controller changes.
/dev/sda -d ignore
DEVICESCAN -d removable -n standby -m root -M exec /usr/share/smartmontools/smartd-runner
~~~

After `systemctl restart smartmontools.service`, the **observed journal** confirmed `Device: /dev/sda, ignored` and `Monitoring 1 ATA/SATA, 0 SCSI/SAS and 1 NVMe devices`. This was a deliberately limited **workaround**, **not** a resolution of the firmware defect. It removes SMART coverage of that mirror member, and `/dev/sda` is not a stable drive identity across hardware changes. Do **not** copy this exclusion to a healthy, unrelated disk; validate model/drive mapping and seek a safer lasting hardware/firmware solution. [9]

### 8.3 Alerting decision

The operator **declined email notifications for now**. No successful SMTP/Gotify or end-to-end alert-delivery test was recorded. A running `smartd` service and PVE task text saying `notified via target mail-to-root` **do not prove** that someone actually received the message.

For later implementation: **PBS > Configuration > Notifications** and **PVE > Datacenter > Notifications** are separate systems. Configure a reachable delivery target and send a test. For PBS `system-mail` events, inspect matching rules carefully; do not blindly filter only for `error` if the event's severity is `unknown`. Include a tested disk-health and backup-failure signal.

## 9. Prove backup and recovery

### 9.1 Non-destructive checks first

In PBS, open **Datastore > vault-demo > Content** and check that the expected `ct/<ID>` and `vm/<ID>` groups have recent completed timestamps. Run **Verify** and read its completion status. Confirm PBS free space and `zpool status -v`.

On PVE, read-only example:

~~~bash
pvesm list pbs-vault --content backup
~~~

Record the **exact** actual volume ID returned by PVE; do **not** invent an archive timestamp or paste fictional IDs.

### 9.2 Restore an LXC into a *new unused test ID* (recommended first)

On the PVE host that should run the restored guest, inspect the original backup and current guest configuration. Choose a **free** test ID; check storage capacity, bridge, IP/MAC collisions and bind mounts before starting the restored guest.

~~~bash
pct list
pvesm list pbs-vault --content backup
# Replace everything in angle brackets with locally verified values.
pct restore <UNUSED_TEST_ID> '<EXACT_PBS_BACKUP_VOLUME_ID>' --storage local-lvm --start 0
pct config <UNUSED_TEST_ID>
~~~

Do not start a restored clone on the original guest's static IP, hostname or service ports until duplicates are resolved. Check whether its external host mount points exist and whether `/dev/net/tun` or other device mappings have been preserved. After isolation, start it and check the **application**, not merely the VM/LXC power state.

### 9.3 Destructive original-ID restore — **only in an approved drill**

The source case performed a genuine destructive restore test for a logging LXC: it backed up the guest, exported the guest configuration, shut it down, **destroyed the original container**, restored the specific PBS snapshot into the original ID on local LVM storage, and restarted it. Docker services, MongoDB and OpenSearch volumes under the root filesystem were still present; the logging server subsequently reported **healthy**.

**Never run these steps against a valuable guest just because this guide contains them.** Use the isolated-ID test above for routine assurance. For an explicitly approved destructive drill, the *outline* on the owning PVE node is:

~~~bash
pct config <ORIGINAL_ID> > /root/guest-before-restore.conf
pct shutdown <ORIGINAL_ID> --timeout 180
pct status <ORIGINAL_ID>
# Only after confirming the shutdown, correct verified PBS snapshot,
# configuration export, and rollback plan:
pct destroy <ORIGINAL_ID>
pct restore <ORIGINAL_ID> '<EXACT_PBS_BACKUP_VOLUME_ID>' --storage local-lvm --start 0
pct config <ORIGINAL_ID>
pct start <ORIGINAL_ID>
~~~

Check database/application health, restored records, network settings, bind mounts and permissions. A green task result is necessary but not a substitute for application validation. The source case did **not** independently demonstrate an n8n restore or a full PBS hardware rebuild.

### 9.4 VM recovery

For a VM, use **PVE > storage > Backups > Restore** or the equivalent verified `qmrestore` procedure and choose a **new unused VM ID** for testing. Review firmware (UEFI), EFI disk, TPM state, storage mapping, bridge, backup age and any encrypted guest data. Do not overwrite an existing VM or boot a conflicting clone on the live network.

## 10. Rebuild PBS itself after OS-disk loss

**This is a documented recovery procedure, not a practical drill performed in the case.**

1. Preserve and identify the **existing datastore disks**. **Do not initialize, format, recreate the pool, run destructive badblocks, or click Create ZFS** on them.
2. Install PBS onto a **replacement OS disk only** using Section 1; restore network access and current packages.
3. With the original datastore disks attached, inspect `lsblk`, `zpool import` and `zpool status`. If the pool is visible but not imported, assess the correct pool GUID and import it non-destructively using the platform's OpenZFS instructions. Verify `zfs list`, `findmnt` and the intended existing mount point.
4. Restore PBS configuration from a **separate private** backup if available (access identities, ACLs, datastore metadata, scheduled jobs, certificate/trust and keys), taking care not to overwrite newer settings blindly. If the datastore config is missing, re-register the **existing** mounted datastore path only after confirming the PBS datastore configuration is absent. Do not create a second chunk directory or overwrite `.chunks`.
5. Recreate/rotate backup API credentials as needed, re-check PVE-side storage trust and permissions on **every node**, and validate `pvesm status`, Content, Verify and a **test restore**.
6. If **both** mirror disks have failed or the datastore's data is missing, the ZFS mirror is **not** sufficient. Restore from the separately maintained copy. This original case did not have a proven offsite second copy.

Store a **private**, tested export of necessary `/etc/proxmox-backup/` configuration and recovery information somewhere **other than the PBS OS disk**. This repository must contain **only a description**, never actual secrets or recovered configs.

## 11. End-state checklist and evidence boundaries

| Check | Command / location | What would count as success |
| --- | --- | --- |
| PBS accessible | `https://<PBS_HOST>:8007` | Authenticated UI with expected version |
| Disk mirror | `zpool status -v vault-demo` | `ONLINE`, no unresolved data errors |
| PBS datastore | `proxmox-backup-manager datastore list` | Correct unique path |
| Scoped API token | `proxmox-backup-manager user permissions ...` | `Datastore.Backup` effective |
| PVE host A | `pvesm status --storage pbs-vault` | `active` |
| PVE host B | Same, on the other host | `active` |
| PVE backup jobs | Datacenter > Backup > task logs | Intended guests, `TASK OK` |
| Prune | `prune-job list` / task log | Correct retention and no errors |
| Verify | `verify-job list` / task log | Verified current backups; zero errors |
| GC | `datastore show` / task log | Schedule configured and eventual successful run |
| Monthly scrub | `systemctl list-timers --all 'zfs-scrub*'` | Enabled correct per-pool timer |
| SMART | `smartmontools` journal | Expected disks monitored; documented exceptions |
| Disaster recovery | Isolated restore and app health | Actual recovered data and services |
| Alerting | Deliver an actual test | **Deferred in this case** |
| Independent copy | Separate system / location | **Not demonstrated in this case** |

**Directly observed in the source case:** PBS installed and available; ZFS mirror and datastore online; PVE storage active; two critical LXCs backed up in stop mode; one logging LXC **destroyed and restored successfully**; node-A scheduled job manually run with `TASK OK`; node-B first job completed **five of six** guests and reported an error on one VM; that VM separately passed a snapshot backup; node-B job configuration then changed to snapshot; verify job reported **TASK OK / zero errors**; initial ZFS scrub completed `0B repaired` with zero errors; monthly scrub timer enabled; `smartd` discovered expected disks and later intentionally ignored one firmware-risk model.

**Configured/reported, but not end-to-end proven:** prune schedule, GC schedule, node B's proposed 03:00 schedule, the next overnight scheduled backup cycles, full node-B post-change job success, Tailscale certificate auto-renewal, any alert delivery, an independent offsite copy, PBS OS-disk disaster recovery, and recovery of external media bind-mount data. Do not convert these into completed tests merely because the corresponding UI settings exist.

## 12. Troubleshooting and remaining risks

See the companion **[PBS/PVE backup troubleshooting guide](proxmox-backup-server-troubleshooting.md)** for the actual observed failures and safe decision paths: no-subscription APT 401, certificate hostname verification despite separate successful TLS diagnostics, LXC `vzdumptmp` permission denied caused by a root-shell `umask 0027`, VM shutdown timeout despite `agent: 1`, missing bind-mount data, deduplication/sparse reporting, aged disks, certificate rotation and scheduling collisions.

**Rebuild decision:** use this as a detailed starting procedure, not an unattended install script. Inventory disks and secrets privately, follow version-matched vendor dialogs, verify each boundary, and avoid proceeding past unexplained errors or a proposed destructive action.

## Sources and validation

**Source check date: 2026-11-11.** Source verification confirms vendor-described mechanisms and syntax; the author **did not run any procedure against the operator's machines**. The case's practical results came from operator-supplied task logs and command output. Fictitious IDs, hosts, network addresses and storage names have **not** been deployed or validated.

[1]: https://pbs.proxmox.com/docs/using-the-installer.html
[2]: https://pbs.proxmox.com/docs/installation.html
[3]: https://pbs.proxmox.com/docs/installation.html#proxmox-backup-no-subscription-repository
[4]: https://pbs.proxmox.com/docs/storage.html
[5]: https://pbs.proxmox.com/docs/user-management.html
[6]: https://pbs.proxmox.com/wiki/HTTPS_Certificate_Configuration
[7]: https://tailscale.com/docs/how-to/set-up-https-certificates
[8]: https://pve.proxmox.com/pve-docs/vzdump.1.html
[9]: https://github.com/mirror/smartmontools/blob/master/drivedb.h
[10]: https://pbs.proxmox.com/docs/maintenance.html
[pbs-installer]: https://www.proxmox.com/downloads
