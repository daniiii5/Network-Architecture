# 🌐 Network Architecture Overhaul

## 🧠 The New Networking Logic

<img width="5504" height="2847" alt="Network" src="https://github.com/user-attachments/assets/dbe37bd2-a2c8-4ef6-a2b8-0e81af8a7eb6" />


In this new configuration, the architecture shifts from a "Mesh" style (where every VM connects individually to the VPS) to a **"Hub-and-Spoke" / Site-to-Site** model managed by Unraid.

**How it works now:**

1.  **Isolation:** The VMs (like `Paymenter`) no longer communicate directly with your physical home router (`192.168.1.1`) for their public service traffic.
2.  **The Bridge:** They are connected to a virtual internal network on Unraid (likely `virbr0` or a custom Docker network) with the range `10.0.200.0/24`.
3.  **The Gateway (Unraid):** Unraid acts as the **Gateway**. It has an IP of `10.0.200.1` on this internal network.
4.  **The Tunnel:** Unraid maintains a *single* WireGuard connection (`wg1`) to the VPS (Strato).
5.  **The Flow:**
      * VM sends data to Unraid (`10.0.200.1`).
      * Unraid forwards that traffic through the WireGuard tunnel (`10.0.100.2` -\> `10.0.100.1`).
      * The VPS receives it and routes it to the public Internet using its Public IP (`87.106...`).

**Benefits:**

  * **Cleaner:** You only manage one VPN connection on the Unraid host, not one per VM.
  * **Secure:** VMs are isolated behind Unraid.
  * **Efficient:** Traffic bypasses the home router's NAT table for these services.

-----

# 📂 Configuration & Files

## ☁️ System 1: VPS (Strato)

*The Public Gateway*

### 🛡️ WireGuard & Firewall

To install: `sudo apt install wireguard`
Keys: Generate using `wg genkey | tee privatekey | wg pubkey > publickey`

#### 📂 File Structure

```text
.
├── scripts
│   └── rules.sh          # 🔥 Dynamic Firewall Script
├── wg0                   # 👴 Legacy Network (Direct VM connections)
│   ├── privatekey
│   └── publickey
├── wg0.conf
├── wg1                   # 🆕 New Network (Unraid Tunnel)
│   ├── privatekey
│   └── publickey
├── wg1.conf
└── zones                 # 🚦 Port Forwarding Rules
    ├── wg0
    │   ├── paymenter.conf
    │   ├── ptero.conf
    │   └── pyro.conf
    └── wg1
```

#### `scripts/rules.sh`

> This script manages IPTables. It accepts `up` or `down` and the interface name (`wg0` or `wg1`). It automatically applies NAT (Masquerade) to allow internet access and reads the `/zones/` folder to apply port forwarding rules (DNAT) dynamically.

```bash
#!/bin/bash

# --- PARAMETROS AUTOMÁTICOS ---
ACTION=$1                   # "up" o "down"
INTERFACE=$2                # "wg1" (pasado por WireGuard)
ZONE_DIR="/etc/wireguard/zones/$INTERFACE"

# Validación
if [ -z "$INTERFACE" ]; then
    echo "❌ Error: Falta interfaz. Uso: $0 {up|down} wg1"
    exit 1
fi

if [ "$ACTION" == "up" ]; then
    echo "🚀 [VPS] Iniciando Firewall Dinámico para $INTERFACE..."

    # 1. PREPARACIÓN DEL SISTEMA
    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    # Limpieza de tablas NAT para evitar conflictos o duplicados
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING

    # 2. REGLA MAESTRA DE RETORNO (MASQUERADE)
    # Fundamental para que el tráfico sepa volver por el túnel
    iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE

    # 3. CARGA DINÁMICA DE ZONAS (.conf)
    if [ -d "$ZONE_DIR" ]; then
        # Buscamos cualquier archivo .conf en /etc/wireguard/zones/wg1/
        for CONFIG_FILE in "$ZONE_DIR"/*.conf; do
            [ -e "$CONFIG_FILE" ] || continue # Si no hay archivos, salta

            # Leemos las variables del archivo (IP_DEST, TCP_PORTS, UDP_PORTS)
            source "$CONFIG_FILE"

            echo "   📂 Cargando: $(basename "$CONFIG_FILE") -> Destino: $IP_DEST"

            # --- APLICAR REGLAS TCP ---
            # El bucle 'for' separa por espacios. IPTables entiende los rangos (:) nativamente.
            if [ ! -z "$TCP_PORTS" ]; then
                for PORT in $TCP_PORTS; do
                    iptables -t nat -A PREROUTING -p tcp --dport $PORT -j DNAT --to-destination $IP_DEST
                done
            fi

            # --- APLICAR REGLAS UDP ---
            if [ ! -z "$UDP_PORTS" ]; then
                for PORT in $UDP_PORTS; do
                    iptables -t nat -A PREROUTING -p udp --dport $PORT -j DNAT --to-destination $IP_DEST
                done
            fi
        done
    else
        echo "   ⚠️ No existe el directorio de zonas: $ZONE_DIR"
    fi
    echo "✅ Reglas aplicadas."

elif [ "$ACTION" == "down" ]; then
    echo "🛑 [VPS] Deteniendo Firewall..."
    # Limpieza total al apagar
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    echo "✅ Reglas eliminadas."
fi
```

