# 🌐 Deep Dive: Network Infrastructure Documentation

<img width="5461" height="2847" alt="NETWORK(3)" src="https://github.com/user-attachments/assets/f42f9fa5-165c-44dc-a596-1426bde0db7c" />

## 🧠 Logical Architecture: "Hub-and-Spoke"

The infrastructure has evolved from a "Mesh" model (where every Virtual Machine connected individually to the VPS) to a centralized **Hub-and-Spoke** model.

  * **The Hub:** Unraid acts as the central router for your home network services.
  * **The Spoke:** The VPS acts as the public entry point.
  * **The Endpoint:** The VMs sit behind Unraid, isolated from the public internet, only receiving traffic forwarded explicitly through the tunnel.

### Detailed Traffic Flow (The Life of a Packet)

To understand *why* the configurations below are necessary, we must follow a single game packet (e.g., a Minecraft login) from the internet to the server and back.

1.  **Entry (The Handshake):** A player connects to the VPS Public IP (`87.106...`) on port `25565`.
2.  **The VPS Tunnel (DNAT & SNAT):**
      * The VPS Firewall (`rules.sh`) intercepts this packet.
      * **Destination Change:** It changes the destination from itself to the VM IP (`10.0.200.2`).
      * **Source Change (Masquerade):** Crucially, it changes the "Sender" IP to its own VPN IP (`10.0.100.1`). *Why? So that when the game server replies, it replies to the Tunnel, not to the player's random IP directly.*
      * The packet is pushed through WireGuard interface `wg1`.
3.  **The Routing Bridge (Unraid):**
      * Unraid receives the packet on `10.0.100.2`.
      * It sees the packet is destined for `10.0.200.2`. Unraid knows this IP lives on its virtual bridge (`virbr0`).
      * **Forwarding:** The IPTables rules allow the packet to cross from the VPN interface to the Virtual Machine interface.
4.  **The Docker Trick (The VM):**
      * The VM receives the packet. Normally, Docker blocks external traffic on custom bridges.
      * The `fix_ptero.sh` script intercepts the packet before Docker sees it.
      * It rewrites the packet to look like it is coming from `localhost` (`127.0.0.1`).
      * Docker accepts the connection because it trusts "local" traffic.

-----

## ☁️ Node 1: VPS (Strato)

**Role:** Public Gateway & Central Firewall

The VPS is the "Face" of the network. It protects your home IP (DDoS protection) and standardizes access. It runs WireGuard to create a secure, encrypted extension of your local network over the internet.

### 📂 File Structure

```text
/etc/wireguard/
├── scripts/
│   └── rules.sh          # ⚙️ Dynamic Firewall Engine (The Logic)
├── zones/
│   └── wg1/              # 🚦 Zone Definitions (The Data)
│       └── ptero.conf    # Specific ports for Pterodactyl
├── wg1.conf              # Unraid Tunnel Config
└── wg0.conf              # Legacy Config (Deprecated or secondary)
```

### ⚙️ Critical Configurations

#### 1\. `wg1.conf` (Main Tunnel)

This file configures the WireGuard interface. The `PostUp` and `PostDown` lines are the "hooks" that turn the VPN into a router by launching our firewall script.

```ini
[Interface]
Address = 10.0.100.1/24
ListenPort = 51821
PrivateKey = <Private_Key_VPS>

# --- FIREWALL MANAGEMENT ---
# When the tunnel starts, run the script with "up". When it stops, run "down".
# %i is a variable that is automatically replaced by the interface name (wg1).
PostUp = /etc/wireguard/scripts/rules.sh up %i
PostDown = /etc/wireguard/scripts/rules.sh down %i

[Peer]
# Client: Unraid Server
PublicKey = <Public_Key_Unraid>
PresharedKey = <Preshared_Key>
# AllowedIPs acts as a routing table.
# It tells the VPS: "Send traffic for the Tunnel IP (100.2) AND the VM Subnet (200.0/24) through this peer."
AllowedIPs = 10.0.100.2/32, 10.0.200.0/24
```

#### 2\. `scripts/rules.sh` (Master Script)

This is a robust, modular firewall script. Instead of hardcoding ports, it reads external files. This prevents syntax errors in the main script from breaking the network.

  * **`sysctl ... ip_forward`**: Tells the Linux kernel to allow passing packets between interfaces (Router mode).
  * **`MASQUERADE`**: The most critical rule. It ensures that traffic leaving the tunnel looks like it comes from the VPS. Without this, return traffic would get lost.

<!-- end list -->

