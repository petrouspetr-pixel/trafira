"use strict";
"require baseclass";
"require form";
"require uci";
"require view.trafira.main as main";
"require view.trafira.local_devices as localDevices";

const MAC_PATTERN = /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/;
const INTERFACE_PATTERN = /^[A-Za-z0-9_.@-]+\*?$/;

function interfaceMatches(pattern, name) {
  return pattern.endsWith("*")
    ? name.startsWith(pattern.slice(0, -1))
    : pattern === name;
}

function sourceNetworkInterfaces(map) {
  const lookup = map.lookupOption("source_network_interfaces", "settings");
  const option = lookup && lookup[0];
  const value = option
    ? option.formvalue("settings")
    : uci.get(
        main.TRAFIRA_UCI_PACKAGE,
        "settings",
        "source_network_interfaces",
      );
  const interfaces = localDevices.normalizeOptionValues(value);
  return interfaces.length ? interfaces : ["br-lan"];
}

function createAliceContent(section) {
  let option = section.option(
    form.Flag,
    "alice_mode_enabled",
    _("Enable Alice Mode"),
    _(
      "Choose whether devices in the list use Trafira or bypass it. Bypassed devices connect directly and receive real IP addresses from DNS.",
    ),
  );
  option.default = "0";
  option.rmempty = false;

  option = section.option(
    form.Flag,
    "alice_dashboard_enabled",
    _("Show on dashboard"),
    _("Show each device's routing status on the dashboard."),
  );
  option.default = "1";
  option.rmempty = false;
  option.depends("alice_mode_enabled", "1");

  option = section.option(
    form.ListValue,
    "alice_list_mode",
    _("Devices in the list"),
    _(
      "Other devices do the opposite. Match devices by interface, MAC address or IP address.",
    ),
  );
  option.value("allow", _("Use Trafira"));
  option.value("deny", _("Bypass Trafira"));
  option.default = "allow";
  option.rmempty = false;
  option.depends("alice_mode_enabled", "1");

  option = section.option(
    form.DynamicList,
    "alice_interfaces",
    _("Interfaces"),
    _(
      "Add an interface to match all its clients, such as every peer on a WireGuard server. It must also be selected in Source Network Interface.",
    ),
  );
  option.placeholder = _("Interface or mask, e.g. wg*");
  option.depends("alice_mode_enabled", "1");
  option.retain = true;
  option.validate = function (_sectionId, value) {
    if (!value) return true;
    if (!INTERFACE_PATTERN.test(value)) {
      return _("Invalid interface name");
    }
    const captured = sourceNetworkInterfaces(this.map).some(
      (source) =>
        interfaceMatches(value, source) || interfaceMatches(source, value),
    );
    return captured
      ? true
      : _("Add %s to Source Network Interface first").format(value);
  };
  option.renderWidget = function (sectionId, optionIndex, cfgvalue) {
    return localDevices.createInterfaceDynamicListWidget(
      this,
      sectionId,
      cfgvalue,
    );
  };

  option = section.option(
    form.DynamicList,
    "alice_ips",
    _("IP addresses and subnets"),
    _(
      "Add IPv4 and IPv6 addresses or subnets as separate entries. For LAN or Wi-Fi devices, use a MAC address if the IP may change. IP addresses can be spoofed.",
    ),
  );
  option.placeholder = _("Device, subnet or IP");
  option.depends("alice_mode_enabled", "1");
  option.retain = true;
  option.validate = function (_sectionId, value) {
    if (!value) return true;
    const result = main.validateSubnet(value);
    return result.valid ? true : result.message;
  };
  option.renderWidget = function (sectionId, optionIndex, cfgvalue) {
    return localDevices.createLocalDeviceDynamicListWidget(
      this,
      sectionId,
      cfgvalue,
      { includeSubnets: true },
    );
  };

  option = section.option(
    form.DynamicList,
    "alice_macs",
    _("MAC addresses"),
    _(
      "Use a MAC address for a LAN or Wi-Fi device to keep matching it when its IP changes. MAC addresses do not apply to WireGuard peers.",
    ),
  );
  option.placeholder = _("Device or MAC");
  option.depends("alice_mode_enabled", "1");
  option.retain = true;
  option.validate = function (_sectionId, value) {
    if (!value) return true;
    return MAC_PATTERN.test(value)
      ? true
      : _("Invalid MAC address. Use the aa:bb:cc:dd:ee:ff format");
  };
  option.renderWidget = function (sectionId, optionIndex, cfgvalue) {
    return localDevices.createLocalMacDynamicListWidget(
      this,
      sectionId,
      cfgvalue,
    );
  };
  option = section.option(form.DummyValue, "_gaming_presets");
  option.render = function (sectionId) {
    main.ConfigurationPanels.init("gaming", !this.map.readonly);
    return E(
      "div",
      { id: this.cbid(sectionId), class: "trafira-feature-slot" },
      [E("div", { id: "trafira-gaming-presets" })],
    );
  };
}

return baseclass.extend({ createAliceContent });
