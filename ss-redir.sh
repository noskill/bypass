# Create new chains

/opt/sbin/insmod /lib/modules/$(/opt/bin/uname -r)/xt_TPROXY.ko
VPS_IP_ADDRESS=xxx.xxx.xxx.xxx

IPTABLES=/opt/sbin/iptables
IP_CMD=/opt/sbin/ip
LOG=/dev/null
GREP_CMD=/opt/bin/grep


# Function to check if an $IPTABLES chain exists
chain_exists() {
    $IPTABLES -t "$1" -nL "$2" >/dev/null 2>&1
}

# Create or flush SHADOWSOCKS chain in the nat table
if chain_exists nat SHADOWSOCKS; then
    # Chain exists, flush it
    echo "chain nat SHADOWSOCKS exists" >> $LOG
    $IPTABLES -t nat -F SHADOWSOCKS
else
    # Chain doesn't exist, create it
    $IPTABLES -t nat -N SHADOWSOCKS
fi

# Create or flush SHADOWSOCKS chain in the mangle table
if chain_exists mangle SHADOWSOCKS; then
    # Chain exists, flush it
    $IPTABLES -t mangle -F SHADOWSOCKS
    echo "chain mangle SHADOWSOCKS exists" >> $LOG
else
    # Chain doesn't exist, create it
    $IPTABLES -t mangle -N SHADOWSOCKS
fi

# Ignore traffic to your Shadowsocks server
$IPTABLES -t nat -C SHADOWSOCKS -d "$VPS_IP_ADDRESS" -j RETURN 2>/dev/null || \
$IPTABLES -t nat -A SHADOWSOCKS -d "$VPS_IP_ADDRESS" -j RETURN

$IPTABLES -t mangle -C SHADOWSOCKS -d "$VPS_IP_ADDRESS" -j RETURN 2>/dev/null || \
$IPTABLES -t mangle -A SHADOWSOCKS -d "$VPS_IP_ADDRESS" -j RETURN

# Ignore local and reserved IP addresses
for IP in \
    0.0.0.0/8 \
    10.0.0.0/8 \
    127.0.0.0/8 \
    169.254.0.0/16 \
    172.16.0.0/12 \
    192.168.0.0/16 \
    224.0.0.0/4 \
    240.0.0.0/4
do
    $IPTABLES -t nat -C SHADOWSOCKS -d "$IP" -j RETURN 2>/dev/null || \
    $IPTABLES -t nat -A SHADOWSOCKS -d "$IP" -j RETURN

    $IPTABLES -t mangle -C SHADOWSOCKS -d "$IP" -j RETURN 2>/dev/null || \
    $IPTABLES -t mangle -A SHADOWSOCKS -d "$IP" -j RETURN
done


# Redirect TCP traffic to IPs in 'viatunnel' set
$IPTABLES -t nat -C SHADOWSOCKS -p tcp -m set --match-set viatunnel dst -j REDIRECT --to-ports 1381 2>/dev/null || \
$IPTABLES -t nat -A SHADOWSOCKS -p tcp -m set --match-set viatunnel dst -j REDIRECT --to-ports 1381

# Create a new routing table if not exists
$IP_CMD route show table 100 >/dev/null 2>&1 || $IP_CMD route add local default dev lo table 100

# Add a rule to use the new routing table for marked packets if not exists
$IP_CMD rule list | $GREP_CMD -q 'fwmark 0x1 lookup 100' || $IP_CMD rule add fwmark 0x1 lookup 100

# Mark UDP packets destined for IPs in 'viatunnel' set
$IPTABLES -t mangle -C SHADOWSOCKS -p udp -m set --match-set viatunnel dst -j TPROXY --on-port 1381 --tproxy-mark 0x01/0x01 2>/dev/null || \
$IPTABLES -t mangle -A SHADOWSOCKS -p udp -m set --match-set viatunnel dst -j TPROXY --on-port 1381 --tproxy-mark 0x01/0x01

# Apply the SHADOWSOCKS chain to PREROUTING in the nat table for TCP
$IPTABLES -t nat -C PREROUTING -i br0 -p tcp -j SHADOWSOCKS 2>/dev/null || \
$IPTABLES -t nat -A PREROUTING -i br0 -p tcp -j SHADOWSOCKS

# Apply the SHADOWSOCKS chain to PREROUTING in the mangle table for UDP
$IPTABLES -t mangle -C PREROUTING -i br0 -p udp -j SHADOWSOCKS 2>/dev/null || \
$IPTABLES -t mangle -A PREROUTING -i br0 -p udp -j SHADOWSOCKS

# Allow forward of related and established connections if not already allowed
$IPTABLES -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
$IPTABLES -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

# Accept all traffic from LAN to WAN if not already allowed
$IPTABLES -C FORWARD -i br0 -o eth0 -j ACCEPT 2>/dev/null || \
$IPTABLES -A FORWARD -i br0 -o eth0 -j ACCEPT
