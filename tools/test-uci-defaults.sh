#!/bin/sh
# Run complete defaults against a UCI mock, or the native UCI CLI when supplied.
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
mkdir -p "$repo_dir/logs/uci-defaults"
test_root="$(mktemp -d "$repo_dir/logs/uci-defaults/test.XXXXXX")"
UCI_REAL="${1:-}"
if [ -n "$UCI_REAL" ]; then
    [ -x "$UCI_REAL" ] || { echo 'Supply an executable native UCI binary' >&2; exit 1; }
    UCI_REAL="$(CDPATH= cd -- "$(dirname -- "$UCI_REAL")" && pwd)/$(basename -- "$UCI_REAL")"
fi
UCI_MOCK_COMMANDS="$test_root/commands.sh"
export UCI_REAL UCI_MOCK_COMMANDS

cat > "$UCI_MOCK_COMMANDS" <<'MOCK'
uci() {
    [ "$1" != '-q' ] || shift
    action="$1"
    shift
    case "$action" in
        set|add_list|del_list)
            key="${1%%=*}"
            [ "$key" != "${UCI_FAIL_SET:-}" ] || return 1
            printf '%s %s\n' "$action" "$key" >> "$UCI_CASE/writes"
            ;;
        delete) printf 'delete %s\n' "$1" >> "$UCI_CASE/writes" ;;
        commit) [ "${1:-}" != "${UCI_FAIL_COMMIT:-}" ] || return 1 ;;
    esac
    if [ -n "$UCI_REAL" ]; then
        "$UCI_REAL" -c "$UCI_CASE/config" -P "$UCI_CASE/delta" "$action" "$@" || return $?
        [ "$action" != commit ] || printf '%s\n' "$1" >> "$UCI_CASE/commits"
        return 0
    fi
    case "$action" in
        get)
            [ -f "$UCI_CASE/db/$1" ] || return 1
            cat "$UCI_CASE/db/$1"
            ;;
        set|add_list|del_list)
            key="${1%%=*}"
            value="${1#*=}"
            case "$action" in
                set) printf '%s\n' "$value" > "$UCI_CASE/db/$key" ;;
                add_list)
                    previous="$(cat "$UCI_CASE/db/$key" 2>/dev/null || true)"
                    printf '%s\n' "${previous:+$previous }$value" > "$UCI_CASE/db/$key"
                    ;;
                del_list)
                    [ -f "$UCI_CASE/db/$key" ] || return 1
                    remaining=''
                    for item in $(cat "$UCI_CASE/db/$key"); do
                        [ "$item" = "$value" ] || remaining="${remaining:+$remaining }$item"
                    done
                    printf '%s\n' "$remaining" > "$UCI_CASE/db/$key"
                    ;;
            esac
            ;;
        delete)
            [ -f "$UCI_CASE/db/$1" ] || return 1
            rm "$UCI_CASE/db/$1"
            ;;
        commit)
            for entry in "$UCI_CASE/committed/$1".*; do
                [ ! -f "$entry" ] || rm "$entry"
            done
            for entry in "$UCI_CASE/db/$1".*; do
                [ ! -f "$entry" ] || cp "$entry" "$UCI_CASE/committed/"
            done
            printf '%s\n' "$1" >> "$UCI_CASE/commits"
            ;;
        *) printf 'Unexpected UCI command: %s\n' "$action" >&2; return 1 ;;
    esac
}
logger() { printf '%s\n' "$*" >> "$UCI_CASE/messages"; }
# Supply a deterministic random prefix and isolated IPv6 presence to both
# backends, so role transitions cover ULA restoration on non-Linux hosts too.
hexdump() { printf 'fd12:3456:789a:'; }
MOCK

