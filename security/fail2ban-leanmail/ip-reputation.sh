#!/bin/bash
#
# Check the reputation of an IP address
#
# VERSION       :0.1.0
# DATE          :2018-09-09
# AUTHOR        :Viktor Szépe <viktor@szepe.net>
# URL           :https://github.com/szepeviktor/debian-server-tools
# LICENSE       :The MIT License (MIT)
# BASH-VERSION  :4.2+
# DEPENDS       :apt-get install dnsutils dos2unix grepcidr geoip-database-contrib jq sipcalc
# CONFIG        :~/.config/ip-reputation/configuration
# LOCATION      :/usr/local/bin/ip-reputation.sh
# CRON-HOURLY   :/usr/local/bin/ip-reputation.sh cron

# Default configuration

# Full IP match or first three octets only (Class C)
# Value: 0 or 1
CLASSC_MATCH="0"

# DNS resolver
NS1="1.1.1.1"

# Timeout in seconds
TIMEOUT="3"

# List cache path
CACHE_DIR="${HOME}/.cache/ip-reputation"

# Last 100 unmatched attackers
KNOWN_IP="${CACHE_DIR}/known.list"

# GeoIP database
GEOIP_COUNTRY="/usr/share/GeoIP/GeoIP.dat"
GEOIP_AS="/usr/share/GeoIP/GeoIPASNum.dat"

CONFIGURATION="${HOME}/.config/ip-reputation/configuration"

Is_ipv4()
{
    local TOBEIP="$1"
    #             0-9  10-99  100-199   200-249     250-255
    local OCTET="([1-9]?[0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])"

    [[ "$TOBEIP" =~ ^${OCTET}\.${OCTET}\.${OCTET}\.${OCTET}$ ]]
}

Reverse_ip()
{
    local IPV4="$1"
    local OCTET1 OCTET2 OCTET3 OCTET4

    IFS="." read -r OCTET1 OCTET2 OCTET3 OCTET4 <<< "$IPV4"

    echo "${OCTET4}.${OCTET3}.${OCTET2}.${OCTET1}"
}

Ip2dec()
{
    local IPV4="$1"
    local -i OCTET1 OCTET2 OCTET3 OCTET4

    IFS="." read -r OCTET1 OCTET2 OCTET3 OCTET4 <<< "$IPV4"
    echo "$(( (OCTET1 << 24) + (OCTET2 << 16) + (OCTET3 << 8) + OCTET4 ))"
}

Log_match() {
    local MATCH="$1"

    logger -t "ip-reputation" "IP with low reputation '${IP}' matches ${MATCH}"
}

Get_cache_file()
{
    local URL="$1"
    local SHA
    local CACHE_FILE
    local CACHE_FILE_TEMP

    SHA="$(printf '%s' "$URL" | shasum -a 256 | cut -d " " -f 1)"
    CACHE_FILE="${CACHE_DIR}/${SHA}"

    if [ ! -s "$CACHE_FILE" ]; then
        install --mode=0660 /dev/null "$CACHE_FILE"
        # Lock for singleton execution
        # shellcheck disable=SC2094
        {
            flock --nonblock --conflict-exit-code 101 9 || return 0

            CACHE_FILE_TEMP="$(mktemp "${CACHE_FILE}.XXXXXXXXXX")"
            # Long timeout, three tries
            wget -q -T 20 -t 3 -O "$CACHE_FILE_TEMP" "$URL" 2>/dev/null

            # Circumvent the case of partially downloaded file
            # shellcheck disable=SC2181
            if [ "$?" == 0 ] && [ -s "$CACHE_FILE_TEMP" ]; then
                dos2unix --quiet "$CACHE_FILE_TEMP" 2>/dev/null
                mv -f "$CACHE_FILE_TEMP" "$CACHE_FILE"
                chmod 0660 "$CACHE_FILE"
            else
                # Remove empty cache item
                rm -f "$CACHE_FILE_TEMP"
            fi
        } 9<"$CACHE_FILE"
    fi

    echo "$CACHE_FILE"
}

