#!/bin/bash

# --- CONFIGURACIÓN ---
# Si le pasas un argumento (ej: ./script.sh 25565:25570), usa ese rango.
# Si no le pasas nada, usa el rango por defecto 25565:25999.
INPUT_RANGE=${1:-"25565:25999"}

# Separar el inicio y el fin del rango (formato INICIO:FIN)
START_PORT=$(echo $INPUT_RANGE | cut -d':' -f1)
END_PORT=$(echo $INPUT_RANGE | cut -d':' -f2)

# Si no hay dos puntos (un solo puerto), el fin es igual al inicio
if [ -z "$END_PORT" ]; then
    END_PORT=$START_PORT
fi

echo "🔧 Reparando red para puertos: $START_PORT a $END_PORT ..."

# 1. Habilitar enrutamiento a Localhost (OBLIGATORIO)
sysctl -w net.ipv4.conf.all.route_localnet=1 > /dev/null

# 2. Limpieza TOTAL de NAT (Para quitar el "Searching..." causado por reglas rotas)
iptables -t nat -F PREROUTING
iptables -t nat -F POSTROUTING

# 3. BUCLE PUERTO A PUERTO (El método lento pero SEGURO)
# Volvemos a este método porque es el único que garantiza que el SNAT se aplique bien.
for port in $(seq $START_PORT $END_PORT); do
    # ENTRADA: Redirigir tráfico externo al Localhost
    iptables -t nat -A PREROUTING -p tcp --dport $port -j DNAT --to-destination 127.0.0.1:$port
    iptables -t nat -A PREROUTING -p udp --dport $port -j DNAT --to-destination 127.0.0.1:$port

    # SALIDA: La regla mágica de retorno (SNAT)
    # Esta es la que arregla el "Searching / Connection Refused"
    iptables -t nat -A POSTROUTING -p tcp --dport $port -d 127.0.0.1 -j SNAT --to-source 127.0.0.1
    iptables -t nat -A POSTROUTING -p udp --dport $port -d 127.0.0.1 -j SNAT --to-source 127.0.0.1
done

# 4. Regla para que Docker tenga internet (Descargar plugins, actualizaciones)
iptables -t nat -A POSTROUTING -s 172.0.0.0/8 ! -d 172.0.0.0/8 -j MASQUERADE

echo "✅ Listo. Puertos $START_PORT:$END_PORT arreglados."
