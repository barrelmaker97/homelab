# homelab

Configuration for the poseidon Talos cluster and its supporting hosts.

- `kubernetes/`: Flux-managed infrastructure and applications.
- `ansible/`: Talos configuration generation, Kubernetes user certificates,
  Flux bootstrap, and services on castor and pollux.
- `mise.toml`: development tools and local validation tasks used by CI.

Talos manages the Kubernetes control plane, flannel, kube-proxy and CoreDNS.
Flux manages the infrastructure and applications declared in this repository.

## Tools and checks

Tool versions are declared in `mise.toml`; CI installs each job's tools from
that file. Ansible collections are pinned in `ansible/requirements.yml`.
[Install mise](https://mise.jdx.dev/installing-mise.html), activate it in your
shell, then from the repository root:

```bash
mise install
mise run collections
```

Local checks and CI use the same mise tasks. These checks do not apply changes
to hosts or the cluster:

```bash
mise run check                # All lint, syntax, schema and rendering checks
mise run ansible:check        # Ansible lint and playbook syntax checks
mise run kubernetes:validate  # Kustomize builds and kubeconform schema validation
mise run kubernetes:render    # Whole-cluster rendering, including Helm charts
mise run kubernetes:diff      # Rendered diff against main
```
Individual Ansible checks are also available as `ansible:lint` and
`ansible:syntax`. Kubernetes checks fetch charts and schemas over the network
but do not require a running cluster or secret decryption. Schema validation
skips Secrets. Rendering is an offline preview, not a comparison with live
cluster state.

The diff task needs the base Git ref locally and accepts flate flags, for example
`mise run kubernetes:diff --base origin/main --output github`.

## Secrets

SOPS encrypts sensitive fields with age using `.sops.yaml`. The personal key,
normally at `~/.config/sops/age/keys.txt`, decrypts all encrypted files.
Kubernetes secrets also use a separate key held in Flux's `sops-age` Secret.
Ansible-only secrets are not encrypted to that key.

Edit encrypted files with `sops <file>`. New `*.sops.yaml` files use the rule
matching their path. Applications reference encrypted Kubernetes Secrets from
their chart values; see `kubernetes/apps/loch` for an example.

## Dependency updates

[Renovate](https://docs.renovatebot.com/) is configured in `renovate.json5`.
Cluster and host dependency updates use PRs. Merging Kubernetes changes makes
them available to Flux; Ansible changes require running the relevant playbook.

- Versions that must move together arrive as one PR: Flux (CLI, FluxInstance,
  operator), Talos (talosctl and `talos_version`), CloudNativePG (chart and
  kubectl plugin).
- Major updates require approval in the Dependency Dashboard.
- kubectl gets patches only; minor upgrades follow the cluster upgrade.
- PostgreSQL major versions are disabled: they are data migrations.
- Obscura's dev overlay is its test deployment. Dev and prod updates get separate
  PRs. Prod requires an upstream release age of three days, not three days in
  dev; verify it in dev before promotion. PostgreSQL images bypass the age check
  when no release timestamp is available.
- Minor, patch and digest updates to ungrouped tooling in `mise.toml` and
  GitHub Actions are eligible for branch automerge after CI passes, on Mondays.
  The tools grouped with Flux, Talos and CloudNativePG still use PRs.

## Ansible

Playbooks run from `ansible/`, where its `ansible.cfg`, inventory and
`group_vars` apply:

```bash
cd ansible
ansible-playbook user.yaml
ansible-playbook dns.yaml --tags pihole
```

| Playbook             | Targets                      | Purpose                                                    |
|----------------------|------------------------------|------------------------------------------------------------|
| `setup.yaml`         | localhost                    | Generate Talos machine configs for the control plane nodes |
| `user.yaml`          | localhost                    | Issue a cluster-admin certificate and kubeconfig          |
| `flux.yaml`          | localhost                    | Bootstrap Flux on a cluster that has none                  |
| `dns.yaml`           | `dns_servers`                | Install unbound, Pi-hole and keepalived                    |
| `dewpoint.yaml`      | `dns_servers`                | Install the dewpoint Govee sensor exporter                 |
| `node_exporter.yaml` | `dns_servers`                | Install the Prometheus node exporter                       |
| `nut.yaml`           | `ups_servers`, `ups_clients` | Run the NUT server on the UPS host, and its secondaries    |
| `ssh.yaml`           | `dns_servers`                | Harden the OpenSSH server configuration                    |
| `wireguard.yaml`     | `vpn_servers`                | Run the WireGuard VPN server                               |

`setup.yaml` generates machine configs; it does not apply them or bootstrap
etcd. A full run also generates a Talos admin certificate and merges a context
into `~/.talos/config`. Use `--tags configs` to generate only machine configs.

`user.yaml` replaces the local kubeconfig and requests a new client certificate
with a 30-day lifetime. It requires working Talos access and local privilege
escalation. `flux.yaml` installs the operator and FluxInstance only if missing,
but always reconciles the namespace and SOPS key Secret. Host playbooks tag
their roles by name, such as `--tags pihole`.

## Kubernetes

### Flux and repository layout

The FluxInstance syncs `kubernetes/clusters/poseidon` from `main`.
Flux manages itself: upgrade Flux or its operator by editing
`flux-system/flux-instance.yaml` or `flux-system/flux-operator.yaml` there.

| Path                                | Contents                                                                                    |
|-------------------------------------|---------------------------------------------------------------------------------------------|
| `kubernetes/clusters/poseidon`      | Flux itself (`flux-system/`), chart sources, and the infrastructure/app Flux Kustomizations |
| `kubernetes/infrastructure/<layer>` | Platform layers, ordered bottom up by `dependsOn` in `infrastructure.yaml`                  |
| `kubernetes/apps/<app>`             | Application manifests, including HelmReleases, routes and owned resources                 |
| `kubernetes/apps/barrelmaker`       | The namespace most apps share                                                               |
| `kubernetes/apps/obscura`           | Obscura's shared `base` and `prod`/`dev` overlays                                           |
| `kubernetes/components/helmrelease` | Shared HelmRelease reconciliation settings                                                  |

### Deployment behavior

- Flux reconciles Kubernetes changes merged to `main`. CI validates manifests
  with kubeconform and renders charts and post-renderers with
  [flate](https://github.com/home-operations/flate). Nonempty rendered diffs are
  posted on PRs; encrypted values and live state are not verified.
- Infrastructure and app Flux Kustomizations reconcile every 10 minutes and
  wait for their resources to become healthy. `dependsOn` controls ordering.
- HelmReleases use `RetryOnFailure`: failed installs or upgrades are retried
  every 15 minutes rather than rolled back or uninstalled. Correct the
  manifests or revert the commit. A StatefulSet stuck on a bad pod may also
  need that pod deleted after the spec is fixed.
- HelmRelease drift detection reverts manual changes to chart-managed objects.
- Infrastructure Flux Kustomizations have `prune: false`; removing a manifest
  does not delete its applied resource. This does not prevent Helm upgrades
  from removing chart resources. Chart-rendered CRDs are marked
  `helm.sh/resource-policy: keep`. App namespaces and
  database Clusters carry `kustomize.toolkit.fluxcd.io/prune: disabled`, so
  removing those manifests does not prune those objects. These settings are
  not backups.
- Failed reconciliations post to Discord. Alertmanager also alerts when a Flux
  object stays not ready or a controller is down (`prometheusrule-flux.yaml`).
- A manual branch override is not persistent: Flux syncs its own FluxInstance
  from Git, which specifies `main`. Preview against the cluster with
  `flux diff kustomization` instead.

### CoreDNS

Talos owns CoreDNS; this repository adds a PodDisruptionBudget with
`minAvailable: 1`. If a drain blocks, restore a ready replica rather than
overriding the budget. The budget does not prevent node failures or control
replica placement; check readiness and node distribution after maintenance.

### Telemetry

The OpenTelemetry collector accepts OTLP over gRPC (4317) and HTTP (4318),
routing traces to Tempo, logs to Loki and metrics to Prometheus. Prometheus
also scrapes configured cluster and host exporters.

### Network policy

The Talos machine config enables kube-network-policies alongside flannel.
There is no repository-wide default-deny policy. Configure chart-provided
policies through chart values; add access between components in manifests
beside the release. Longhorn's `networkpolicy.yaml` permits Prometheus scraping
and gateway access to its UI. NetworkPolicy allow rules are additive.

Inspect dropped traffic with:

```bash
kubectl -n kube-system logs -f -l k8s-app=flannel -c kube-network-policies \
  --max-log-requests=3 | grep -B8 'verdict="drop"'
```

### Adding an app

1. Create `kubernetes/apps/<app>/` with a `kustomization.yaml` and the app's
   HelmRelease, and `../../components/helmrelease` under `components` in that
   `kustomization.yaml`. Put it in the shared `barrelmaker` namespace, or give
   it its own `namespace.yaml` with
   `kustomize.toolkit.fluxcd.io/prune: disabled` that enforces the `restricted`
   Pod Security Standard. Verify that the chart's pod settings meet it.
2. Add a Flux Kustomization for it to `kubernetes/clusters/poseidon/apps.yaml`,
   with `prune: true` and the `dependsOn` its resources need (listed at the top
   of that file).
3. Declare any required Helm/OCI source in
   `kubernetes/clusters/poseidon/repositories.yaml`.
4. Add encrypted Kubernetes Secrets and reference them through the chart's
   existing-secret settings.

### Routine operations

```bash
flux get all -A                                   # Status of every Flux object
flux reconcile kustomization obscura-dev --with-source  # Apply now instead of waiting
flux diff kustomization obscura-dev --path kubernetes/apps/obscura/dev  # Preview local changes
flux suspend helmrelease obscura -n obscura-dev   # Pause while fixing by hand
flux resume helmrelease obscura -n obscura-dev
flux events -A                                    # Why something is not Ready
```

### Storage and backups

- Volumes on `longhorn-protected`, the default storage class, are snapshotted
  hourly (24 kept) and backed up daily at 12:00 (30 kept) to the NAS at
  `nfs://soteria.lan:/volume1/longhorn-backupstore`.
- The Prometheus volume (`longhorn-monitoring`) is not backed up.
- The CloudNativePG databases (`longhorn-cnpg-local`) have no configured backups:
  replication protects against losing a node, not against losing data.
- The Jellyfin media library lives on the NAS itself.
- Loki and Tempo retain 30 days of logs and traces on PVCs; no object storage
  is configured.

## Supporting hosts

### UPS and shutdown

The nodes, castor, pollux, soteria and the router run off one UPS (CyberPower
CP1500PFCLCDa), USB-connected to castor; the modem does not. Castor is the NUT
primary, configured by `nut.yaml`. The secondaries are the Talos nodes, through
the nut-client extension configured by `setup.yaml`; pollux, through the
`nut_client` role in `nut.yaml`; and soteria, through DSM.

The configured shutdown sequence is:
1. The driver raises low battery at 600s of runtime or 15% charge, whichever
   comes first, rather than trusting the UPS's own flag.
2. Castor sets FSD and every secondary starts shutting down.
3. Castor waits up to 15s for them, shuts itself down and commands killpower.
4. The UPS holds its output for 180s, then cuts it.
5. Once mains returns, it waits 240s and restores output.

Allow enough time for the slowest secondary to shut down before the UPS cuts
output. Check actual shutdown times before changing `nut_ups_offdelay` or
`nut_ups_runtime_low`. Power-on behavior after an outage depends on each
device's firmware settings.

The server provides the `ups` device and `monuser` account for DSM.
Point DSM at castor under
**Control Panel > Hardware and Power > UPS** as a Synology UPS server.

Check the server and its clients with `upsc ups@castor.lan` and
`upsc -c ups@castor.lan`.

**Shutdown test:** `sudo upsmon -c fsd` on castor shuts down the entire chain
and cuts UPS output. Run it only during a planned maintenance window.

### DNS

Castor and pollux each run Pi-hole on port 53, which forwards to its own
unbound, a recursive, DNSSEC-validating resolver on port 5335. The DNS entry
point is the VIP (`192.168.15.80`), which keepalived prefers on castor. Every
3 seconds keepalived checks each host: Pi-hole and unbound both resolve a name,
and `wg0` is up. A check that fails twice in a row takes 60 off that host's
priority (castor 150, pollux 100). A failing check on castor moves the VIP to
pollux if pollux is healthy; castor takes it back after recovery.

`dns.yaml` installs Pi-hole once and manages it from
`ansible/roles/pihole/defaults/main.yml`. It reconciles adlists, groups, clients
and domain rules to that file, removing unmanaged entries; edit it rather than
the web UI. Local records come from `lan_hosts`.
Run `dns.yaml` one host at a time (`--limit castor`, then `--limit pollux`): a
config change restarts unbound, and the VIP needs one healthy resolver to stay
up. Ansible never upgrades Pi-hole; do that with `sudo pihole -up`, one host at
a time.

### VPN

Castor and pollux are both WireGuard servers on UDP 51820, with the same keys
and peers, configured by `wireguard.yaml`. The router forwards the port to the
DNS VIP, so new connections reach whichever host holds it. A failed `wg0`
also affects VIP priority. Both servers are `10.33.167.1`; clients use
`10.33.167.0/24` and the VIP for DNS. Each host masquerades IPv4 tunnel traffic
out of `eth0`; IPv6 routing is not configured.

VIP failover does not transfer WireGuard session state; clients must
re-establish sessions with the other host. Changes to the address, MTU or NAT
settings restart WireGuard and interrupt clients; key and peer changes use
`wg syncconf`.

The server's and peers' keys are in `ansible/vars/wireguard.sops.yaml`; the
peer list and addresses are in `ansible/vars/wireguard.yaml`. To add a client:
1. On the workstation, generate its keys with
   `umask 077; wg genkey | tee client.key | wg pubkey` and `wg genpsk`.
2. Add its public and preshared keys under its name in `wireguard.sops.yaml`
   (`sops ansible/vars/wireguard.sops.yaml`), and the name with the next free
   `/32` to `wireguard_peers`.
3. From `ansible/`, run `ansible-playbook wireguard.yaml`.
4. Give the client a config with its private key, `Address = <its IP>/24`,
   `DNS = 192.168.15.80`, and a `[Peer]` with the server's public key
   (`sudo wg show wg0 public-key` on either host), the preshared key,
   `Endpoint = <public hostname>:51820` and `AllowedIPs = 0.0.0.0/0, ::/0`.
   This routes IPv6 into the tunnel without providing IPv6 connectivity.
   For a phone, display the config with `qrencode -t ansiutf8 < client.conf`.

To remove a client, delete it from both files and run the playbook.

## IP plan

`lan_hosts` in `ansible/group_vars/all.yaml` holds named LAN addresses;
`dns_vip` is defined separately in the same file. The inventory, Talos VIP,
NUT and NTP use these variables, and Pi-hole serves each `lan_hosts` entry as
`<name>.lan`. Change an address there, then run `dns.yaml` and whichever
playbook uses it. Kubernetes manifests (MetalLB, the gateway, scrape targets,
etcd endpoints) keep their own copies.

### Cluster

| Name             | Address                     | Hostname           |
|------------------|-----------------------------|--------------------|
| Virtual IP       | 192.168.15.40               | kube.poseidon.lan  |
| Node 1           | 192.168.15.41               | node1-poseidon.lan |
| Node 2           | 192.168.15.42               | node2-poseidon.lan |
| Node 3           | 192.168.15.43               | node3-poseidon.lan |
| MetalLB pool     | 192.168.15.60-192.168.15.69 |                    |
| Public gateway   | 192.168.15.60               |                    |
| Valheim          | 192.168.15.61               |                    |
| Niucraft         | 192.168.15.62               |                    |
| Loch             | 192.168.15.63               |                    |
| Internal gateway | 192.168.15.64               | poseidon.lan       |

### Hosts

| Host    | Address       | Role                                     |
|---------|---------------|------------------------------------------|
| openwrt | 192.168.15.1  | Router and NTP server                    |
| soteria | 192.168.15.20 | NAS: Longhorn backups, Jellyfin media    |
| pollux  | 192.168.15.30 | DNS and VPN (VRRP backup), NUT secondary |
| demeter | 192.168.15.50 | Workstation                              |
| castor  | 192.168.15.70 | DNS and VPN (VRRP master), NUT primary   |
| DNS VIP | 192.168.15.80 | Held by castor or pollux; no name        |

## Cluster lifecycle

### Bootstrap

1. Generate the Talos machine configs and the ISO link:
   ```bash
   cd ansible
   ansible-playbook setup.yaml
   ```
2. Boot the nodes from the ISO, then apply the configs and bootstrap etcd.
   `setup.yaml` writes configs to `~/.talos` by default; override it with
   `-e talos_config_dir=/path/to/configs` if needed. Set `CONFIG_DIR` to the
   chosen path:
   ```bash
   CONFIG_DIR="$HOME/.talos"

   # Node 1
   talosctl -n node1-poseidon.lan apply-config --insecure --file "$CONFIG_DIR/node1-poseidon.yaml"

   # Node 2
   talosctl -n node2-poseidon.lan apply-config --insecure --file "$CONFIG_DIR/node2-poseidon.yaml"

   # Node 3
   talosctl -n node3-poseidon.lan apply-config --insecure --file "$CONFIG_DIR/node3-poseidon.yaml"

   # Bootstrap etcd once, after the nodes have applied their configs
   talosctl -n node1-poseidon.lan -e node1-poseidon.lan bootstrap
   ```
3. Create the cluster user and the local kubeconfig, from `ansible/`:
   ```bash
   ansible-playbook user.yaml
   ```
4. Bootstrap Flux. It then builds the platform layer by layer, in the
   `dependsOn` order of `infrastructure.yaml`, and the apps on top:
   ```bash
   ansible-playbook flux.yaml
   flux get kustomizations --watch
   ```

### Node configuration

`ansible-playbook setup.yaml --tags configs` writes only machine configs,
without a new certificate or talosconfig context. `mise run talos:diff`
generates them in a temporary directory and dry-runs each against its node,
redacting certificates, keys and tokens from the diff. It needs the personal
age key and a working talosconfig.

Apply configs one drained node at a time. After network changes, reboot and
verify the node's addresses and readiness before uncordoning.

To reconcile changes to Talos-managed Kubernetes manifests (flannel,
kube-proxy and CoreDNS), run
`talosctl upgrade-k8s --to <current Kubernetes version>`, first with `--dry-run`.

### Upgrades

Renovate opens one PR for a new Talos release, bumping `talos_version` and
talosctl together. Merge it, `mise install`, then upgrade the nodes.

#### Talos

Upgrade one node at a time, each through another node's endpoint, and wait for
the node to rejoin and every workload to be healthy before the next.
`mise run talos:image` prints the installer image for the merged version:
```bash
IMAGE=$(mise run -q talos:image)
talosctl -e node2-poseidon.lan -n node1-poseidon.lan upgrade --image "$IMAGE"
talosctl -e node1-poseidon.lan -n node2-poseidon.lan upgrade --image "$IMAGE"
talosctl -e node1-poseidon.lan -n node3-poseidon.lan upgrade --image "$IMAGE"
```

#### Kubernetes

```bash
talosctl -n node1-poseidon.lan upgrade-k8s --dry-run
talosctl -n node1-poseidon.lan upgrade-k8s
```
Then bump kubectl in `mise.toml` to the new version and run `mise install`.

## License

GPL-3.0-or-later; see `LICENSE`.
