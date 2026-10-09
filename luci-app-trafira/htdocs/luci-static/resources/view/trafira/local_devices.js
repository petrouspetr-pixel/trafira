"use strict";
"require baseclass";
"require rpc";
"require ui";
"require view.trafira.main as main";

const callHostHints = rpc.declare({
  object: "luci-rpc",
  method: "getHostHints",
  expect: { "": {} },
});
const callDHCPLeases = rpc.declare({
  object: "luci-rpc",
  method: "getDHCPLeases",
  expect: { "": {} },
});
const callNetworkInterfaceDump = rpc.declare({
  object: "network.interface",
  method: "dump",
  expect: { interface: [] },
});

let localDeviceChoicesCache = null;
let localSubnetChoicesCache = null;
let localMacChoicesCache = null;
let localInterfaceChoicesCache = null;
let localDeviceChoicesPromise = null;

function normalizeOptionValues(value) {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value
      .filter(Boolean)
      .map((item) => `${item}`.trim())
      .filter(Boolean);
  }

  return `${value}`
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function normalizeLocalDeviceName(name) {
  return `${name || ""}`.trim().replace(/\.lan$/i, "");
}

function addLocalDeviceChoice(choices, ip, name) {
  const normalizedIp = `${ip || ""}`.trim();
  const normalizedName = normalizeLocalDeviceName(name);

  if (!normalizedIp || !normalizedName) {
    return;
  }

  if (!main.validateIP(normalizedIp).valid) {
    return;
  }

  choices[normalizedIp] = `${normalizedIp} · ${normalizedName}`;
}

function addRouterIp(routerIps, ip) {
  const normalizedIp = `${ip || ""}`.trim();

  if (!normalizedIp || !main.validateIP(normalizedIp).valid) {
    return;
  }

  routerIps[normalizedIp] = true;
}

function buildRouterIpMap(networkInterfaces) {
  const routerIps = {};

  if (!Array.isArray(networkInterfaces)) {
    return routerIps;
  }

  networkInterfaces.forEach((networkInterface) => {
    const ipAddresses = [];
    const ipv4Addresses =
      networkInterface &&
      typeof networkInterface === "object" &&
      Array.isArray(networkInterface["ipv4-address"])
        ? networkInterface["ipv4-address"]
        : [];
    const ipv6Addresses =
      networkInterface &&
      typeof networkInterface === "object" &&
      Array.isArray(networkInterface["ipv6-address"])
        ? networkInterface["ipv6-address"]
        : [];

    ipAddresses.push(...ipv4Addresses, ...ipv6Addresses);
    ipAddresses.forEach((address) => {
      addRouterIp(
        routerIps,
        address && typeof address === "object" ? address.address : address,
      );
    });
  });

  return routerIps;
}

function buildLocalDeviceChoices(hostHints, dhcpLeases, networkInterfaces) {
  const choices = {};
  const routerIps = buildRouterIpMap(networkInterfaces);

  if (hostHints && typeof hostHints === "object") {
    Object.values(hostHints).forEach((hint) => {
      if (!hint || typeof hint !== "object") {
        return;
      }

      [
        ...normalizeOptionValues(hint.ipaddrs),
        ...normalizeOptionValues(hint.ipv4),
        ...normalizeOptionValues(hint.ipv6),
      ].forEach((ip) => {
        addLocalDeviceChoice(choices, ip, hint.name);
      });
    });
  }

  if (dhcpLeases && Array.isArray(dhcpLeases.dhcp_leases)) {
    dhcpLeases.dhcp_leases.forEach((lease) => {
      if (!lease || typeof lease !== "object") {
        return;
      }

      addLocalDeviceChoice(choices, lease.ipaddr, lease.hostname);
    });
  }

  Object.keys(routerIps).forEach((ip) => {
    delete choices[ip];
  });

  return choices;
}

function ipv4NetworkCidr(address, mask) {
  const octets = `${address}`.split(".").map((part) => parseInt(part, 10));
  const value =
    ((octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]) >>>
    0;
  const maskValue = mask === 0 ? 0 : (0xffffffff << (32 - mask)) >>> 0;
  const network = (value & maskValue) >>> 0;

  return `${[24, 16, 8, 0].map((shift) => (network >>> shift) & 255).join(".")}/${mask}`;
}

function hasDefaultRoute(networkInterface) {
  return (
    Array.isArray(networkInterface.route) &&
    networkInterface.route.some(
      (route) =>
        route &&
        (route.target === "0.0.0.0" || route.target === "::") &&
        Number(route.mask) === 0,
    )
  );
}