#### `wg0.conf` (Legacy)

> Standard WireGuard config using IP range `12.0.0.1`. It calls the `rules.sh` script on startup/shutdown.

```ini
[Interface]
Address = 12.0.0.1/24
ListenPort = 51820
PrivateKey = PrivateKey

# --- SISTEMA ELÁSTICO ---
# 1. Activar kernel forwarding
PostUp = sysctl -w net.ipv4.ip_forward=1

# 2. Ejecutar el script maestro (UP)
PostUp = /etc/wireguard/scripts/rules.sh up %i

# 3. Ejecutar el script maestro (DOWN) - Limpieza automática
PostDown = /etc/wireguard/scripts/rules.sh down %i

[Peer]
# Pterodactyl Backend
PublicKey = PublicKey
AllowedIPs = 12.0.1.1/32

[Peer]
# Pyrodactyl Backend
PublicKey = PublicKey
AllowedIPs = 12.0.1.2/32

[Peer]
# Pyrodactyl Backend
PublicKey = PublicKey
AllowedIPs = 12.0.1.3/32
```

#### `wg1.conf` (New Unraid Link)

>   * **Address:** `10.0.100.1` (The new private network for Unraid).
>   * **ListenPort:** `51821` (Different from wg0 to avoid conflicts).
>   * **AllowedIPs:** Includes `10.0.200.0/24` — this is crucial. It tells the VPS that to reach the VMs (like Paymenter), it must send traffic through this peer (Unraid).

```ini
[Interface]
# Esta es la IP del VPS en la NUEVA red exclusiva para Unraid
Address = 10.0.100.1/24

# ¡IMPORTANTE! Cambiamos el puerto al 51821 para no chocar con el wg0
ListenPort = 51821

# Genera una PrivateKey NUEVA para este wg1 (comando: wg genkey)
PrivateKey = PrivateKey

# Scripts
PostUp = sysctl -w net.ipv4.ip_forward=1
# OJO: Asegúrate de que este script no tenga escrito "wg0" a fuego dentro.
# Si es genérico, funcionará.
PostUp = /etc/wireguard/scripts/rules.sh up %i
PostDown = /etc/wireguard/scripts/rules.sh down %i

[Peer]
# Esta es la Public Key de tu Unraid (esa se mantiene igual)
PublicKey = PublicKey
PresharedKey = PresharedKey
AllowedIPs = 10.0.100.2/32, 10.0.200.0/24
```

#### `zones/wg0/ptero.conf`

> Defines variable for the firewall script. Points ports 25565-25999 to the specific internal IP.

```bash
# Configuración para Pterodactyl
IP_DEST="12.0.1.1"

# Lista de puertos TCP (separados por espacio)
# Ejemplo: Rangos con dos puntos, puertos sueltos solos
TCP_PORTS="25565:25999 2022"

# Lista de puertos UDP
UDP_PORTS="25565:25999"
```

-----

### 🚦 Caddy Reverse Proxy

Handles SSL termination and subdomains.

#### 📂 File Structure

```text
.
├── conf
│   └── Caddyfile
├── docker-compose.yml
├── restart.sh
└── site
```

#### `conf/Caddyfile`

> **Note:** Notice `billing.danicdn.tech` points to `10.0.200.3`. This traffic goes through the `wg1` tunnel to Unraid.

```text
ptero.danicdn.tech {
    reverse_proxy 12.0.1.1:80
}

wings.danicdn.tech:8080 {
    reverse_proxy 12.0.1.1:8080
}

pyro.danicdn.tech {
    reverse_proxy 12.0.1.2:80
}

daemon.danicdn.tech:8081 {
    reverse_proxy 12.0.1.2:8081
}

daemon.danicdn.tech {
    reverse_proxy 12.0.1.2:8081
}

theblockheads.me {
    reverse_proxy localhost:15151
}

join.theblockheads.me {
    reverse_proxy localhost:9924
}

billing.danicdn.tech {
    reverse_proxy 10.0.200.3:80
}

status.danicdn.tech {
    reverse_proxy localhost:3001
}
```

#### `docker-compose.yml`

