#!/bin/sh
# Execute both complete defaults scripts against isolated UCI and sysfs fixtures.
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
mkdir -p "$repo_dir/logs/uci-defaults"
test_root="$(mktemp -d "$repo_dir/logs/uci-defaults/test.XXXXXX")"
UCI_MOCK_COMMANDS="$test_root/mock-commands.sh"
export UCI_MOCK_COMMANDS

cat > "$UCI_MOCK_COMMANDS" <<'MOCK'
uci() {
	[ "$1" != '-q' ] || shift
	action="$1"
	shift
	case "$action" in
		get)
			[ -f "$UCI_CASE/db/$1" ] || return 1
			cat "$UCI_CASE/db/$1"
			;;
		set|add_list|del_list)
			key="${1%%=*}"
			value="${1#*=}"
			[ "$key" != "${UCI_FAIL_SET:-}" ] || return 1
			printf '%s %s\n' "$action" "$key" >> "$UCI_CASE/writes"
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
			printf 'delete %s\n' "$1" >> "$UCI_CASE/writes"
			rm "$UCI_CASE/db/$1"
			;;
		commit) printf '%s\n' "$1" >> "$UCI_CASE/commits" ;;
		*) printf 'Unexpected UCI command: %s\n' "$action" >&2; return 1 ;;
	esac
}
logger() { printf '%s\n' "$*" >> "$UCI_CASE/messages"; }
MOCK

put() { printf '%s\n' "$2" > "$UCI_CASE/db/$1"; }
get() { cat "$UCI_CASE/db/$1"; }
assert_eq() {
	if [ "$1" != "$2" ]; then
		printf 'FAIL: %s (%s): expected [%s], got [%s]\n' "$3" "$UCI_CASE" "$2" "$1" >&2
		exit 1
	fi
}
assert_no_writes() {
	[ ! -s "$UCI_CASE/writes" ] && [ ! -s "$UCI_CASE/commits" ] || {
		printf 'FAIL: topology rejection changed UCI: %s\n' "$UCI_CASE" >&2
		exit 1
	}
}
new_case() {
	UCI_CASE="$test_root/$role-$1"
	UCI_FAIL_SET=''
	export UCI_CASE UCI_FAIL_SET
	mkdir -p "$UCI_CASE/db" "$UCI_CASE/sys"
	printf '%s\n' "${3:-zyxel,ex5601-t0-ubootmod}" > "$UCI_CASE/board_name"
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
	put 'wireless.@wifi-device[0].band' 2g
	put 'wireless.@wifi-device[1].band' 5g
	put 'wireless.@wifi-iface[0].mode' ap
}
run_defaults() {
	{
		printf '. "$UCI_MOCK_COMMANDS"\n'
		sed -e "s@/sys/class/net@$UCI_CASE/sys@g" \
			-e "s@/tmp/sysinfo/board_name@$UCI_CASE/board_name@g" \
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
		ap) assert_eq "$(get 'network.@device[0].ports')" "lan1 lan2 lan3 lan4 $1" 'AP includes physical WAN exactly once' ;;
		router) assert_eq "$(get 'network.@device[0].ports')" 'lan1 lan2 lan3 lan4' 'router removes WAN from bridge' ;;
	esac
	assert_eq "$(get network.wan.proto)" pppoe 'saved WAN protocol preserved'
	assert_eq "$(get network.wan.password)" fixture-secret 'saved WAN credentials preserved'
}

for role in ap router; do
	new_case legacy eth1
	mkdir "$UCI_CASE/sys/wan"
	put network.wan6.device eth1
	put 'network.@device[0].ports' 'lan1 lan2 lan3 lan4 eth1'
	put 'network.@device[1].name' eth1
	put 'network.@device[1].macaddr' 02:00:00:00:00:01
	run_defaults 0
	assert_eq "$(get network.wan.device)" wan 'legacy Zyxel WAN migrated'
	assert_eq "$(get network.wan6.device)" wan 'legacy WAN6 migrated'
	assert_eq "$(get 'network.@device[1].name')" wan 'legacy device section migrated'
	assert_eq "$(get 'network.@device[1].macaddr')" 02:00:00:00:00:01 'device options preserved'
	assert_role wan
	run_defaults 0
	assert_role wan

	new_case clean wan
	mkdir "$UCI_CASE/sys/wan"
	put 'network.@device[0].ports' 'lan1 lan2 lan3 lan4 wan'
	run_defaults 0
	assert_role wan
	assert_eq "$(get network.wan6.device)" @wan 'dynamic WAN6 reference preserved'

	new_case glinet eth0 glinet,gl-mt3000
	mkdir "$UCI_CASE/sys/eth0"
	put 'network.@device[0].ports' 'lan1 lan2 lan3 lan4 eth0'
	put 'network.@device[1].name' eth1
	run_defaults 0
	assert_role eth0
	assert_eq "$(get 'network.@device[1].name')" eth1 'GL-MT3000 device names preserved'

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
	assert_eq "$(get network.wan.device)" eth1 'existing eth1 must not be guessed away'
	assert_role eth1

	new_case vlan eth1.35
	mkdir "$UCI_CASE/sys/wan"
	run_defaults 1
	assert_no_writes
	grep -q 'manual migration' "$UCI_CASE/messages"

	new_case wan6-vlan eth1
	mkdir "$UCI_CASE/sys/wan"
	put network.wan6.device eth1.35
	run_defaults 1
	assert_no_writes

	new_case conflicting-devices eth1
	mkdir "$UCI_CASE/sys/wan"
	put 'network.@device[1].name' eth1
	put 'network.@device[2].name' wan
	run_defaults 1
	assert_no_writes

	new_case wan-is-bridge wan
	mkdir -p "$UCI_CASE/sys/wan/bridge"
	run_defaults 1
	assert_no_writes

	new_case failed-migration eth1
	mkdir "$UCI_CASE/sys/wan"
	UCI_FAIL_SET=network.wan.device
	export UCI_FAIL_SET
	run_defaults 1
	assert_no_writes
done

printf 'First-boot defaults tests passed for AP/router, Zyxel/GL-MT3000, migration, retries, and topology failures. Fixtures: %s\n' "$test_root"
