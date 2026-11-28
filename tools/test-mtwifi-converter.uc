'use strict';

import { convert } from 'mtwifi.converter';
import { defs } from 'mtwifi.defaults';

function check(condition, message) {
    if (!condition)
        die("Converter regression: " + message + "\n");
}

function equal(actual, expected, message) {
    check(actual === expected, message + sprintf(" (expected %J, got %J)", expected, actual));
}

function radio(band, country, width, channel) {
    return convert({
        config: { band, country, htmode: width, channel },
        interfaces: {
            main: {
                mtwifi_ifname: band == "2g" ? "ra0" : "rax0",
                config: { mode: "ap", ssid: "converter-fixture", encryption: "psk2", key: "fixture-only" }
            }
        }
    });
}

function dfs(dat, region) {
    equal(dat.RDRegion, region, "radar domain");
    equal(dat.IEEE80211H, "1", "802.11h enabled");
    equal(dat.DfsEnable, "1", "DFS enabled");
    equal(dat.DfsDedicatedZeroWait, "2", "portable dedicated mode, including HE160");
    equal(dat.DfsZeroWait, "1", "zero-wait enabled");
    equal(dat.DfsZeroWaitCacTime, "255", "driver-default CAC");
    equal(dat.DfsZeroWaitDefault, "1", "default zero-wait enabled");
}

for (let country, regions in defs.COUNTRY_REGIONS) {
    check(length(country) == 2 && length(regions) == 3, "country entry structure");
    check(type(regions[0]) == "int" && type(regions[1]) == "int", "numeric region indices");
    check(index(["CE", "FCC", "JAP"], regions[2]) >= 0, "known radar domain");
}
equal(join(",", defs.COUNTRY_REGIONS.SE), "1,1,CE", "SE schema mapping");

let se2 = radio("2g", "SE", "HE40", "auto");
equal(se2.CountryRegion, 1, "2.4 GHz region");
equal(se2.AutoChannelSelect, "3", "automatic channel selection");
equal(se2.Channel, "0", "automatic channel placeholder");
equal(se2.HT_BW, "1", "HE40 width");
equal(se2.HT_BSSCoexistence, "1", "2.4 GHz coexistence");
check(se2.RDRegion == null && se2.DfsEnable == null, "2.4 GHz must not emit DFS fields");
equal(se2.SSID1, "converter-fixture", "AP config retained");

let se5 = radio("5g", "SE", "HE80", "auto");
dfs(se5, "CE");
equal(se5.CountryRegionABand, 1, "SE 5 GHz region");
equal(se5.VHT_BW, "1", "HE80 width");

let us = radio("5g", "US", "VHT80", "36");
dfs(us, "FCC");
equal(us.CountryRegionABand, 0, "US 5 GHz region");
equal(us.Channel, "36", "fixed channel retained");
equal(us.AutoChannelSelect, "0", "fixed channel selection");

let jp = radio("5g", "JP", "HE160", "auto");
dfs(jp, "JAP");
equal(jp.CountryRegionABand, 9, "JP 5 GHz region");
equal(jp.VHT_BW, "2", "HE160 width");

for (let country in [null, "", "S", "SWE"]) {
    let dat = radio("5g", country, "HE80", "auto");
    check(dat.CountryCode == null && dat.RDRegion == null && dat.DfsEnable == null,
        "missing/invalid-length country must not emit regulatory overrides");
}
let fallback = radio("5g", "ZZ", "HE80", "auto");
dfs(fallback, "FCC");
equal(fallback.CountryRegionABand, 13, "existing unknown-country fallback");

// Changing country replaces every emitted DFS/domain field during DAT merging.
for (let key, value in us)
    se5[key] = value;
dfs(se5, "FCC");
equal(se5.CountryCode, "US", "country transition");

// Exercise the converter's explicit clearing branch using a test-only schema
// entry; no actual country mapping or installed firmware is changed.
defs.COUNTRY_REGIONS.QX = [1, 1, ""];
let clear = radio("5g", "QX", "HE80", "auto");
for (let key, value in clear)
    se5[key] = value;
equal(se5.RDRegion, "", "old radar domain cleared");
for (let key in ["IEEE80211H", "DfsEnable", "DfsDedicatedZeroWait", "DfsZeroWait", "DfsZeroWaitDefault"])
    equal(se5[key], "0", "old DFS override cleared: " + key);

print("Patched converter tests passed for 2.4/5 GHz, CE/FCC/JAP, channel widths and transitions.\n");
