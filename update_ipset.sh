#!/bin/sh

# Name of the original ipset
IPSET_NAME="viatunnel"

# Name of the temporary ipset
TEMP_IPSET_NAME="${IPSET_NAME}_temp"

# Path to the domain list file
DOMAIN_LIST_FILE="/opt/etc/redirect.txt"
ASN_LIST_FILE="/opt/etc/asnredirect.txt"
RANGES_FILE="/opt/etc/ranges_redirect.txt"

# Time to live for IP addresses in seconds (e.g., 1 day)
IPSET_TIMEOUT=86400

# DNS query timeout in seconds
DNS_QUERY_TIMEOUT=5

# Absolute paths to commands
IPSET_CMD="/opt/sbin/ipset"
GREP_CMD="/opt/bin/grep"
TIMEOUT_CMD="/opt/bin/timeout"
DIG_CMD="/opt/bin/dig"
RM_CMD="/opt/bin/rm"
TOUCH_CMD="/opt/bin/touch"
SED_CMD="/opt/bin/sed"
WHOIS_CMD="/opt/bin/whois"
TR_CMD="/opt/bin/tr"

# Determine which download command to use
if [ -x "/opt/bin/curl" ]; then
    DOWNLOAD_CMD="/opt/bin/curl -s -o"
elif [ -x "/opt/bin/wget" ]; then
    DOWNLOAD_CMD="/opt/bin/wget -q -O"
else
    echo "Error: Neither curl nor wget is available."
    exit 1
fi

# Log file
LOG_FILE="/tmp/ipset_update.log"
# Uncomment the next line to disable logging
LOG_FILE="/dev/null"

# Lock file to prevent concurrent runs
LOCK_FILE="/tmp/update_ipset.lock"

# Exit if another instance is running
if [ -e "$LOCK_FILE" ]; then
    echo "Script is already running. Exiting." >> "$LOG_FILE"
    exit 1
else
    $TOUCH_CMD "$LOCK_FILE"
fi

# Function to clean up lock file on exit
cleanup() {
    $RM_CMD -f "$LOCK_FILE"
    # Destroy the temporary ipset if it exists
    if $IPSET_CMD list -n | $GREP_CMD -qw $TEMP_IPSET_NAME; then
        echo "Destroying temporary ipset: $TEMP_IPSET_NAME" >> "$LOG_FILE"
        $IPSET_CMD destroy $TEMP_IPSET_NAME
    fi
}
trap cleanup EXIT

# Create the temporary ipset with the desired type and parameters
echo "Creating temporary ipset: $TEMP_IPSET_NAME" >> "$LOG_FILE"
$IPSET_CMD create $IPSET_NAME hash:net family inet timeout $IPSET_TIMEOUT hashsize 16384 maxelem 1000000
$IPSET_CMD create $TEMP_IPSET_NAME hash:net family inet timeout $IPSET_TIMEOUT hashsize 16384 maxelem 1000000

# Download and process goog.json
GOOG_JSON_URL="https://www.gstatic.com/ipranges/goog.json"
GOOG_JSON_FILE="/tmp/goog.json"
echo "Downloading goog.json file..." >> "$LOG_FILE"
$DOWNLOAD_CMD "$GOOG_JSON_FILE" "$GOOG_JSON_URL"

# Check if download was successful
if [ $? -ne 0 ] || [ ! -f "$GOOG_JSON_FILE" ]; then
    echo "Error: Failed to download $GOOG_JSON_URL" >> "$LOG_FILE"
else
    echo "Processing goog.json file..." >> "$LOG_FILE"
    # Extract ipv4Prefix entries
    IPV4_PREFIXES=$($GREP_CMD '"ipv4Prefix"' "$GOOG_JSON_FILE" | $SED_CMD 's/.*"ipv4Prefix": *"\([^"]*\)".*/\1/')

    # Add each prefix to the temporary ipset
    for PREFIX in $IPV4_PREFIXES; do
        echo "Adding prefix: $PREFIX to temporary ipset: $TEMP_IPSET_NAME" >> "$LOG_FILE"
        $IPSET_CMD add $TEMP_IPSET_NAME $PREFIX
    done
    # remove these subnetworks to keep google dns working
    $IPSET_CMD del $TEMP_IPSET_NAME 8.8.4.0/24
    $IPSET_CMD del $TEMP_IPSET_NAME 8.8.8.0/24
fi

