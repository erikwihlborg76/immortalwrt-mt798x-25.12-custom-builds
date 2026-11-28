# Troubleshooting

[Documentation index](README.md)

## Defaults failed or remain pending

Missing topology or required Wi-Fi sections stop both scripts before UCI changes. Later write or commit failures can still leave defaults partially applied: network, DHCP, system, and wireless are separate UCI packages, and the scripts commit them in that order. A later failure can leave the LAN / management address changed to the selected variant's address. Reconnect using the [management addresses](../README.md#installation); if direct Ethernet access to an AP is needed without an upstream DHCP server, assign your computer an unused address in the same `/24` subnet.

After connecting over SSH or a local console, inspect the diagnostic messages, saved LAN address, active IPv4 addresses, and pending script:

```sh
logread -e 99-custom
uci -q get network.lan.ipaddr
uci -q get network.wan.device
ubus call network.device status '{"name":"br-lan"}'
ip -4 addr show
if [ -f /etc/uci-defaults/99-custom ]; then echo 'Custom defaults pending'; else echo 'No pending custom defaults'; fi
```

The scripts log topology and missing-Wi-Fi errors with the `99-custom` tag; individual failed UCI commands may also report errors outside that tag. OpenWrt retains a failed defaults script for retry on the next boot. Correct the reported topology or Wi-Fi configuration before rebooting; the retry reapplies the defaults, including the Wi-Fi security reset.
