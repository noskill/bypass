#!/bin/sh

# --- Variables ---
/opt/sbin/insmod /lib/modules/$(/opt/bin/uname -r)/xt_TPROXY.ko 2>/dev/null
VPS_IP_ADDRESS=xxx.xxx.xxx.xxx

IPTABLES="/opt/sbin/iptables -w"
IP_CMD=/opt/sbin/ip
LOG=/dev/null
DNSMASQ_PORT=1053
LAN_IF=br0
TPROXY_PORT=1381

# 1. Disable rp_filter 
for i in /proc/sys/net/ipv4/conf/*/rp_filter; do  
    echo 0 > "$i" 2>/dev/null
done

# Function to check and append rules
add_rule() {
    $1 -C $2 $3 >/dev/null 2>&1 || $1 -A $2 $3
}

# Function to check and insert rules at the top
insert_rule() {
    $1 -C $2 $3 >/dev/null 2>&1 || $1 -I $2 $3
}

# --- Setup IPSet for Local/Bypass Subnets ---
/opt/sbin/ipset create bypass_ips hash:net 2>/dev/null
for IP in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    /opt/sbin/ipset add bypass_ips $IP 2>/dev/null
done

# 2. Setup NAT Chain
$IPTABLES -t nat -N SHADOWSOCKS 2>/dev/null
add_rule "$IPTABLES -t nat" SHADOWSOCKS "-d $VPS_IP_ADDRESS -j RETURN"

# One single rule replaces the loop
add_rule "$IPTABLES -t nat" SHADOWSOCKS "-m set --match-set bypass_ips dst -j RETURN"

add_rule "$IPTABLES -t nat" SHADOWSOCKS "-p tcp -m set --match-set viatunnel dst -j REDIRECT --to-ports $TPROXY_PORT"

# 3. Setup Mangle Chain
$IPTABLES -t mangle -N SHADOWSOCKS 2>/dev/null
add_rule "$IPTABLES -t mangle" SHADOWSOCKS "-p udp --dport 53 -j RETURN"
add_rule "$IPTABLES -t mangle" SHADOWSOCKS "-d $VPS_IP_ADDRESS -j RETURN"

# One single rule replaces the loop
add_rule "$IPTABLES -t mangle" SHADOWSOCKS "-m set --match-set bypass_ips dst -j RETURN"

add_rule "$IPTABLES -t mangle" SHADOWSOCKS "-p udp -m set --match-set viatunnel dst -j TPROXY --on-port $TPROXY_PORT --tproxy-mark 0x01/0x01"

# 4. Global Jumps
insert_rule "$IPTABLES -t nat" PREROUTING "-i $LAN_IF -p udp --dport 53 -j REDIRECT --to-ports $DNSMASQ_PORT"
insert_rule "$IPTABLES -t nat" PREROUTING "-i $LAN_IF -p tcp --dport 53 -j REDIRECT --to-ports $DNSMASQ_PORT"
add_rule "$IPTABLES -t nat" PREROUTING "-i $LAN_IF -p tcp -j SHADOWSOCKS"
add_rule "$IPTABLES -t mangle" PREROUTING "-i $LAN_IF -p udp -j SHADOWSOCKS"

# 5. Routing Table & Rules
$IP_CMD -4 route replace local 0.0.0.0/0 dev lo table 100
$IP_CMD rule list | grep -q 'fwmark 0x1/0x1.*lookup 100' || $IP_CMD rule add fwmark 0x1/0x1 lookup 100

echo "$(date): Rules refreshed" >> $LOG
