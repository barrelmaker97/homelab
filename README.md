# homelab
GitOps and Ansible for the poseidon homelab cluster and the hosts around it.
Flux deploys everything on the cluster from `kubernetes/`. Ansible, in
`ansible/`, does what Flux cannot: builds and bootstraps the cluster, issues
the local kubeconfig, and manages the DNS and sensor hosts.

# Tools
Every tool is pinned in `mise.toml`, and CI installs from the same file.
[Install mise](https://mise.jdx.dev/installing-mise.html), activate it in your
shell, then from the repository root:
```bash
mise install          # the pinned tools
mise run collections  # the Ansible collections in ansible/requirements.yml
```

Ansible commands and ansible-lint share one Python environment, with
ansible-core pinned once and the Kubernetes Python library installed alongside
it. Python and uv provide the interpreter and installer for that environment.
When updating an existing checkout from the separate Ansible installations,
run `mise install --force pypi:ansible-lint` once to rebuild the environment
with the exposed Ansible commands.

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
`mise run kubernetes:diff --base origin/main --output github`. CI installs only
the tools needed by each job and disables task auto-installation so a check
does not pull in the rest of the workstation tools.

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
- Obscura's dev overlay is its staging environment: a chart update arrives
  for dev first, and for prod in a separate PR three days later. Merge prod's
  only once the version has run in dev.

# Running Playbooks
Playbooks run from `ansible/`, where its `ansible.cfg`, inventory and
`group_vars` apply:
```bash
cd ansible
ansible-playbook user.yaml
ansible-playbook dns.yaml --tags pihole
```

| Playbook        | Targets       | Purpose                                                    |
|-----------------|---------------|------------------------------------------------------------|
| `setup.yaml`    | localhost     | Generate Talos machine configs for the control plane nodes |
| `user.yaml`     | localhost     | Create the cluster user, sign its cert, write a kubeconfig |
| `flux.yaml`     | localhost     | Bootstrap Flux on a cluster that has none                  |
| `dns.yaml`      | `dns_servers` | unbound, Pi-hole and keepalived on the DNS pair            |
| `dewpoint.yaml` | `dns_servers` | The dewpoint Govee sensor Prometheus exporter              |
| `nut.yaml`      | `ups_servers` | The NUT server, on the host the UPS is USB-connected to    |

None of them is meant to run on a schedule. `setup.yaml` mints a fresh Talos
admin certificate and `user.yaml` a fresh client certificate on every run, so
run them when building the cluster or renewing the kubeconfig. `flux.yaml` only
acts on a cluster missing Flux, or one that lost it. `dns.yaml`,
`dewpoint.yaml` and `nut.yaml` support role tags. Run `dns.yaml` one host at a time
(`--limit castor`, then `--limit pollux`): a config change restarts unbound,
and the VIP needs one healthy resolver to stay on.

# Flux
The FluxInstance syncs `kubernetes/clusters/poseidon` from `main` every minute.
Flux manages itself: upgrade Flux or its operator by editing
`flux-system/flux-instance.yaml` or `flux-system/flux-operator.yaml` there.

| Path                                | Contents                                                  |
|-------------------------------------|-----------------------------------------------------------|
| `kubernetes/clusters/poseidon`      | Flux itself (`flux-system/`), chart sources, and one Flux Kustomization per directory below. Settings they all share are a patch in `kustomization.yaml` |
| `kubernetes/infrastructure/<layer>` | Platform layers, ordered bottom up by `dependsOn` in `infrastructure.yaml` |
| `kubernetes/apps/<app>`             | The app's HelmRelease, plus its namespace, database and alerts where it owns them |
| `kubernetes/apps/barrelmaker`       | The namespace most apps share, with its quota and limit range |
| `kubernetes/apps/obscura`           | Obscura as a `base` with `prod` and `dev` overlays; dev is its staging environment (see Updates) |
| `kubernetes/components/helmrelease` | The settings every HelmRelease shares, listed under `components` beside each one |

## How deploys work
- Merging to `main` deploys. Before merge, CI validates every kustomization's
  schema (kubeconform), renders the whole cluster offline the way Flux will,
  charts and post-renderers included
  ([flate](https://github.com/home-operations/flate)), and comments the
  rendered diff on the PR. Preview locally with
  `mise run kubernetes:diff`.
- Manifests hold literal values, apart from a few kustomize patches and
  generators; the rendered diff shows what will actually be applied. The
  settings every HelmRelease shares are one kustomize component,
  `kubernetes/components/helmrelease`, so a HelmRelease file holds only its
  chart, values and `dependsOn`.
- HelmReleases fail forward: a failed install or upgrade is retried as written
  every 15 minutes and never rolled back, so the cluster does not drift from
  Git. Fix forward with a commit, or `git revert`. A StatefulSet stuck on a bad
  pod also needs that pod deleted by hand once the spec is fixed.
- Every HelmRelease reverts changes made by hand to the objects its chart
  manages.
- Infrastructure is never pruned: removing a file does not uninstall it. Every
  chart's CRDs are marked `helm.sh/resource-policy: keep`. Namespaces and database
  Clusters carry `kustomize.toolkit.fluxcd.io/prune: disabled`, so deleting
  their files never deletes their data.
- Failed reconciliations post to Discord. Alertmanager also alerts when a Flux
  object stays not ready or a controller is down (`prometheusrule-flux.yaml`),
  so a broken Flux cannot fail silently.
- Flux cannot be pointed at a branch to test it: it syncs its own FluxInstance,
  which would point it back at `main`. Preview against the cluster with
  `flux diff kustomization` instead.

## CoreDNS availability
Talos bootstraps CoreDNS, including its Deployment, image, Corefile, Service
and RBAC. The `coredns` infrastructure layer manages only a separate
PodDisruptionBudget; it does not modify Talos's Deployment or scheduling rules.

The PDB requires one ready DNS replica during eviction-based maintenance.
Use normal PDB-respecting drains rather than manually deleting CoreDNS pods;
if a drain blocks, recover DNS before proceeding. The PDB does not protect
against node failure, direct deletion or Deployment rolling updates.

Talos's two DNS replicas prefer separate hostnames, but this is not guaranteed.
If both land on one node, the PDB protects a normal drain but not an abrupt
failure of that node. After maintenance or Talos/Kubernetes upgrades, verify
DNS readiness and placement and that the `coredns` Flux Kustomization is healthy.

## Adding an app
1. Create `kubernetes/apps/<app>/` with a `kustomization.yaml` and the app's
   HelmRelease, and `../../components/helmrelease` under `components` in that
   `kustomization.yaml`. Put it in the shared `barrelmaker` namespace, or give
   it its own `namespace.yaml` with `kustomize.toolkit.fluxcd.io/prune: disabled`
   that enforces the `restricted` Pod Security Standard, as the app namespaces
   do. Charts from `charts.barrelmaker.dev` meet it with their default values.
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

# Power
The nodes, pollux, Soteria and the router run off one UPS (CyberPower
CP1500PFCLCDa), USB-connected to pollux; the modem does not. Pollux is the NUT primary, configured by `nut.yaml`; the Talos nodes are
secondaries through the nut-client extension, configured by `setup.yaml`, and
Soteria is one through DSM.

On battery, a power loss plays out as:
1. The driver raises low battery at 600s of runtime or 15% charge, whichever
   comes first, rather than trusting the UPS's own flag.
2. Pollux sets FSD and every secondary starts shutting down.
3. Pollux waits up to 15s for them, shuts itself down and commands killpower.
4. The UPS holds its output for 180s, then cuts it.
5. Once mains returns, it waits 240s and restores output.

A graceful Talos shutdown takes about 70s, so the nodes get roughly 2.5x what
they need. If one ever comes close to 3 minutes, raise `nut_ups_offdelay` and
`nut_ups_runtime_low` together. Pollux boots when power returns; the nodes stay
off and have to be powered on.

DSM cannot set the UPS name or credentials: it always connects to `ups` as
`monuser`, which is why the server keeps both. Point it at pollux under
**Control Panel > Hardware and Power > UPS** as a Synology UPS server.

Check the server and its clients with `upsc ups@pollux.lan` and
`upsc -c ups@pollux.lan`. `sudo upsmon -c fsd` on pollux tests the whole chain
and shuts everything down for real.

# IP Plan
### Cluster
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

### DNS
| Name       | Address       | Hostname   | Role   |
|------------|---------------|------------|--------|
| Virtual IP | 192.168.15.80 |            |        |
| Castor     | 192.168.15.70 | castor.lan | MASTER |
| Pollux     | 192.168.15.30 | pollux.lan | BACKUP |

### Other Hosts
| Name    | Address       | Hostname    | Role                                         |
|---------|---------------|-------------|----------------------------------------------|
| Router  | 192.168.15.1  | openwrt.lan | Router and NTP server                        |
| Soteria | 192.168.15.20 | soteria.lan | NAS: Longhorn backups, Jellyfin media        |
| Demeter | 192.168.15.50 | demeter.lan | Workstation                                  |

# Cluster Bootstrap
1. Generate the Talos machine configs and the ISO link:
   ```bash
   cd ansible
   ansible-playbook setup.yaml
   ```
2. Boot the nodes from the ISO, then apply the configs and bootstrap etcd.
   `setup.yaml` writes the configs to `talos_config_dir`, which defaults to
   `.talos` under the Ansible controller's `HOME` on Linux or macOS. Override
   it with `-e talos_config_dir=/path/to/configs` if needed:
   ```bash
   cd ~/.talos

   # Node 1
   talosctl -n node1-poseidon.lan apply-config --insecure --file node1-poseidon.yaml
   talosctl -n node1-poseidon.lan -e node1-poseidon.lan bootstrap

   # Node 2
   talosctl -n node2-poseidon.lan apply-config --insecure --file node2-poseidon.yaml

   # Node 3
   talosctl -n node3-poseidon.lan apply-config --insecure --file node3-poseidon.yaml
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
Then bump kubectl in `mise.toml` to the new version, and after a minor upgrade
of either, any globally installed talosctl or kubectl too.

# License
GPL-3.0-or-later; see `LICENSE`.