```bash
#!/bin/bash
# Location: /etc/wireguard/scripts/rules.sh

ACTION=$1                   # "up" or "down"
INTERFACE=$2                # "wg1"
ZONE_DIR="/etc/wireguard/zones/$INTERFACE"

if [ -z "$INTERFACE" ]; then echo "❌ Error: Missing interface"; exit 1; fi

if [ "$ACTION" == "up" ]; then
    echo "🚀 [VPS] Starting Dynamic Firewall for $INTERFACE..."
    
    # Enable the Kernel's ability to forward packets
    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    # Preventive Cleanup: Clear old NAT rules to avoid duplicates
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING

    # 1. MASTER RETURN RULE (MASQUERADE) - CRITICAL
    # "Any packet leaving via wg1 must bear my IP address as the source."
    iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE

    # 2. DYNAMIC ZONE LOADING
    # Loops through every .conf file in the zones directory
    if [ -d "$ZONE_DIR" ]; then
        for CONFIG_FILE in "$ZONE_DIR"/*.conf; do
            [ -e "$CONFIG_FILE" ] || continue
            source "$CONFIG_FILE"
            echo "   📂 Loading zone: $(basename "$CONFIG_FILE") -> $IP_DEST"

            # Apply TCP Rules: Forwards external traffic to the internal VM IP
            if [ ! -z "$TCP_PORTS" ]; then
                for PORT in $TCP_PORTS; do
                    iptables -t nat -A PREROUTING -p tcp --dport $PORT -j DNAT --to-destination $IP_DEST
                done
            fi
            # Apply UDP Rules: Same as above, for UDP (Crucial for Minecraft/Voice)
            if [ ! -z "$UDP_PORTS" ]; then
                for PORT in $UDP_PORTS; do
                    iptables -t nat -A PREROUTING -p udp --dport $PORT -j DNAT --to-destination $IP_DEST
                done
            fi
        done
    fi
    echo "✅ Rules applied."

elif [ "$ACTION" == "down" ]; then
    echo "🛑 [VPS] Cleaning rules..."
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
fi
```

#### 3\. `zones/wg1/ptero.conf` (Port Definitions)

This file makes management easy. To add a port, you edit this file, not the complex script.

```bash
# Destination: Pterodactyl VM on Unraid
IP_DEST="10.0.200.2"

# Game Ports + SFTP
TCP_PORTS="25565:25999 2022"
UDP_PORTS="25565:25999"
```

-----

## 🟠 Node 2: Unraid (The Hub)

**Role:** Internal Router & VM Host

Unraid is the physical machine hosting your infrastructure. It maintains the connection to the VPS and bridges that connection to your Virtual Machines using Linux bridging (`virbr0`).

### 📂 WireGuard Config (`wg0.conf`)

*Note: Unraid names the interface `wg0` locally, but it connects to the VPS's `wg1`. This is normal.*

The `PostUp` command here is a dense chain of commands that configures Unraid to act as a bridge.

1.  `sysctl ... ip_forward=1`: Activates router mode.
2.  `iptables -I FORWARD ...`: These are "Permissions". By default, Linux might block traffic moving from VPN to VM. These rules explicitly allow it.
3.  `MASQUERADE`: This ensures that when the VM replies to Unraid, Unraid knows how to handle the packet.

<!-- end list -->

```ini
[Interface]
Address = 10.0.100.2/24
PrivateKey = <Private_Key_Unraid>
ListenPort = 51821

# --- ADVANCED ROUTING ---
# 1. Enable IP Forwarding
# 2. Allow Traffic VPN (%i) -> VM Bridge (virbr0)
# 3. Allow Traffic VM Bridge (virbr0) -> VPN (%i)
# 4. Masquerade return traffic (Ensures routing stability)
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -I FORWARD 1 -i %i -o virbr0 -j ACCEPT; iptables -I FORWARD 1 -i virbr0 -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; iptables -t nat -A POSTROUTING -s 10.0.100.0/24 -o virbr0 -j MASQUERADE

# Cleanup on shutdown (Exact reverse of PostUp)
PostDown = iptables -D FORWARD -i %i -o virbr0 -j ACCEPT; iptables -D FORWARD -i virbr0 -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE; iptables -t nat -D POSTROUTING -s 10.0.100.0/24 -o virbr0 -j MASQUERADE

[Peer]
# VPS Strato connection details
PublicKey = <Public_Key_VPS>
PresharedKey = <Preshared_Key>
Endpoint = 87.106.XXX.XXX:51821
AllowedIPs = 10.0.100.0/24
PersistentKeepalive = 25
```

-----

## 📦 Node 3: Pterodactyl VM

