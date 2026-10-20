# homelab
GitOps and Ansible for the poseidon homelab cluster and the hosts around it.
Flux deploys everything on the cluster from `kubernetes/`. Ansible, in
`ansible/`, does what Flux cannot: builds and bootstraps the cluster, issues
the local kubeconfig, and manages castor and pollux: DNS, VPN, UPS and sensors.

# Tools
Every tool is pinned in `mise.toml`, and CI installs from the same file.
[Install mise](https://mise.jdx.dev/installing-mise.html), activate it in your
shell, then from the repository root:
```bash
mise install          # the pinned tools
mise run collections  # the Ansible collections in ansible/requirements.yml
```

## Checks
Local checks and CI run the same mise tasks. No check applies changes to hosts
or the cluster:
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
skips Secrets, as in CI.

The diff task accepts flate flags, for example
`mise run kubernetes:diff --base origin/main --output github`.

# Secrets
Secrets are sops files encrypted with age (rules in `.sops.yaml`). The personal
key, expected at `~/.config/sops/age/keys.txt`, decrypts all of them. Files
under `kubernetes/` are also encrypted to a cluster-only key, which Flux holds
as the `sops-age` Secret; it cannot decrypt anything outside `kubernetes/`.
Edit one with `sops <file>`; a new `*.sops.yaml` file picks up the right keys
from its path.

A Helm values file with secrets stays a sops file in Git: a kustomize
`secretGenerator` turns it into a Secret that the HelmRelease reads through
`valuesFrom` (see `kubernetes/apps/loch`).

# Updates
[Renovate](https://docs.renovatebot.com/) (`renovate.json5`) opens a PR for
every pinned version in the repository. Each PR gets the usual checks and
rendered diff, and merging deploys it; nothing automerges.

- Versions that must move together arrive as one PR: Flux (CLI, FluxInstance,
  operator), Talos (talosctl and `talos_version`), CloudNativePG (chart and
  kubectl plugin).
- Major updates wait on the Dependency Dashboard issue until ticked.
- kubectl gets patches only; it follows the cluster (see Cluster Upgrade).
- PostgreSQL major versions are disabled: they are data migrations.
- Obscura's dev overlay is its staging environment. Dev and prod chart updates
  get separate PRs; prod waits until the upstream release is at least three
  days old, not three days after deployment to dev. Merge prod's only once the
  version has run in dev.

# Running Playbooks
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
| `user.yaml`          | localhost                    | Create the cluster user, sign its cert, write a kubeconfig |
| `flux.yaml`          | localhost                    | Bootstrap Flux on a cluster that has none                  |
| `dns.yaml`           | `dns_servers`                | Install unbound, Pi-hole and keepalived                    |
| `dewpoint.yaml`      | `dns_servers`                | Install the dewpoint Govee sensor exporter                 |
| `node_exporter.yaml` | `dns_servers`                | Install the Prometheus node exporter                       |
| `nut.yaml`           | `ups_servers`, `ups_clients` | Run the NUT server on the UPS host, and its secondaries    |
| `wireguard.yaml`     | `vpn_servers`                | Run the WireGuard VPN server                               |

None of them is meant to run on a schedule. Every run of `setup.yaml` mints a
fresh Talos admin certificate and adds another context to `~/.talos/config`,
unless it runs with `--tags configs` (see Node Configs), and every run of
`user.yaml` a fresh client certificate, so run them when building the cluster
or renewing the kubeconfig. `flux.yaml` only acts on a
cluster missing Flux, or one that lost it. Each host playbook tags its roles by
name, as in `--tags pihole`.

# Cluster
## Flux
The FluxInstance syncs `kubernetes/clusters/poseidon` from `main` every minute.
Flux manages itself: upgrade Flux or its operator by editing
`flux-system/flux-instance.yaml` or `flux-system/flux-operator.yaml` there.

| Path                                | Contents                                                                                    |
|-------------------------------------|---------------------------------------------------------------------------------------------|
| `kubernetes/clusters/poseidon`      | Flux itself (`flux-system/`), chart sources, and the infrastructure/app Flux Kustomizations |
| `kubernetes/infrastructure/<layer>` | Platform layers, ordered bottom up by `dependsOn` in `infrastructure.yaml`                  |
| `kubernetes/apps/<app>`             | The app's HelmRelease, plus its namespace, database and alerts where it owns them           |
| `kubernetes/apps/barrelmaker`       | The namespace most apps share, with its quota and limit range                               |
| `kubernetes/apps/obscura`           | Obscura's shared `base` and `prod`/`dev` overlays                                           |
| `kubernetes/components/helmrelease` | Shared HelmRelease reconciliation settings                                                  |

## How deploys work
- Merging to `main` deploys. Before merge, CI validates every kustomization's
  schema (kubeconform), renders the whole cluster offline the way Flux will,
  charts and post-renderers included
  ([flate](https://github.com/home-operations/flate)), and comments the
  rendered diff on the PR. Preview locally with
  `mise run kubernetes:diff`.
- Manifests hold literal values, apart from a few kustomize patches and
  generators; the rendered diff shows what will actually be applied.
- HelmReleases fail forward: a failed install or upgrade is retried as written
  every 15 minutes and never rolled back, so the cluster does not drift from
  Git. Fix forward with a commit, or `git revert`. A StatefulSet stuck on a bad
  pod also needs that pod deleted by hand once the spec is fixed.
- Every HelmRelease reverts changes made by hand to the objects its chart
  manages.
- Infrastructure is never pruned: removing a file does not uninstall it. Every
  chart's CRDs are marked `helm.sh/resource-policy: keep`. Namespaces and
  database Clusters carry `kustomize.toolkit.fluxcd.io/prune: disabled`, so
  deleting their files never deletes their data.
- Failed reconciliations post to Discord. Alertmanager also alerts when a Flux
  object stays not ready or a controller is down (`prometheusrule-flux.yaml`).
- Flux cannot be pointed at a branch to test it: it syncs its own FluxInstance,
  which would point it back at `main`. Preview against the cluster with
  `flux diff kustomization` instead.

## CoreDNS
Talos owns CoreDNS; this repo only adds a PodDisruptionBudget keeping one
replica ready through drains. If a drain blocks on it, get the other replica
ready rather than overriding the PDB. It does not cover node failure or
rollouts, and both replicas can land on one node, so after maintenance check
that both are ready, on separate nodes.

## Telemetry
Apps send OTLP to the OpenTelemetry collector, which routes traces to Tempo,
logs to Loki, and metrics to Prometheus.

## Network policy
kube-network-policies, running beside flannel, enforces standard
NetworkPolicy; there is no cluster-wide policy. Policies only add access, so
a chart's policy cannot be narrowed by another one, only through its values.

- A chart's policies cover traffic between its own components (Longhorn,
  Flux), tuned through its values.
- `networkpolicy.yaml` beside a release covers traffic between components:
  the gateway to an app, Prometheus to its targets, an app to its database.
- A chart policy that needs every rule written into its values is left off
  in favour of `networkpolicy.yaml`.

Policy applies to traffic from other nodes' hosts, such as an API server
calling a webhook, which arrives from that node's `flannel.1` address
(`10.244.<n>.0`), but not to a node's traffic to its own pods, such as kubelet
probes. Webhook ports stay open to every pod rather than listing those
addresses, which change when a node is replaced, since a missed one fails
API requests at random. Only new connections are checked, so after a change, restart a
client to test it. Drops are logged, and the logs turn over within minutes:

```bash
kubectl -n kube-system logs -f -l k8s-app=flannel -c kube-network-policies \
  --max-log-requests=3 | grep -B8 'verdict="drop"'
```

## Adding an app
1. Create `kubernetes/apps/<app>/` with a `kustomization.yaml` and the app's
   HelmRelease, and `../../components/helmrelease` under `components` in that
   `kustomization.yaml`. Put it in the shared `barrelmaker` namespace, or give
   it its own `namespace.yaml` with
   `kustomize.toolkit.fluxcd.io/prune: disabled` that enforces the `restricted`
   Pod Security Standard, as the app namespaces do. Charts from
   `charts.barrelmaker.dev` meet it with their default values.
2. Add a Flux Kustomization for it to `kubernetes/clusters/poseidon/apps.yaml`,
   with `prune: true` and the `dependsOn` its resources need (listed at the top
   of that file).
3. For secrets in its values, add a `values.sops.yaml` and a `secretGenerator`,
   as in Secrets above.

## Day to day
```bash
flux get all -A                                   # Status of every Flux object
flux reconcile kustomization obscura-dev --with-source  # Apply now instead of waiting
flux diff kustomization obscura-dev --path kubernetes/apps/obscura/dev  # Preview local changes
flux suspend helmrelease obscura -n obscura-dev   # Pause while fixing by hand
flux resume helmrelease obscura -n obscura-dev
flux events -A                                    # Why something is not Ready
```

# Backups
- Volumes on `longhorn-protected`, the default storage class, are snapshotted
  hourly (24 kept) and backed up daily at 12:00 (30 kept) to the NAS at
  `nfs://soteria.lan:/volume1/longhorn-backupstore`.
- The Prometheus volume (`longhorn-monitoring`) is not backed up.
- The CloudNativePG databases (`longhorn-cnpg-local`) are not backed up:
  replication protects against losing a node, not against losing data.
- The Jellyfin media library lives on the NAS itself.
- Loki and Tempo retain 30 days of logs and traces on PVCs; no object storage
  is configured.

# Power
The nodes, castor, pollux, soteria and the router run off one UPS (CyberPower
CP1500PFCLCDa), USB-connected to castor; the modem does not. Castor is the NUT
primary, configured by `nut.yaml`. The secondaries are the Talos nodes, through
the nut-client extension configured by `setup.yaml`; pollux, through the
`nut_client` role in `nut.yaml`; and soteria, through DSM.

On battery, a power loss plays out as:
1. The driver raises low battery at 600s of runtime or 15% charge, whichever
   comes first, rather than trusting the UPS's own flag.
2. Castor sets FSD and every secondary starts shutting down.
3. Castor waits up to 15s for them, shuts itself down and commands killpower.
4. The UPS holds its output for 180s, then cuts it.
5. Once mains returns, it waits 240s and restores output.

A graceful Talos shutdown takes about 70s, so the nodes get roughly 2.5x what
they need. If one ever comes close to 3 minutes, raise `nut_ups_offdelay` and
`nut_ups_runtime_low` together. Castor and pollux boot when power returns; the
nodes stay off and have to be powered on.

DSM cannot set the UPS name or credentials: it always connects to `ups` as
`monuser`, which is why the server keeps both. Point it at castor under
**Control Panel > Hardware and Power > UPS** as a Synology UPS server.

Check the server and its clients with `upsc ups@castor.lan` and
`upsc -c ups@castor.lan`. `sudo upsmon -c fsd` on castor tests the whole chain
and shuts everything down for real.

# DNS
Castor and pollux each run Pi-hole on port 53, which forwards to its own
unbound, a recursive, DNSSEC-validating resolver on port 5335. LAN clients,
the cluster nodes and both hosts themselves resolve through the VIP
(`192.168.15.80`), which keepalived keeps on castor while it is healthy. Every
3 seconds keepalived checks each host: Pi-hole and unbound both resolve a name,
and `wg0` is up. A check that fails twice in a row takes 60 off that host's
priority (castor 150, pollux 100), so a single failing check on castor moves
the VIP to pollux, and it moves back once castor passes again.

`dns.yaml` installs Pi-hole once and manages it from
`ansible/roles/pihole/defaults/main.yml`. Adlists, groups, clients and domain
rules that are not in that file are deleted on the next run, so change them
there, not in the web UI. Local records come from `lan_hosts` (see IP Plan).
Run `dns.yaml` one host at a time (`--limit castor`, then `--limit pollux`): a
config change restarts unbound, and the VIP needs one healthy resolver to stay
up. Ansible never upgrades Pi-hole; do that with `sudo pihole -up`, one host at
a time.

# VPN
Castor and pollux are both WireGuard servers on UDP 51820, with the same keys
and peers, configured by `wireguard.yaml`. The router forwards the port to the
DNS VIP, so the VPN runs on whichever host holds it, and a failed `wg0` moves
the VIP too (see DNS). Both servers are `10.33.167.1`; clients get an address
in `10.33.167.0/24`, send all their traffic through the tunnel, and use the VIP
for DNS. Each host masquerades their traffic out of `eth0`.

When the VIP moves, clients reconnect to the other host in about 20 seconds:
WireGuard starts a new handshake once 15 seconds of traffic go unanswered.
A host that loses the VIP while still running can keep its clients, since
WireGuard follows a peer that answers from a new address; using the VIP for
DNS keeps their queries working either way. Changes to the address, MTU or
NAT settings restart WireGuard, dropping clients for about 15 seconds; key and
peer changes reload it without dropping them.

The server's and peers' keys are in `ansible/vars/wireguard.sops.yaml`; the
peer list and addresses are in `ansible/vars/wireguard.yaml`. To add a client:
1. On the workstation, generate its keys with
   `wg genkey | tee client.key | wg pubkey` and `wg genpsk`.
2. Add its public and preshared keys under its name in `wireguard.sops.yaml`
   (`sops ansible/vars/wireguard.sops.yaml`), and the name with the next free
   `/32` to `wireguard_peers`.
3. Run `ansible-playbook wireguard.yaml`.
4. Give the client a config with its private key, `Address = <its IP>/24`,
   `DNS = 192.168.15.80`, and a `[Peer]` with the server's public key
   (`sudo wg show wg0 public-key` on either host), the preshared key,
   `Endpoint = <public hostname>:51820` and `AllowedIPs = 0.0.0.0/0, ::/0`.
   Show it as a QR code for a phone with `qrencode -t ansiutf8 < client.conf`.

To remove a client, delete it from both files and run the playbook.

# IP Plan
`lan_hosts` in `ansible/group_vars/all.yaml` holds every address Ansible uses:
the inventory, the VIPs, NUT and NTP read it, and Pi-hole serves each entry as
`<name>.lan`. Change an address there, then run `dns.yaml` and whichever
playbook uses it. Kubernetes manifests (MetalLB, the gateway, scrape targets,
etcd endpoints) keep their own copies.

## Cluster
| Name         | Address                     | Hostname           |
|--------------|-----------------------------|--------------------|
| Virtual IP   | 192.168.15.40               | kube.poseidon.lan  |
| Node 1       | 192.168.15.41               | node1-poseidon.lan |
| Node 2       | 192.168.15.42               | node2-poseidon.lan |
| Node 3       | 192.168.15.43               | node3-poseidon.lan |
| MetalLB pool | 192.168.15.60-192.168.15.69 |                    |
| Gateway      | 192.168.15.60               | poseidon.lan       |
| Valheim      | 192.168.15.61               |                    |
| Niucraft     | 192.168.15.62               |                    |
| Loch         | 192.168.15.63               |                    |

## Hosts
| Host    | Address       | Role                                     |
|---------|---------------|------------------------------------------|
| openwrt | 192.168.15.1  | Router and NTP server                    |
| soteria | 192.168.15.20 | NAS: Longhorn backups, Jellyfin media    |
| pollux  | 192.168.15.30 | DNS and VPN (VRRP backup), NUT secondary |
| demeter | 192.168.15.50 | Workstation                              |
| castor  | 192.168.15.70 | DNS and VPN (VRRP master), NUT primary   |
| DNS VIP | 192.168.15.80 | Held by castor or pollux; no name        |

# Cluster Bootstrap
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
   talosctl -n node1-poseidon.lan -e node1-poseidon.lan bootstrap

   # Node 2
   talosctl -n node2-poseidon.lan apply-config --insecure --file "$CONFIG_DIR/node2-poseidon.yaml"

   # Node 3
   talosctl -n node3-poseidon.lan apply-config --insecure --file "$CONFIG_DIR/node3-poseidon.yaml"
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

# Node Configs
`setup.yaml --tags configs` writes only the machine configs, without a new
certificate or talosconfig context. `mise run talos:diff` generates them into
a temporary directory and dry-runs each against its node, showing what
`talosctl apply-config` would change, with certificates, keys and tokens
redacted. It needs the personal age key and a working talosconfig.

Apply a config to a drained node and reboot it before uncordoning. Network
changes in particular: if they briefly drop the node's DHCP address, Talos
picks a new default address and can settle on flannel's `cni0` bridge, which
lands in the node's `/etc/hosts` until the next boot.

Talos applies the manifests it owns (flannel, kube-proxy, CoreDNS) only when
they are missing, so a config change to them reaches the cluster through
`talosctl upgrade-k8s --to <current Kubernetes version>`, after `--dry-run`.

# Cluster Upgrade
Renovate opens one PR for a new Talos release, bumping `talos_version` and
talosctl together. Merge it, `mise install`, then upgrade the nodes.

## Upgrade Talos
Upgrade one node at a time, each through another node's endpoint, and wait for
the node to rejoin and every workload to be healthy before the next.
`mise run talos:image` prints the installer image for the merged version:
```bash
IMAGE=$(mise run -q talos:image)
talosctl -e node2-poseidon.lan -n node1-poseidon.lan upgrade --image "$IMAGE"
talosctl -e node1-poseidon.lan -n node2-poseidon.lan upgrade --image "$IMAGE"
talosctl -e node1-poseidon.lan -n node3-poseidon.lan upgrade --image "$IMAGE"
```

## Upgrade Kubernetes
```bash
talosctl -n node1-poseidon.lan upgrade-k8s --dry-run
talosctl -n node1-poseidon.lan upgrade-k8s
```
Then bump kubectl in `mise.toml` to the new version and run `mise install`.

# License
GPL-3.0-or-later; see `LICENSE`.