# Check if ASN list file exists
if [ -f "$ASN_LIST_FILE" ]; then
    echo "Processing ASN list from $ASN_LIST_FILE..." >> "$LOG_FILE"
    while read -r ASN; do
        # Skip empty lines and comments
        [ -z "$ASN" ] && continue
        echo "$ASN" | $GREP_CMD -qE '^#' && continue

        # Clean up ASN (remove leading/trailing spaces)
        ASN=$(echo "$ASN" | $TR_CMD -d '[:space:]')

        echo "Fetching IP prefixes for ASN $ASN..." >> "$LOG_FILE"
        # Fetch IP prefixes associated with the ASN
        PREFIXES=$($WHOIS_CMD -h whois.radb.net -- "-i origin AS$ASN" | $GREP_CMD -Eo 'route(:6)?:\s*[0-9a-fA-F:.]*/[0-9]+' | $GREP_CMD -Eo '[0-9a-fA-F:.]+/[0-9]+')

        if [ -z "$PREFIXES" ]; then
            echo "Warning: No prefixes found for ASN $ASN" >> "$LOG_FILE"
            continue
        fi

        # Add the prefixes to the temporary ipset
        for PREFIX in $PREFIXES; do
            # Skip IPv6 addresses (since ipset is family inet)
            echo "$PREFIX" | $GREP_CMD -q ':'
            if [ $? -eq 0 ]; then
                echo "Skipping IPv6 prefix: $PREFIX" >> "$LOG_FILE"
                continue
            fi
            echo "Adding prefix: $PREFIX to temporary ipset: $TEMP_IPSET_NAME" >> "$LOG_FILE"
            $IPSET_CMD add "$TEMP_IPSET_NAME" "$PREFIX"
        done

    done < "$ASN_LIST_FILE"
else
    echo "ASN list file $ASN_LIST_FILE not found. Skipping ASN processing." >> "$LOG_FILE"
fi

# Read domains from file and resolve them
while read -r DOMAIN; do
    # Skip empty lines and comments
    [ -z "$DOMAIN" ] && continue
    echo "$DOMAIN" | $GREP_CMD -qE '^#' && continue

    echo "Resolving domain: $DOMAIN" >> "$LOG_FILE"

    # Resolve domain to IPv4 addresses
    IP_ADDRESSES=$($TIMEOUT_CMD $DNS_QUERY_TIMEOUT $DIG_CMD +short @8.8.4.4 A $DOMAIN | $GREP_CMD -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')

    # Handle DNS query timeout or failure
    if [ $? -ne 0 ] || [ -z "$IP_ADDRESSES" ]; then
        echo "Warning: DNS query for $DOMAIN timed out or failed." >> "$LOG_FILE"
        continue
    fi

    # Add each IP to the temporary ipset
    for IP in $IP_ADDRESSES; do
        echo "Adding IP: $IP to temporary ipset: $TEMP_IPSET_NAME" >> "$LOG_FILE"
        $IPSET_CMD add $TEMP_IPSET_NAME $IP
    done

done < "$DOMAIN_LIST_FILE"


# Read IP ranges from file and add them to temporary ipset
while read -r RANGE; do
    # Skip empty lines and comments
    [ -z "$RANGE" ] && continue
    echo "$RANGE" | $GREP_CMD -qE '^\s*#' && continue

    # Trim leading and trailing whitespace
    RANGE=$(echo "$RANGE" | $SED_CMD 's/^\s*//;s/\s*$//')

    # Validate IP or IP range format
    if echo "$RANGE" | $GREP_CMD -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'; then
        echo "Adding range/IP: $RANGE to temporary ipset: $TEMP_IPSET_NAME" >> "$LOG_FILE"
        $IPSET_CMD add $TEMP_IPSET_NAME $RANGE
    else
        echo "Warning: Invalid IP or range format: $RANGE" >> "$LOG_FILE"
    fi
done < "$RANGES_FILE"


# Copy entries from existing ipset to temporary ipset, preserving remaining timeouts
echo "Copying entries from $IPSET_NAME to $TEMP_IPSET_NAME with remaining timeouts" >> "$LOG_FILE"
$IPSET_CMD save $IPSET_NAME | while read -r line; do
    case "$line" in
        add*)
            # Replace 'add IPSET_NAME' with 'add TEMP_IPSET_NAME'
            new_line=$(echo "$line" | $SED_CMD "s/add $IPSET_NAME/add $TEMP_IPSET_NAME/")
#            echo "Executing: $IPSET_CMD $new_line"  >> "$LOG_FILE"
            $IPSET_CMD $new_line
            ;;
        *)
            ;;
    esac
done

# Atomically swap the temporary ipset with the original ipset
echo "Swapping ipset $IPSET_NAME with temporary ipset $TEMP_IPSET_NAME" >> "$LOG_FILE"
$IPSET_CMD swap $IPSET_NAME $TEMP_IPSET_NAME

if [ $? -ne 0 ]; then
    echo "Error: Failed to swap ipsets" >> "$LOG_FILE"
    # Cleanup is handled by the trap
    exit 1
else
    echo "Swap successful" >> "$LOG_FILE"
    # Destroy the temporary ipset (which now holds the old ipset's data)
    echo "Destroying temporary ipset: $TEMP_IPSET_NAME" >> "$LOG_FILE"
    $IPSET_CMD destroy $TEMP_IPSET_NAME
fi

echo "ipset update completed." >> "$LOG_FILE"