raw_uci() { "$UCI_REAL" -c "$UCI_CASE/config" -P "$UCI_CASE/delta" "$@"; }
put() {
    if [ -n "$UCI_REAL" ]; then
        case "$1" in
            *.ports)
                raw_uci -q delete "$1" || true
                for item in $2; do raw_uci add_list "$1=$item"; done
                ;;
            *) raw_uci set "$1=$2" ;;
        esac
    else printf '%s\n' "$2" > "$UCI_CASE/db/$1"
    fi
}
get() {
    if [ -n "$UCI_REAL" ]; then raw_uci -q get "$1" || true
    else cat "$UCI_CASE/db/$1" 2>/dev/null || true
    fi
}
committed() {
    if [ -n "$UCI_REAL" ]; then
        "$UCI_REAL" -c "$UCI_CASE/config" -P "$UCI_CASE/clean-delta" -q get "$1" || true
    else cat "$UCI_CASE/committed/$1" 2>/dev/null || true
    fi
}
remove_option() {
    if [ -n "$UCI_REAL" ]; then raw_uci -q delete "$1" || true
    else rm -f "$UCI_CASE/db/$1"
    fi
}
seal_fixture() {
    if [ -n "$UCI_REAL" ]; then raw_uci commit
    else cp "$UCI_CASE/db/"* "$UCI_CASE/committed/"
    fi
    : > "$UCI_CASE/writes"
    : > "$UCI_CASE/commits"
}
assert_eq() {
    if [ "$1" != "$2" ]; then
        printf 'FAIL: %s (%s): expected [%s], got [%s]\n' "$3" "$UCI_CASE" "$2" "$1" >&2
        exit 1
    fi
}
assert_no_writes() {
    [ ! -s "$UCI_CASE/writes" ] && [ ! -s "$UCI_CASE/commits" ] || {
        printf 'FAIL: preflight changed UCI: %s\n' "$UCI_CASE" >&2
        exit 1
    }
}
new_case() {
    UCI_CASE="$test_root/$role-$1"
    UCI_FAIL_SET=''
    UCI_FAIL_COMMIT=''
    fixture_unsealed=1
    lan_prefix='10.0.0'
    export UCI_CASE UCI_FAIL_SET UCI_FAIL_COMMIT
    mkdir -p "$UCI_CASE/db" "$UCI_CASE/committed" "$UCI_CASE/sys" "$UCI_CASE/ipv6" "$UCI_CASE/config" "$UCI_CASE/delta" "$UCI_CASE/clean-delta"
    printf '%s\n' "${3:-zyxel,ex5601-t0-ubootmod}" > "$UCI_CASE/board_name"
    if [ -n "$UCI_REAL" ]; then
        cat > "$UCI_CASE/config/network" <<'CONFIG'
config interface 'lan'
config interface 'wan'
config interface 'wan6'
config globals 'globals'
config device
config device
config device
CONFIG
        cat > "$UCI_CASE/config/wireless" <<'CONFIG'
config wifi-device
config wifi-device
config wifi-iface
config wifi-iface
config wifi-iface
CONFIG
        printf "config dhcp 'lan'\n" > "$UCI_CASE/config/dhcp"
        printf 'config system\n' > "$UCI_CASE/config/system"
    fi
    put network.wan interface
    put network.wan.device "$2"
    put network.wan.proto pppoe
    put network.wan.username fixture-user
    put network.wan.password fixture-secret
    put network.wan6 interface
    put network.wan6.device @wan
    put network.lan.device br-lan
    put network.lan.ipaddr 192.0.2.1
    put 'network.@device[0].name' br-lan
    put 'network.@device[0].type' bridge
    put 'network.@device[0].ports' 'lan1 lan2 lan3 lan4'
    put network.globals.ula_prefix fd12:3456:789a::/48
    put 'wireless.@wifi-device[0]' wifi-device
    put 'wireless.@wifi-device[0].band' 2g
    put 'wireless.@wifi-device[0].disabled' 0
    put 'wireless.@wifi-device[1]' wifi-device
    put 'wireless.@wifi-device[1].band' 5g
    put 'wireless.@wifi-device[1].disabled' 1
    put 'wireless.@wifi-iface[0]' wifi-iface
    put 'wireless.@wifi-iface[0].mode' ap
    put 'wireless.@wifi-iface[0].ssid' fixture-main
    put 'wireless.@wifi-iface[0].encryption' sae
    put 'wireless.@wifi-iface[0].key' old-fixture-key
    put 'wireless.@wifi-iface[0].disabled' 0
    put 'wireless.@wifi-iface[1]' wifi-iface
    put 'wireless.@wifi-iface[1].mode' ap
    put 'wireless.@wifi-iface[1].ssid' fixture-disabled
    put 'wireless.@wifi-iface[1].disabled' 1
    put 'wireless.@wifi-iface[2]' wifi-iface
    put 'wireless.@wifi-iface[2].mode' sta
    put 'wireless.@wifi-iface[2].encryption' sae
    put 'wireless.@wifi-iface[2].key' station-fixture-key
}
run_defaults() {
    if [ "$fixture_unsealed" -eq 1 ]; then
        seal_fixture
        fixture_unsealed=0
    else
        : > "$UCI_CASE/writes"
        : > "$UCI_CASE/commits"
    fi
    {
        printf '. "$UCI_MOCK_COMMANDS"\n'
        sed -e "s@/sys/class/net@$UCI_CASE/sys@g" \
            -e "s@/tmp/sysinfo/board_name@$UCI_CASE/board_name@g" \
            -e "s@/proc/sys/net/ipv6@$UCI_CASE/ipv6@g" \
            -e "s@^lan_prefix=.*@lan_prefix='$lan_prefix'@" \
            -e 's/\r$//' "$repo_dir/uci-defaults/$role"
    } > "$UCI_CASE/defaults.sh"
    if sh "$UCI_CASE/defaults.sh" > "$UCI_CASE/stdout" 2> "$UCI_CASE/stderr"; then
        actual_status=0
    else
        actual_status=$?
    fi
    assert_eq "$actual_status" "$1" 'defaults exit status'
}
assert_role() {
    case "$role" in
        ap)
            assert_eq "$(get 'network.@device[0].ports')" "lan1 lan2 lan3 lan4 $1" 'AP includes WAN once'
            assert_eq "$(get network.lan.ipaddr)" "$lan_prefix.9/24" 'AP management address'
            assert_eq "$(get network.lan.gateway)" "$lan_prefix.1" 'AP gateway'
            assert_eq "$(get network.lan.dns)" "$lan_prefix.1" 'AP DNS'
            assert_eq "$(get network.wan.disabled)" 1 'AP WAN disabled'
            assert_eq "$(get network.wan6.disabled)" 1 'AP WAN6 disabled'
            assert_eq "$(get network.lan.ip6assign)" '' 'AP IPv6 assignment removed'
            assert_eq "$(get network.globals.ula_prefix)" '' 'AP ULA removed'
            assert_eq "$(get dhcp.lan.ignore)" 1 'AP DHCP ignored'
            assert_eq "$(get dhcp.lan.dhcpv4)" disabled 'AP DHCPv4 disabled'
            assert_eq "$(get dhcp.lan.ra)" disabled 'AP RA disabled'
            ;;
        router)
            assert_eq "$(get 'network.@device[0].ports')" 'lan1 lan2 lan3 lan4' 'router removes WAN'
            assert_eq "$(get network.lan.ipaddr)" "$lan_prefix.1/24" 'router management address'
            assert_eq "$(get network.lan.gateway)" '' 'router has no LAN gateway override'
            assert_eq "$(get network.lan.dns)" '' 'router has no LAN DNS override'
            assert_eq "$(get network.wan.disabled)" '' 'router WAN enabled'
            assert_eq "$(get network.wan6.disabled)" '' 'router WAN6 enabled'
            assert_eq "$(get network.lan.ip6assign)" 60 'router IPv6 assignment'
            assert_eq "$(get network.globals.ula_prefix)" 'fd12:3456:789a::/48' 'router ULA retained/restored'
            assert_eq "$(get dhcp.lan.ignore)" 0 'router DHCP active'
            assert_eq "$(get dhcp.lan.dhcpv4)" server 'router DHCPv4'
            assert_eq "$(get dhcp.lan.start)" 100 'router DHCP range start'
            assert_eq "$(get dhcp.lan.limit)" 150 'router DHCP range size'
            assert_eq "$(get dhcp.lan.leasetime)" 12h 'router DHCP leases'
            assert_eq "$(get dhcp.lan.ra)" server 'router RA active'
            assert_eq "$(get dhcp.lan.ra_slaac)" 1 'router SLAAC'
            ;;
    esac
    assert_eq "$(get network.wan.proto)" pppoe 'saved WAN protocol'
    assert_eq "$(get network.wan.password)" fixture-secret 'saved WAN credentials'
    assert_eq "$(get network.lan.proto)" static 'LAN protocol'
    assert_eq "$(get dhcp.lan.dhcpv6)" disabled 'DHCPv6 disabled'
    assert_eq "$(get 'system.@system[0].zonename')" Europe/Stockholm 'timezone name'
    assert_eq "$(get 'wireless.@wifi-device[0].country')" SE '2.4 GHz country'
    assert_eq "$(get 'wireless.@wifi-device[1].country')" SE '5 GHz country'
    assert_eq "$(get 'wireless.@wifi-device[0].channel')" auto '2.4 GHz automatic channel'
    assert_eq "$(get 'wireless.@wifi-device[1].channel')" auto '5 GHz automatic channel'
    assert_eq "$(get 'wireless.@wifi-device[0].htmode')" HE40 '2.4 GHz width'
    assert_eq "$(get 'wireless.@wifi-device[1].htmode')" HE80 '5 GHz width'
    assert_eq "$(get 'wireless.@wifi-device[1].disabled')" 1 'disabled radio retained'
    assert_eq "$(get 'wireless.@wifi-iface[0].ssid')" fixture-main 'SSID retained'
    assert_eq "$(get 'wireless.@wifi-iface[1].ssid')" fixture-disabled 'disabled AP SSID retained'
    assert_eq "$(get 'wireless.@wifi-iface[1].disabled')" 1 'disabled AP retained'
    for i in 0 1; do
        assert_eq "$(get "wireless.@wifi-iface[$i].encryption")" psk2 'AP security default'
        assert_eq "$(get "wireless.@wifi-iface[$i].key")" password123 'AP key default'
    done
    assert_eq "$(get 'wireless.@wifi-iface[2].key')" station-fixture-key 'station key retained'
    assert_eq "$(get 'wireless.@wifi-iface[2].encryption')" sae 'station security retained'
    assert_eq "$(committed network.lan.ipaddr)" "$(get network.lan.ipaddr)" 'network committed'
    assert_eq "$(committed 'wireless.@wifi-iface[0].key')" password123 'wireless committed'
}