Is_aws()
{
    local IP="$1"
    local -r URL="https://ip-ranges.amazonaws.com/ip-ranges.json"
    local IPDEC AMAZON_JSON RANGES
    local RANGE START_END STARTDEC ENDDEC

    IPDEC="$(Ip2dec "$IP")"
    AMAZON_JSON="$(Get_cache_file "$URL")"

    if [ ! -s "$AMAZON_JSON" ]; then
        return 10
    fi

    RANGES="$(jq -r '.prefixes[].ip_prefix' "$AMAZON_JSON")"

    while read -r RANGE; do
        START_END="$(sipcalc "$RANGE" | sed -n -e 's/^Network range\s\+- \([0-9.]\+\) - \([0-9.]\+\)$/\1:\2/p')"
        STARTDEC="$(Ip2dec "${START_END%:*}")"
        ENDDEC="$(Ip2dec "${START_END#*:}")"
        if [ "$IPDEC" -ge "$STARTDEC" ] && [ "$IPDEC" -le "$ENDDEC" ]; then
            # There is a match
            return 0
        fi
    done <<<"$RANGES"

    # No match
    return 1
}

Match_list()
{
    local IP="$1"
    local LIST="$2"
    local CACHE_FILE
    local IP_24

    CACHE_FILE="$(Get_cache_file "$LIST")"

    if [ ! -s "$CACHE_FILE" ]; then
        return 10
    fi

    if [ "$CLASSC_MATCH" == 0 ]; then
        # Full match
        grep -q -F -x "$IP" "$CACHE_FILE"
    else
        # /24 match
        IP_24="${IP%.*}"
        grep -q -E -x "${IP_24//./\\.}\\.[0-9]{1,3}" "$CACHE_FILE"
    fi
}

Match_country()
{
    local IP="$1"
    local COUNTRY="$2"

    if /usr/bin/geoiplookup -f "$GEOIP_COUNTRY" "$IP" \
        | cut -d ":" -f 2- | grep -q "^ ${COUNTRY},"; then
        # Country found
        return 0
    fi

    return 10
}

Match_autonomoussystems()
{
    local IP="$1"
    shift
    # $2 $3 ...
    local -a AUTONOMOUS_SYSTEMS=( "$@" )
    local IP_AS
    local AS

    IP_AS="$(/usr/bin/geoiplookup -f "$GEOIP_AS" "$IP" | cut -d ":" -f 2-)"

    for AS in "${AUTONOMOUS_SYSTEMS[@]}"; do
        if grep -q "^ ${AS} " <<<"$IP_AS"; then
            # AS found
            return 0
        fi
    done

    return 10
}

Match_known()
{
    local IP="$1"

    if [ -s "$KNOWN_IP" ] && grep -q -F -x "$IP" "$KNOWN_IP"; then
        # IP is known
        return 0
    fi

    return 10
}

Match_commented_list()
{
    local IP="$1"
    local LIST="$2"
    local CACHE_FILE

    CACHE_FILE="$(Get_cache_file "$LIST")"

    if [ ! -s "$CACHE_FILE" ]; then
        return 10
    fi

    grepcidr -q -f "$CACHE_FILE" <<< "$IP"
}

Match_cidr_list()
{
    local IP="$1"
    local LIST="$2"
    local CACHE_FILE

    CACHE_FILE="$(Get_cache_file "$LIST")"

    if [ ! -s "$CACHE_FILE" ]; then
        return 10
    fi

    grepcidr -f "$CACHE_FILE" <<<"$IP" &>/dev/null
}

# Service-specific functions #

Match_httpbl()
{
    local IP="$1"
    local ACCESSKEY="$2"
    local HOSTNAME
    local ANSWER

    # https://www.projecthoneypot.org/httpbl_api.php
    printf -v HOSTNAME "%s.%s.dnsbl.httpbl.org." "$ACCESSKEY" "$(Reverse_ip "$IP")"

    # First answer
    ANSWER="$(dig +retry=0 +time="$TIMEOUT" +short @"$NS1" "$HOSTNAME" A 2>/dev/null | head -n 1)"

    if ! Is_ipv4 "$ANSWER"; then
        # NXDOMAIN, network error or invalid IP
        return 10
    fi

    # Fourth octet represents the type of visitor
    # 0 = Search Engine
    test "${ANSWER##*.}" != 0
}

Match_spamhaus()
{
    local IP="$1"
    local HOSTNAME
    local ANSWER

    # Combination of SBL, SBLCSS, XBL and PBL blocklists
    # https://www.spamhaus.org/zen/
    # XBL includes CBL (result: 127.0.0.2)
    # http://www.abuseat.org/faq.html
    printf -v HOSTNAME "%s.zen.spamhaus.org." "$(Reverse_ip "$IP")"

    # First answer
    ANSWER="$(dig +retry=0 +time="$TIMEOUT" +short @"$NS1" "$HOSTNAME" A 2>/dev/null | head -n 1)"

    if ! Is_ipv4 "$ANSWER"; then
        # NXDOMAIN, network error or invalid IP
        return 10
    fi

    # SBL:    127.0.0.2     - The Spamhaus Block List
    # CSS:    127.0.0.3     - Spamhaus CSS Component
    # XBL:    127.0.0.4-7   - Exploits Block List
    # No PBL: 127.0.0.10-11 - The Policy Block List
    [[ "$ANSWER" =~ ^127\.0\.0\.[234567]$ ]]
}

Match_dangerous()
{
    local IP="$1"
    local HOSTNAME
    local ANSWER

    # Private list of dangerous networks
    # See: /mail/spammer.dnsbl/dangerous.dnsbl.zone
    printf -v HOSTNAME "%s.dangerous.dnsbl." "$(Reverse_ip "$IP")"

    # First answer
    ANSWER="$(dig +retry=0 +time="$TIMEOUT" +short @"$NS1" "$HOSTNAME" A 2>/dev/null | head -n 1)"

    if ! Is_ipv4 "$ANSWER"; then
        # NXDOMAIN, network error or invalid IP
        return 10
    fi

    # 127.0.0.1   - Dangerous network
    # 127.0.0.2   - Tor exit node
    # 127.0.0.128 - Blocked network
    [[ "$ANSWER" =~ ^127\.0\.0\.(1|2|128)$ ]]
}

Match_tor()
{
    local IP="$1"
    local OWN_IP
    local HOSTNAME
    local ANSWER

    # https://www.torproject.org/projects/tordnsel.html.en
    OWN_IP="$(ip addr show dev eth0 | sed -n -e 's/^\s*inet \([0-9\.]\+\)\b.*$/\1/p')"
    printf -v HOSTNAME "%s.80.%s.ip-port.exitlist.torproject.org." "$(Reverse_ip "$IP")" "$(Reverse_ip "$OWN_IP")"

    # First answer
    ANSWER="$(dig +retry=0 +time="$TIMEOUT" +short @"$NS1" "$HOSTNAME" A 2>/dev/null | head -n 1)"

    if ! Is_ipv4 "$ANSWER"; then
        # NXDOMAIN, network error or invalid IP
        return 10
    fi

    # Tor IP
    test "$ANSWER" == "127.0.0.2"
}

Match_barracuda()
{
    local IP="$1"
    local HOSTNAME
    local ANSWER

    # Barracuda Reputation Block List
    # http://www.barracudacentral.org/rbl/how-to-use
    printf -v HOSTNAME "%s.b.barracudacentral.org." "$(Reverse_ip "$IP")"

    # First answer
    ANSWER="$(dig +retry=0 +time="$TIMEOUT" +short @"$NS1" "$HOSTNAME" A 2>/dev/null | head -n 1)"

    if ! Is_ipv4 "$ANSWER"; then
        # NXDOMAIN, network error or invalid IP
        return 10
    fi

    # Listed
    test "$ANSWER" == "127.0.0.2"
}

Match_stopforumspam()
{
    local IP="$1"
    local URL
    local ANSWER

    # http://www.stopforumspam.com/usage
    printf -v URL "https://api.stopforumspam.org/api?json&ip=%s" "$IP"

    ANSWER="$(wget -q -T "$TIMEOUT" -t 1 -O - "$URL" 2>/dev/null)"
    if [ "$(jq -r '.success' <<< "$ANSWER")" != 1 ]; then
        return 10
    fi

    # IP is positive
    test "$(jq -r '.ip.appears' <<< "$ANSWER")" != 1
}

Match_dshield()
{
    local IP="$1"
    local URL

    # https://www.dshield.org/api/
    # handlers-a-t-isc.sans.edu
    printf -v URL "https://dshield.org/api/ip/%s" "$IP"

    if wget -q -T "$TIMEOUT" -t 1 -O - "$URL" 2>/dev/null | grep -q '<attacks>[0-9]\+</attacks>'; then
        # IP is positive
        return 0
    fi

    return 10
}

Match_accesswatch()
{
    local IP="$1"
    local APIKEY="$2"
    local URL

    # https://access.watch/
    printf -v URL "https://api.access.watch/1.1/address/%s" "$IP"

    #if wget -q -T "$TIMEOUT" -t 1 -O - \
    if wget -q -T "10" -t 1 -O - \
        --header="Accept: application/json" \
        --header="Api-Key: ${APIKEY}" \
        "$URL" 2>/dev/null \
        | grep -F -A 1 '"reputation": {' | grep -q -E '"status": "(bad|suspicious)",'; then
        # IP is positive
        return 0
    fi

    return 10
}

Match()
{
    # ANY or ALL
    local MODE="$1"

    # Exclusions

    if Is_aws "$IP"; then
        if [ "$MODE" == ANY ]; then
            # It is an error to ban CloudFront
            Log_match "Amazon CloudFront ERROR"
            return 2
        fi
        echo "amazon-cloudfront"
    fi

    # Cacheables ordered by hit rate

    # https://www.blocklist.de/en/export.html
    if Match_list "$IP" "https://lists.blocklist.de/lists/all.txt"; then
        if [ "$MODE" == ANY ]; then
            Log_match "blde"
            return 0
        fi
        echo "blde"
    fi

    # @global AS_HOSTING
    if Match_autonomoussystems "$IP" "${AS_HOSTING[@]}"; then
        if [ "$MODE" == ANY ]; then
            Log_match "hosting"
            return 0
        fi
        echo "hosting"
    fi

    # https://greensnow.co/
    # https://api.greensnow.co/
    if Match_list "$IP" "https://blocklist.greensnow.co/greensnow.txt"; then
        if [ "$MODE" == ANY ]; then
            Log_match "greensnow"
            return 0
        fi
        echo "greensnow"
    fi

    if Match_known "$IP"; then
        if [ "$MODE" == ANY ]; then
            Log_match "known-attacker"
            return 0
        fi
        echo "known-attacker"
    fi

    if Match_country "$IP" A1; then
        if [ "$MODE" == ANY ]; then
            Log_match "anonymous-proxy"
            return 0
        fi
        echo "anonymous-proxy"
    fi

    # https://www.alienvault.com/forums/discussion/5246/otx-reputation-file-format
    if Match_list "$IP" "https://reputation.alienvault.com/reputation.snort"; then
        if [ "$MODE" == ANY ]; then
            Log_match "alienvault"
            return 0
        fi
        echo "alienvault"
    fi

    # Network tests ordered by hit rate

    # @global ACCESSWATCH_APIKEY
    if Match_accesswatch "$IP" "$ACCESSWATCH_APIKEY"; then
        if [ "$MODE" == ANY ]; then
            Log_match "accesswatch"
            return 0
        fi
        echo "accesswatch"
    fi

    if Match_spamhaus "$IP"; then
        if [ "$MODE" == ANY ]; then
            Log_match "spamhaus"
            return 0
        fi
        echo "spamhaus"
    fi

    if Match_barracuda "$IP"; then
        if [ "$MODE" == ANY ]; then
            Log_match "barracuda"
            return 0
        fi
        echo "barracuda"
    fi

    if Match_dshield "$IP"; then
        if [ "$MODE" == ANY ]; then
            Log_match "dshield"
            return 0
        fi
        echo "dshield"
    fi

    if Match_tor "$IP"; then
        if [ "$MODE" == ANY ]; then
            Log_match "tordnsel"
            return 0
        fi
        echo "tordnsel"
    fi

    if Match_dangerous "$IP"; then
        if [ "$MODE" == ANY ]; then
            Log_match "dangerous"
            return 0
        fi
        echo "dangerous"
    fi

    if [ "$MODE" == ANY ]; then
        # Haven't matched any
        return 1
    fi

    # Only in ALL mode #

    # https://www.blocklist.de/en/api.html
    if Match_list "$IP" "https://api.blocklist.de/getlast.php?time=3600"; then
        echo "blde-1h"
    fi

    # https://www.projecthoneypot.org/httpbl_api.php
    # @global HTTPBL_ACCESSKEY
    if Match_httpbl "$IP" "$HTTPBL_ACCESSKEY"; then
        echo "httpbl"
    fi
}

set -e

# Check cache directory
test -r "$CONFIGURATION" || exit 125

# shellcheck disable=SC1090
source "$CONFIGURATION"

# Check cache directory
test -d "$CACHE_DIR" || exit 125

IP="$1"

# Check IP address
test -n "$IP" || exit 100

# Cache flush in cron job
if [ "$IP" == cron ]; then
    find "$CACHE_DIR" -type f -regextype posix-egrep -regex '^[0-9a-f]{64}$' -delete
    # Keep last 100 known IP-s
    if [ -s "$KNOWN_IP" ]; then
        # shellcheck disable=SC2016
        sed -e ':a;$q;N;101,$D;ba' -i "$KNOWN_IP"
    fi
    # Populate cache
    IP="127.0.0.2"
    Match ALL
    exit 0
fi

# Default mode is ANY
Match "${2:-ANY}"