```yaml
services:
  caddy:
    image: caddy:latest
    restart: unless-stopped
    # --- CAMBIO CRÍTICO ---
    # Usamos la red del host para que Caddy vea la interfaz WireGuard (12.0.0.1)
    network_mode: host

    # --- SECCIÓN ELIMINADA ---
    # Al usar network_mode: host, no se mapean puertos.
    # Caddy tomará el control directo de los puertos 80 y 443 de la máquina.
    # ports:
    #   - "80:80"
    #   - "443:443"
    #   - "443:443/udp"

    volumes:
      - ./conf:/etc/caddy
      - ./site:/srv
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
```

#### `restart.sh`

```bash
docker compose exec -w /etc/caddy caddy caddy reload
```

-----

### 🔀 Redirect Service (Python)

A simple FastAPI app to redirect users to a custom URL scheme (`blockheads://`).

#### 📂 File Structure

```text
.
├── Dockerfile
├── docker-compose.yml
└── main.py
```

#### `Dockerfile`

```dockerfile
FROM python:3.14-slim
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir fastapi uvicorn
EXPOSE 9924
# CMD ["python3", "-m", "http.server", "9924"]
# CMD ["python3", "main.py"]
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "9924"]
```

#### `docker-compose.yml`

```yaml
services:
  web-server:
    build: .
    container_name: web-server
    # ESTA ES LA PARTE CLAVE QUE PROBABLEMENTE FALTA:
    network_mode: host
    ports:
      - "9924:9924"
    volumes:
      - .:/app
    # Si el servidor falla, que se reinicie solo
    restart: always
```

-----

### 🕸️ Website (Legacy Static Site)

A static site running on Nginx/Apache (implied by file structure) or Python.

#### 📂 File Structure

*(Summarized for brevity)*

```text
.
├── Dockerfile
├── docker-compose.yml
├── index.html
├── main.py
├── start.sh
└── (assets: css, js, img, fonts)
```

-----

## 🟠 System 2: Unraid (The Hub)

*The Home Server & VM Host*

### 🔌 WireGuard Client

Unraid connects to the VPS via `wg1`.

#### 📂 File Structure

```text
.
├── coredns
│   └── Corefile
├── server
│   ├── privatekey-server
│   └── publickey-server
├── templates
│   ├── peer.conf
│   └── server.conf
└── wg_confs
    └── wg0.conf
```

#### `wg_confs/wg0.conf`

> This is the client side configuration on Unraid.
>
>   * **PostUp Command:**
>     1.  `sysctl -w net.ipv4.ip_forward=1`: Enables the server to pass traffic from one interface to another.
>     2.  `iptables -I FORWARD 1 -i %i -o virbr0 -j ACCEPT`: Allows traffic coming **from** the VPN (`%i`) to go **to** the VM bridge (`virbr0`).
>     3.  `iptables -I FORWARD 1 -i virbr0 -o %i -j ACCEPT`: Allows traffic coming **from** the VMs to go **to** the VPN.
>     4.  `MASQUERADE`: Ensures traffic leaving via `eth0` is NATed (if strictly necessary for local access).

```ini
[Interface]
Address = 10.0.100.2/24
PrivateKey = PrivateKey
ListenPort = 51821

# --- REGLAS DE FIREWALL AUTOMÁTICAS ---

# 1. Al arrancar (PostUp):
# - Activamos el reenvío de IPs (ip_forward).
# - Insertamos (-I) las reglas de paso entre el túnel (%i) y las VMs (virbr0) ARRIBA DEL TODO.
# - Activamos el NAT (Masquerade) para que salgan a internet por eth0 si hace falta.
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -I FORWARD 1 -i %i -o virbr0 -j ACCEPT; iptables -I FORWARD 1 -i virbr0 -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# 2. Al apagar (PostDown):
# - Borramos (-D) exactamente las mismas reglas para dejar el sistema limpio.
PostDown = iptables -D FORWARD -i %i -o virbr0 -j ACCEPT; iptables -D FORWARD -i virbr0 -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE


# Strato
[Peer]
PublicKey = PublicKey
PresharedKey = PresharedKey
Endpoint = PUBLIC:51821
AllowedIPs = 10.0.100.0/24
PersistentKeepalive = 25


# Windows 11
[Peer]
PublicKey = PublicKey
PresharedKey = PresharedKey
AllowedIPs = 10.0.100.3/32
```

-----

## 💻 Virtual Machines (VMs)

### 📦 Pterodactyl VM

  * **Method:** Old / Legacy (`wg0`)
  * **Connection:** Connects directly to VPS `wg0`.

### 💳 Paymenter VM

  * **Method:** **New / Hub-and-Spoke** (`wg1`)
  * **IP Address:** `10.0.200.2`
  * **Gateway:** `10.0.200.1` (Unraid)
  * **Route:** Traffic goes Unraid -\> Tunnel -\> VPS.
  * **Note:** This VM acts as if Unraid is its router. It does not need a WireGuard client installed inside the VM itself to reach the VPS, because Unraid handles the routing.
