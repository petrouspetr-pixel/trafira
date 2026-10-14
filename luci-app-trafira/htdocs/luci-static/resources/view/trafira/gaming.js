"use strict";
"require baseclass";
"require form";
"require uci";
"require view.trafira.main as main";

function createGamingContent(section) {
  const enabled = section.option(
    form.Flag,
    "gaming_presets_enabled",
    _("Enable gaming presets"),
    _(
      "Show gaming preset management. Changes to routing take effect after Apply. Saved presets are kept when disabled.",
    ),
  );
  enabled.default = "1";
  enabled.rmempty = false;
  enabled.write = function (sectionId, value) {
    const packageName = main.TRAFIRA_UCI_PACKAGE;
    for (const edit of main.ConfigurationPanels.gamingSwitchChanges(
      uci.sections(packageName, "section"),
      value === "1",
    )) {
      if (edit.value === undefined)
        uci.unset(packageName, edit.section, edit.option);
      else uci.set(packageName, edit.section, edit.option, edit.value);
    }
    uci.set(packageName, sectionId, this.option, value);
  };
  const option = section.option(form.DummyValue, "_gaming_presets");
  option.depends("gaming_presets_enabled", "1");
  option.retain = true;
  option.render = function (sectionId, optionIndex) {
    main.ConfigurationPanels.init("gaming", !this.map.readonly);
    return this.renderFrame(
      sectionId,
      false,
      optionIndex,
      E("div", { id: this.cbid(sectionId), class: "trafira-feature-slot" }, [
        E("div", { id: "trafira-gaming-presets" }),
      ]),
    );
  };
}

return baseclass.extend({ createGamingContent });