function buildInterfaceSubnetChoices(networkInterfaces) {
  const choices = {};

  if (!Array.isArray(networkInterfaces)) {
    return choices;
  }

  networkInterfaces.forEach((networkInterface) => {
    if (
      !networkInterface ||
      typeof networkInterface !== "object" ||
      networkInterface.interface === "loopback" ||
      hasDefaultRoute(networkInterface)
    ) {
      return;
    }

    const subnetLabel = _("%s subnet").format(networkInterface.interface);
    const ipv4Addresses = Array.isArray(networkInterface["ipv4-address"])
      ? networkInterface["ipv4-address"]
      : [];
    const ipv6Prefixes = Array.isArray(
      networkInterface["ipv6-prefix-assignment"],
    )
      ? networkInterface["ipv6-prefix-assignment"]
      : [];

    ipv4Addresses.forEach((entry) => {
      const mask = Number(entry && entry.mask);
      if (
        entry &&
        main.validateIP(`${entry.address}`).valid &&
        mask > 0 &&
        mask < 32
      ) {
        const cidr = ipv4NetworkCidr(entry.address, mask);
        choices[cidr] = `${cidr} · ${subnetLabel}`;
      }
    });

    ipv6Prefixes.forEach((entry) => {
      const mask = Number(entry && entry.mask);
      const cidr = `${entry && entry.address}/${mask}`;
      if (mask > 0 && mask < 128 && main.validateSubnet(cidr).valid) {
        choices[cidr] = `${cidr} · ${subnetLabel}`;
      }
    });
  });

  return choices;
}

// Client-facing router interfaces by device name; uplinks and loopback are skipped.
function buildInterfaceChoices(networkInterfaces) {
  const choices = {};

  if (!Array.isArray(networkInterfaces)) {
    return choices;
  }

  networkInterfaces.forEach((networkInterface) => {
    const device =
      networkInterface &&
      (networkInterface.l3_device || networkInterface.device);

    if (
      !device ||
      networkInterface.interface === "loopback" ||
      hasDefaultRoute(networkInterface)
    ) {
      return;
    }

    choices[device] =
      device === networkInterface.interface
        ? device
        : `${device} (${networkInterface.interface})`;
  });

  return choices;
}

function macChoiceLabel(mac, name, ip) {
  const details = [name, ip].filter(Boolean).join(" · ");
  return details ? `${mac} (${details})` : mac;
}

function buildLocalMacChoices(hostHints, dhcpLeases) {
  const choices = {};

  if (hostHints && typeof hostHints === "object") {
    Object.keys(hostHints).forEach((mac) => {
      const hint = hostHints[mac];
      if (!/^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/.test(mac) || !hint) {
        return;
      }

      const name = normalizeLocalDeviceName(hint.name);
      const ip = normalizeOptionValues(hint.ipaddrs || hint.ipv4)[0] || "";
      choices[mac.toLowerCase()] = macChoiceLabel(mac.toLowerCase(), name, ip);
    });
  }

  if (dhcpLeases && Array.isArray(dhcpLeases.dhcp_leases)) {
    dhcpLeases.dhcp_leases.forEach((lease) => {
      const mac = `${(lease && lease.macaddr) || ""}`.toLowerCase();
      const name = normalizeLocalDeviceName(lease && lease.hostname);
      if (mac && !choices[mac]) {
        choices[mac] = macChoiceLabel(mac, name, lease.ipaddr);
      }
    });
  }

  return choices;
}

function loadLocalDeviceChoices() {
  if (localDeviceChoicesCache) {
    return Promise.resolve(localDeviceChoicesCache);
  }

  if (localDeviceChoicesPromise) {
    return localDeviceChoicesPromise;
  }

  localDeviceChoicesPromise = Promise.all([
    callHostHints().catch(() => ({})),
    callDHCPLeases().catch(() => ({})),
    callNetworkInterfaceDump().catch(() => []),
  ])
    .then(([hostHints, dhcpLeases, networkInterfaces]) => {
      localDeviceChoicesCache = buildLocalDeviceChoices(
        hostHints,
        dhcpLeases,
        networkInterfaces,
      );
      localSubnetChoicesCache = buildInterfaceSubnetChoices(networkInterfaces);
      localMacChoicesCache = buildLocalMacChoices(hostHints, dhcpLeases);
      localInterfaceChoicesCache = buildInterfaceChoices(networkInterfaces);
      return localDeviceChoicesCache;
    })
    .finally(() => {
      localDeviceChoicesPromise = null;
    });

  return localDeviceChoicesPromise;
}