for role in ap router; do
    new_case legacy eth1
    mkdir "$UCI_CASE/sys/wan"
    put network.wan6.device eth1
    put 'network.@device[0].ports' 'lan1 lan2 lan3 lan4 eth1'
    put 'network.@device[1].name' eth1
    put 'network.@device[1].macaddr' 02:00:00:00:00:01
    run_defaults 0
    assert_eq "$(get network.wan.device)" wan 'legacy WAN migration'
    assert_eq "$(get network.wan6.device)" wan 'legacy WAN6 migration'
    assert_eq "$(get 'network.@device[1].name')" wan 'legacy device migration'
    assert_eq "$(get 'network.@device[1].macaddr')" 02:00:00:00:00:01 'device options preserved'
    assert_role wan
    run_defaults 0
    assert_role wan

    for board in zyxel glinet; do
        for subnet in 10.0.0 192.168.1; do
            if [ "$board" = glinet ]; then wan=eth0; board_name=glinet,gl-mt3000
            else wan=wan; board_name=zyxel,ex5601-t0-ubootmod
            fi
            new_case "$board-$subnet" "$wan" "$board_name"
            lan_prefix="$subnet"
            mkdir "$UCI_CASE/sys/$wan"
            put 'network.@device[0].ports' "lan1 lan2 lan3 lan4 $wan"
            run_defaults 0
            assert_role "$wan"
            assert_eq "$(get network.wan6.device)" @wan 'dynamic WAN6 retained'
        done
    done

    new_case missing eth1
    run_defaults 1
    assert_no_writes

    new_case other-board eth1 other,board
    mkdir "$UCI_CASE/sys/wan"
    run_defaults 1
    assert_no_writes

    new_case old-name-still-exists eth1
    mkdir "$UCI_CASE/sys/wan" "$UCI_CASE/sys/eth1"
    run_defaults 0
    assert_eq "$(get network.wan.device)" eth1 'existing eth1 preserved'
    assert_role eth1

    for scenario in vlan wan6-vlan conflicting-devices wan-is-bridge; do
        new_case "$scenario" eth1
        mkdir "$UCI_CASE/sys/wan"
        case "$scenario" in
            vlan) put network.wan.device eth1.35 ;;
            wan6-vlan) put network.wan6.device eth1.35 ;;
            conflicting-devices)
                put 'network.@device[1].name' eth1
                put 'network.@device[2].name' wan
                ;;
            wan-is-bridge)
                put network.wan.device wan
                mkdir "$UCI_CASE/sys/wan/bridge"
                ;;
        esac
        run_defaults 1
        assert_no_writes
    done

    for scenario in missing-radio missing-band missing-mode no-ap; do
        new_case "$scenario" eth1
        mkdir "$UCI_CASE/sys/wan"
        case "$scenario" in
            missing-radio)
                # Remove highest index first: real UCI renumbers anonymous sections.
                remove_option 'wireless.@wifi-device[1]'
                remove_option 'wireless.@wifi-device[0]'
                ;;
            missing-band) remove_option 'wireless.@wifi-device[1].band' ;;
            missing-mode) remove_option 'wireless.@wifi-iface[1].mode' ;;
            no-ap)
                put 'wireless.@wifi-iface[0].mode' sta
                put 'wireless.@wifi-iface[1].mode' sta
                ;;
        esac
        run_defaults 1
        assert_no_writes
        assert_eq "$(committed network.wan.device)" eth1 'preflight preserves saved WAN'
        assert_eq "$(committed network.lan.ipaddr)" 192.0.2.1 'preflight preserves saved address'
    done

    new_case failed-migration eth1
    mkdir "$UCI_CASE/sys/wan"
    UCI_FAIL_SET=network.wan.device
    export UCI_FAIL_SET
    run_defaults 1
    assert_no_writes

    new_case late-write wan
    mkdir "$UCI_CASE/sys/wan"
    UCI_FAIL_SET='wireless.@wifi-device[1].country'
    export UCI_FAIL_SET
    run_defaults 1
    assert_eq "$(committed 'wireless.@wifi-device[0].country')" '' 'failed wireless writes uncommitted'
    assert_eq "$(committed 'wireless.@wifi-iface[0].key')" old-fixture-key 'failed wireless preserves saved key'
    assert_eq "$(committed network.lan.ipaddr)" "$lan_prefix.$([ "$role" = ap ] && echo 9 || echo 1)/24" 'earlier commit remains visible'
    UCI_FAIL_SET=''
    export UCI_FAIL_SET
    run_defaults 0
    assert_role wan

    for package in network dhcp wireless; do
        new_case "commit-$package" wan
        mkdir "$UCI_CASE/sys/wan"
        UCI_FAIL_COMMIT="$package"
        export UCI_FAIL_COMMIT
        run_defaults 1
        case "$package" in
            network) assert_eq "$(committed network.lan.ipaddr)" 192.0.2.1 'failed network commit retains saved address' ;;
            dhcp) assert_eq "$(committed dhcp.lan.dhcpv4)" '' 'failed DHCP commit retains saved settings' ;;
            wireless) assert_eq "$(committed 'wireless.@wifi-iface[0].key')" old-fixture-key 'failed wireless commit retains saved key' ;;
        esac
        UCI_FAIL_COMMIT=''
        export UCI_FAIL_COMMIT
        run_defaults 0
        assert_role wan
    done
done

role=ap
new_case role-transitions wan
mkdir "$UCI_CASE/sys/wan"
for role in ap router ap router; do
    run_defaults 0
    assert_role wan
done
printf 'Defaults tests passed (%s): roles, subnets, migration, Wi-Fi preflight, transitions, writes and commits. Fixtures: %s\n' "${UCI_REAL:-mock}" "$test_root"
