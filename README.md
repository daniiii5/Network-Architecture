# 🌐 Global Network Infrastructure Documentation

![Network Diagram](./NETWORK%20V5.svg)

## 📚 Table of Contents

- [🧠 Logical Architecture: "Hub-and-Spoke" & Zero Trust](#-logical-architecture-hub-and-spoke--zero-trust)
- [🗺️ Address Map](#️-address-map)
- [🚦 Traffic Flow & Key Concepts](#-traffic-flow--key-concepts)
- [☁️ Node 1: VPS Strato (The Gateway)](#️-node-1-vps-strato-the-gateway)
- [🏗️ Node 2: Geekom / Unraid (The Core)](#️-node-2-geekom--unraid-the-core)
- [🎮 Node 3: Dock VM (Pelican + Wings)](#-node-3-dock-vm-pelican--wings)
- [🗄️ Databases](#️-databases)
- [🧪 Verification Playbook](#-verification-playbook)
- [⚠️ Known Gaps & Pending Hardening](#️-known-gaps--pending-hardening)
- [🧯 Incident Log & Lessons Learned](#-incident-log--lessons-learned)

---

## 🧠 Logical Architecture: "Hub-and-Spoke" & Zero Trust

Centralized **Hub-and-Spoke** model secured by a default-deny firewall policy.

- **The Gateway (Node 1) — VPS Strato.** The only device with a public IP. Terminates
  WireGuard, port-forwards per zone, runs Caddy as reverse proxy, and drops everything
  else coming from the internet.
- **The Core (Node 2) — Geekom (Unraid).** Sits behind the VPN. Hosts the VMs on a
  libvirt bridge (`virbr0`, `10.0.200.0/24`). Isolates the VM zone from the home LAN
  and from the VPN zone.
- **The Compute Node (Node 3) — Dock VM.** Runs the Pelican panel and Wings. Game
  server containers are isolated from every private network from inside this VM.
- **The Admin — Owner PC.** Peer `10.0.100.3`, explicitly exempted from the isolation
  rules. It is the only device allowed into the management interfaces.

> **Deprecated:** the old `ptero` (`10.0.200.2`), `pelican`/`bay` (`10.0.200.4`) and the
> Dell "Storm" satellite node are no longer in use. The only active compute node is
> **dock** (`10.0.200.5`), published under the `osprey.*` hostnames. Their leftover zone
> files (`ptero.conf`, `pelican.conf`) should be deleted from the VPS so `rules.sh`
> stops publishing ports toward machines that no longer exist.

---

## 🗺️ Address Map

| Host | Role | LAN | WireGuard | Virtual |
|---|---|---|---|---|
| Router | CG-NAT uplink | `192.168.1.1` | — | — |
| VPS Strato | Gateway / reverse proxy | public `eth0` | `10.0.100.1` | — |
| Geekom (Unraid) | Hypervisor / core | `192.168.1.220` | `10.0.100.2` | `10.0.200.1` |
| Owner PC | Admin (unrestricted) | `192.168.1.x` | `10.0.100.3` | — |
| Dock VM | Pelican panel + Wings | — | — | `10.0.200.5` |

Docker networks **inside the dock VM** — the distinction matters, see the incident log:

| Network | Subnet | Contents | Isolated? |
|---|---|---|---|
| `wings0` | `172.21.0.0/16` | `pelican-panel`, `pelican-wings`, `pelican-db`, `pelican-redis`, `mariadb_maps` | **No** — trusted stack, must reach the VPS and the admin PC |
| `pelican_nw` | `172.18.0.0/16` (+ IPv6) | Game servers / user containers | **Yes** — untrusted |

---

## 🚦 Traffic Flow & Key Concepts

### iptables chains in play

- **DNAT** (`WG1_PREROUTING` on the VPS): rewrites the destination of an inbound public
  packet to the internal VPN/VM IP.
- **MASQUERADE**: rewrites the source so replies come back through the tunnel.
- **FORWARD** (`WG1_FORWARD`): default-deny bouncer for anything crossing from the
  internet into the VPN.
- **`DOCKER-USER`**: the only supported hook for custom rules on a Docker host. Docker
  traverses it *before* its own rules and never flushes it. Rules placed directly in
  `FORWARD` are lost the moment Docker reloads.
- **`LIBVIRT_FWI` / `LIBVIRT_FWO`**: libvirt's own forward chains on the Geekom. libvirt
  recreates them, hence the watchdog that re-applies our rules every 5s.

### Why the hairpin does not work

`rules.sh` hooks DNAT **only for traffic arriving on the public interface**
(`iptables -t nat -I PREROUTING 1 -i $PUB_INT -j WG1_PREROUTING`). Traffic originating
*inside* the tunnel arrives on `wg1`, never matches those rules, and is refused.

**Consequence:** internal hosts must never reach each other through public hostnames.
Use the private addresses (`10.0.200.5`, `10.0.100.x`) instead. This is why the
changelog API and bot use `DB_HOST=10.0.200.5` and not `osprey.bydani.dev`.

---

## ☁️ Node 1: VPS Strato (The Gateway)

**Role:** public entry point, router, zero-trust firewall, reverse proxy.
**WireGuard:** `10.0.100.1/24` on `wg1` (port `51821`).

### Firewall engine — `/etc/wireguard/scripts/rules.sh`

Detects the public interface, then for every `zones/wg1/*.conf` publishes the listed
TCP/UDP ports via DNAT + a matching FORWARD `ACCEPT`, and finishes with a blanket
`DROP` for anything else crossing from the internet into the VPN.

### Zones — `/etc/wireguard/zones/wg1/`

Only `dock.conf` is current:

```bash
IP_DEST="10.0.200.5"
TCP_PORTS="6600:6700 2022"
UDP_PORTS="6600:6700"
```

> **`3306` was deliberately removed.** Publishing it left MariaDB reachable from the
> entire internet (verified by connecting from outside with no VPN) and, since
> `require_secure_transport` is `OFF`, credentials travelled in cleartext. Everything
> that needs the database reaches it privately: the VMs via `10.0.200.5`, the admin PC
> via the VPN. If it is ever re-added, restrict the MySQL user's host first — it is
> currently `'%'`.

### Reverse proxy — `~/caddy/conf/Caddyfile`

Caddy initiates its connections locally on the VPS, so it bypasses the `FORWARD` drop.
It proxies the `osprey.*` hostnames to `10.0.200.5`.

---

## 🏗️ Node 2: Geekom / Unraid (The Core)

**Role:** hypervisor and internal router.
**WireGuard:** `10.0.100.2` · **Virtual bridge:** `10.0.200.1` (`virbr0`)

### Routing policy — `wg_confs/wg0.conf`

```ini
PostUp = ip rule add to 10.0.100.0/24 table main priority 10
PostUp = ip rule add to 192.168.1.0/24 table main priority 11
PostUp = ip rule add from 10.0.200.0/24 table 200 priority 20
PostUp = ip route add 10.0.200.0/24 dev virbr0 table 200
PostUp = ip route add default dev wg0 table 200
```

Rules are evaluated by ascending priority, so a packet from the VM zone **to** the home
LAN matches priority 11 (table `main`, i.e. straight into the house) *before* priority 20
(out through the tunnel). The firewall below is what stops it.

### Isolation — `wg_confs/start.sh`

A watchdog re-applies these every 5 seconds, because libvirt recreates its chains:

| Rule | Purpose |
|---|---|
| `LIBVIRT_FWI -s 192.168.1.0/24 -d 10.0.200.0/24 -j DROP` | Home LAN cannot reach the VMs |
| `LIBVIRT_FWO -s 10.0.200.0/24 -d 192.168.1.0/24 -j DROP` | **VMs cannot reach the house** |
| `LIBVIRT_FWO -s 10.0.200.0/24 -d 10.0.100.0/24 -j DROP` | **VMs cannot reach the VPN zone** (VPS, admin PC, peers) |
| `LIBVIRT_FWI -i wg0 -d 10.0.200.5 -j ACCEPT` | The tunnel can reach the dock VM |

Plus the `VMS_TO_HOST` chain hooked into `INPUT`:

```bash
iptables -I INPUT 1 -i virbr0 -j VMS_TO_HOST
```

`LIBVIRT_FW*` are *forward* chains, so they never see traffic addressed to the
hypervisor itself. `VMS_TO_HOST` closes that: VMs may use the Geekom as a router
(libvirt DHCP `67/udp` and DNS `53`) and receive replies to established connections,
nothing else.

The chain is built once on `up`, not inside the watchdog — repopulating it every 5s
would leave a window with no rules on each pass.

---

## 🎮 Node 3: Dock VM (Pelican + Wings)

**Virtual IP:** `10.0.200.5` · **Hostname:** `pelican` · **Public names:** `osprey.*`

Runs the Pelican panel, Wings, MariaDB and the changelog stack (API + Telegram bot).

### Container isolation — `wings-isolation.sh`

Enforced **on this VM**, and that placement is the whole point: container traffic leaves
NAT'd as `10.0.200.5`, so from the Geekom a game server and the VM itself are
indistinguishable. Only here, before the NAT, can they be told apart.

```bash
# for each IPv4 subnet of the game-server network
iptables -I DOCKER-USER 1 -s <subnet> -d 192.168.1.0/24 -m conntrack --ctstate NEW -j DROP
iptables -I DOCKER-USER 1 -s <subnet> -d 10.0.100.0/24  -m conntrack --ctstate NEW -j DROP
iptables -I DOCKER-USER 1 -s <subnet> -d 10.0.200.0/24  -m conntrack --ctstate NEW -j DROP
iptables -I INPUT 1       -s <subnet> -p tcp --dport 2022 -m conntrack --ctstate NEW -j DROP
```

Two invariants that are easy to get wrong (both were learned the hard way — see the
incident log):

1. **`--ctstate NEW` is mandatory.** Without it the rules also drop the *replies* of the
   containers to legitimate inbound connections.
2. **Only `pelican_nw` is isolated.** `wings0` holds the panel stack and must keep
   talking to the VPS and the admin PC.

The script detects the network from `/etc/pelican/config.yml`, splits IPv4 and IPv6
subnets to the right binary, and **exits non-zero if any rule fails to apply** — a
partially applied isolation must look like a failure, not a success.

Installed as a `oneshot` systemd unit (`wings-isolation.service`) ordered after
`docker.service`.

---

## 🗄️ Databases

Single MariaDB instance on the dock VM, reached privately at `10.0.200.5:3306`.

| Schema | User | Used by |
|---|---|---|
| `s20_maps` | `u20_QMTJsje6Ru` | Changelog API (versions, flags, deltas, guide) |
| `s5_belgeler` | `u5_ogdSENEZ55` | Telegram bot (links, sources, activity) |

Each user is granted only on its own schema; `mysql.user` is not readable by either.
That per-schema grant — not the network position — is what actually contains a
compromised container, since every container on the host can reach the port.

**Server state:** `bind_address` empty (listens on every interface, including the Docker
bridges), `have_ssl=YES` but `require_secure_transport=OFF`, users defined as `@'%'`.

---

## 🧪 Verification Playbook

From a **throwaway game server** in the Pelican panel — these must all time out:

```bash
192.168.1.1:80      # home router
10.0.100.3:445      # admin PC
10.0.200.2:22       # other VMs
```

...while general internet access keeps working.

On the dock VM, confirm the rules are actually installed (not merely reported):

```bash
sudo iptables -L DOCKER-USER -n -v --line-numbers
```

To see what is being blocked, insert a temporary log rule above the drops:

```bash
sudo iptables -I DOCKER-USER 2 -s <subnet> -d 10.0.100.0/24 -j LOG --log-prefix "WINGS-BLOCK: "
sudo dmesg -w | grep WINGS-BLOCK
```

Non-zero packet counters on a DROP rule mean something is really using that path —
identify it before assuming it is malicious *or* that it is safe to break.

---

## ⚠️ Known Gaps & Pending Hardening

| Gap | Impact | Suggested fix |
|---|---|---|
| The database lives on the same host as Wings | Every container can reach `3306`; only credentials separate them | Move MariaDB to its own VM, then uncomment the `3306` rule in `wings-isolation.sh` |
| MySQL users are `@'%'` | Leaked credentials are usable from anywhere | Restrict to `10.0.200.%` and `10.0.100.%` |
| `require_secure_transport=OFF` | Cleartext credentials on the wire | Enforce TLS once all clients are configured for it |
| VM ↔ VM traffic inside `10.0.200.0/24` | Same L2 segment, not filtered by `FORWARD` | Separate bridges/VLANs per trust level |
| Legacy zone files on the VPS | Ports published toward hosts that no longer exist | Delete `ptero.conf` and `pelican.conf` |
| Stale peer in `wg1.conf` | Unused "Linux DELL" peer still authorized | Remove the peer block |

---

## 🧯 Incident Log & Lessons Learned

**1. Firewall rules silently doing nothing.** `docker network inspect` returned two
subnets (IPv4 + IPv6) and the template concatenated them without a separator
(`172.18.0.0/16fdba:…::/64`). Every `iptables` call failed with `invalid mask '64'`,
yet the systemd unit finished `active (exited)` and printed a success message.
→ *A security control must fail loudly: the script now exits non-zero if any rule fails.*

**2. Panel down with HTTP 502.** The isolation rules dropped **replies** from the
containers to connections initiated from outside: Caddy → panel `:80`, Caddy → wings
`:8080`, admin PC → MariaDB `:3306`.
→ *Filter only `--ctstate NEW`. The Geekom config already did this; the VM script did not.*

**3. The wrong network was isolated.** Detection matched anything starting with
`wings`, which caught `wings0` — the panel/database/redis stack — instead of just the
game-server network.
→ *Read the network name from the Wings configuration, never guess by prefix.*

**4. Stale hostname in the database configuration.** The API failed at startup with
`Can't connect to MySQL server on 'osprey.bydani.dev'` because the public hostname does
not hairpin back through the tunnel.
→ *Internal services address each other by private IP.*
