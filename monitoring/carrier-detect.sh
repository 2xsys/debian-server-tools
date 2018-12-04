#!/bin/bash
#
# List all carriers.
#
# VERSION       :0.2.0
# DATE          :2017-06-08
# URL           :https://github.com/szepeviktor/debian-server-tools
# AUTHOR        :Viktor Szépe <viktor@szepe.net>
# LICENSE       :The MIT License (MIT)
# BASH-VERSION  :4.2+

# Usage
#
#     ./carrier-detect.sh | tee ipv4
#     cat ipv4 | sort -n | uniq -c

Set_iana_special()
{
    # Uses global $IPV4_SPECIAL

    # https://www.iana.org/assignments/iana-ipv4-special-registry/iana-ipv4-special-registry.xhtml
    IPV4_SPECIAL=(
        0.
        10.
        127.
        169.254.
        192.0.0.
        192.0.2.
        192.31.196.
        192.52.193.
        192.88.99.
        192.168.
        192.175.48.
        198.51.100.
        203.0.113.
        255.255.255.255
    )

    # 100.64.0.0/10
    # 172.16.0.0/12
    # 198.18.0.0/15
    # 240.0.0.0/4
    for I in 100.{64..127}.; do IPV4_SPECIAL+=( "$I" ); done
    for I in 172.{16..31}.; do IPV4_SPECIAL+=( "$I" ); done
    for I in 198.{18..19}.; do IPV4_SPECIAL+=( "$I" ); done
    for I in {240..255}.; do IPV4_SPECIAL+=( "$I" ); done

    # Skip multicast addresses too
    for I in {224..239}.; do IPV4_SPECIAL+=( "$I" ); done
}

Match_special()
{
    # Uses global $IPV4_SPECIAL
    local IP="$1"
    local SP

    for SP in "${IPV4_SPECIAL[@]}"; do
        SP="${SP//./\\.}"
        if [[ "$IP" =~ ^${SP} ]]; then
            return 0
        fi
    done

    return 1
}

Get_addresses()
{
    local A
    local B
    local C
    local D
    local IP

    # Whole IPv4 address space
    for A in {0..255}; do
        # Four addresses, one in each 64 segment
        for B in 1 65 129 193; do
        #for B in $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)); do
            # Random third and fourth octet
            C="$((RANDOM % 256))"
            D="$((RANDOM % 254 + 1))"

            IP="${A}.${B}.${C}.${D}"
            if Match_special "$IP"; then
                continue
            fi

            # Return the address
            echo "$IP"
        done
    done
}

declare -a IPV4_SPECIAL

set -e

Set_iana_special

for IP in $(Get_addresses); do
    echo "        ${IP} ..." 1>&2

    HOP="$(traceroute -n -4 -w 2 -f 2 -m 2 "$IP" | sed -n -e '$s/^ 2  \([0-9.]\+\) .*$/\1/p')"
    # Detect local routers
    if [[ "$HOP" =~ ^94\.237\.(24|25|26|27|28|29|30|31)\. ]]; then
        echo "        Third hop ..." 1>&2
        HOP="$(traceroute -n -4 -w 2 -f 3 -m 3 "$IP" | sed -n -e '$s/^ 3  \([0-9.]\+\) .*$/\1/p')"
    fi
    #if [[ "$HOP" =~ ^0.0.0\. ]]; then
    #    echo "        Fourth hop ..." 1>&2
    #    HOP="$(traceroute -n -4 -w 2 -f 4 -m 4 "$IP" | sed -n -e '$s/^ 4  \([0-9.]\+\) .*$/\1/p')"
    #fi
    if [ -n "$HOP" ]; then
        echo "$HOP"
    fi
done