function sortLocalDeviceChoiceValues(choices) {
  return Object.keys(choices).sort((a, b) => {
    const byName = `${choices[a]}`.localeCompare(`${choices[b]}`);
    return byName || a.localeCompare(b);
  });
}

function hasSingleIpValue(values) {
  return normalizeOptionValues(values).some(
    (value) => main.validateIP(value).valid,
  );
}

function preloadLocalDeviceChoicesForValues(values) {
  return hasSingleIpValue(values)
    ? loadLocalDeviceChoices()
    : Promise.resolve(null);
}

// Choice kinds: "devices" (host IPs), "devicesAndSubnets" (host IPs plus
// router interface subnets), "macs" and "interfaces".
function cachedChoices(kind) {
  if (!localDeviceChoicesCache) {
    return null;
  }

  if (kind === "macs") {
    return localMacChoicesCache || {};
  }

  if (kind === "interfaces") {
    return localInterfaceChoicesCache || {};
  }

  if (kind === "devicesAndSubnets") {
    return { ...(localSubnetChoicesCache || {}), ...localDeviceChoicesCache };
  }

  return localDeviceChoicesCache;
}

function loadChoicesOfKind(kind) {
  return loadLocalDeviceChoices().then(() => cachedChoices(kind) || {});
}

function createChoiceDynamicListWidget(option, section_id, cfgvalue, kind) {
  const values = normalizeOptionValues(
    cfgvalue != null ? cfgvalue : option.default,
  );
  const shouldResolveExistingLabels =
    kind === "devices" ? hasSingleIpValue(values) : values.length > 0;

  return (
    shouldResolveExistingLabels ? loadChoicesOfKind(kind) : Promise.resolve({})
  ).then((initialChoices) => {
    const choices = cachedChoices(kind) || initialChoices || {};
    const widget = new ui.DynamicList(values, choices, {
      id: option.cbid(section_id),
      sort: sortLocalDeviceChoiceValues(choices),
      optional: option.optional || option.rmempty,
      datatype: option.datatype,
      placeholder: option.placeholder,
      validate: option.validate.bind(option, section_id),
      disabled: option.readonly != null ? option.readonly : option.map.readonly,
    });
    const node = widget.render();
    if (typeof option.onDeviceWidgetReady === "function") {
      option.onDeviceWidgetReady(section_id, widget);
    }
    if (typeof option.onDeviceListChange === "function") {
      node.addEventListener("cbi-dynlist-change", () => {
        option.onDeviceListChange(section_id, widget.getValue());
      });
    }
    let choicesLoaded = Boolean(cachedChoices(kind));
    let choicesLoading = false;

    const loadChoices = () => {
      if (choicesLoaded || choicesLoading) {
        return;
      }

      choicesLoading = true;
      loadChoicesOfKind(kind)
        .then((loadedChoices) => {
          widget.clearChoices();
          widget.addChoices(
            sortLocalDeviceChoiceValues(loadedChoices),
            loadedChoices,
          );
          choicesLoaded = true;
        })
        .finally(() => {
          choicesLoading = false;
        });
    };

    const maybeLoadChoices = (ev) => {
      if (
        ev.target &&
        typeof ev.target.closest === "function" &&
        ev.target.closest(".cbi-dropdown")
      ) {
        loadChoices();
      }
    };

    node.addEventListener("mousedown", maybeLoadChoices, true);
    node.addEventListener("focusin", maybeLoadChoices, true);

    return node;
  });
}

function createLocalDeviceDynamicListWidget(
  option,
  section_id,
  cfgvalue,
  options = {},
) {
  return createChoiceDynamicListWidget(
    option,
    section_id,
    cfgvalue,
    options.includeSubnets ? "devicesAndSubnets" : "devices",
  );
}

function createLocalMacDynamicListWidget(option, section_id, cfgvalue) {
  return createChoiceDynamicListWidget(option, section_id, cfgvalue, "macs");
}

function createInterfaceDynamicListWidget(option, section_id, cfgvalue) {
  return createChoiceDynamicListWidget(
    option,
    section_id,
    cfgvalue,
    "interfaces",
  );
}

const EntryPoint = {
  buildInterfaceChoices,
  buildInterfaceSubnetChoices,
  buildLocalMacChoices,
  createInterfaceDynamicListWidget,
  createLocalDeviceDynamicListWidget,
  createLocalMacDynamicListWidget,
  hasSingleIpValue,
  loadLocalDeviceChoices,
  normalizeOptionValues,
  preloadLocalDeviceChoicesForValues,
};

return baseclass.extend(EntryPoint);