**Role:** Game Server Host (Docker)
**IP:** `10.0.200.2` (Static IP assigned by Unraid)

**The Problem:** Docker manages its own firewall (`iptables`). When traffic comes from a "strange" network (like our VPN), Docker often blocks it or misroutes the response, leading to "Connection Refused" even if the server is running.

**The Solution:** The **Localhost Mirror**. We run a script that catches incoming packets and rewrites them to target `127.0.0.1`. Docker *always* accepts traffic from Localhost.

### 🛠️ Repair Script (`/root/fix_ptero.sh`)

This script forces the networking to work by bypassing Docker's external filters.

```bash
#!/bin/bash
# Location: /root/fix_ptero.sh

# Ports to fix (Defaults to 25565-25999 if no argument provided)
INPUT_RANGE=${1:-"25565:25999"}
START_PORT=$(echo $INPUT_RANGE | cut -d':' -f1)
END_PORT=$(echo $INPUT_RANGE | cut -d':' -f2)
[ -z "$END_PORT" ] && END_PORT=$START_PORT

echo "🔧 Fixing Docker Network for ports: $START_PORT to $END_PORT ..."

# 1. Enable Localhost Routing (MANDATORY)
# Normally, Linux forbids routing external traffic to 127.0.0.1. We must enable this.
sysctl -w net.ipv4.conf.all.route_localnet=1 > /dev/null

# 2. NAT Cleanup
# Remove old rules to prevent conflicts.
iptables -t nat -F PREROUTING
iptables -t nat -F POSTROUTING

# 3. MIRROR LOOP (Port by Port)
for port in $(seq $START_PORT $END_PORT); do
    # INBOUND (DNAT): 
    # Catch traffic on external IP -> Send to 127.0.0.1
    iptables -t nat -A PREROUTING -p tcp --dport $port -j DNAT --to-destination 127.0.0.1:$port
    iptables -t nat -A PREROUTING -p udp --dport $port -j DNAT --to-destination 127.0.0.1:$port

    # OUTBOUND (SNAT/Hairpin): 
    # This is the magic fix. When the server replies, we rewrite the packet so it looks
    # like it came from 127.0.0.1. This ensures the reply goes back through our tunnel
    # instead of getting lost in the Docker bridge.
    iptables -t nat -A POSTROUTING -p tcp --dport $port -d 127.0.0.1 -j SNAT --to-source 127.0.0.1
    iptables -t nat -A POSTROUTING -p udp --dport $port -d 127.0.0.1 -j SNAT --to-source 127.0.0.1
done

# 4. Internet Access for Docker Containers
# Allows containers to download updates/plugins from the internet.
iptables -t nat -A POSTROUTING -s 172.0.0.0/8 ! -d 172.0.0.0/8 -j MASQUERADE

echo "✅ Network fixed."
```

-----

## 🚦 Web Services (Reverse Proxy)

**Host:** VPS (Strato)
**Stack:** Caddy + Docker

This handles `http` and `https` traffic (Websites, Panels, Wings API). Unlike the raw game ports, this uses a **Reverse Proxy**. Caddy terminates the connection at the VPS and creates a new request to the internal server.

### `docker-compose.yml`

The crucial setting here is `network_mode: host`.

  * **Standard Docker:** Isolated network. Can't see the WireGuard interface (`wg1`) on the host.
  * **Host Mode:** Caddy runs as if it were installed directly on the OS. It can see and route traffic to the `10.0.200.x` VPN IPs.

<!-- end list -->

```yaml
services:
  caddy:
    image: caddy:latest
    restart: unless-stopped
    network_mode: host  # CRITICAL: Allows Caddy to access 10.0.x.x IPs over WireGuard
    volumes:
      - ./conf:/etc/caddy
      - ./site:/srv
      - caddy_data:/data
      - caddy_config:/config
```

### `conf/Caddyfile`

Maps public subdomains to private VPN IPs.

```text
# --- PTERODACTYL & WINGS ---
# Routes traffic from the public web to the VM via the VPN tunnel
ptero.danicdn.tech {
    reverse_proxy 10.0.200.2:80
}

wings.danicdn.tech:8080 {
    reverse_proxy 10.0.200.2:8080
}

# --- BILLING (PAYMENTER) ---
# A different VM on the same internal network (Unraid routed)
billing.danicdn.tech {
    reverse_proxy 10.0.200.3:80
}

# --- REDIRECTS & EXTRAS ---
# These point to services running on the VPS itself (localhost)
theblockheads.me {
    reverse_proxy localhost:15151
}

join.theblockheads.me {
    reverse_proxy localhost:9924
}
```
