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
  const map = section.map;
  const packageName = main.TRAFIRA_UCI_PACKAGE;
  main.ConfigurationPanels.bindGamingDraft({
    read: function () {
      const sections = uci
        .sections(packageName)
        .map((entry) => Object.assign({}, entry));
      const settings = sections.find((entry) => entry[".type"] === "settings");
      const value = enabled.formvalue("settings");
      if (settings && value != null) settings.gaming_presets_enabled = value;
      return sections;
    },
    write: function (before, after) {
      const changes = main.ConfigurationPanels.gamingUciChanges(before, after);
      changes.removed.forEach((name) => uci.remove(packageName, name));
      changes.added.forEach((entry) => {
        const name = uci.add(packageName, entry[".type"], entry[".name"]);
        Object.keys(entry)
          .filter((key) => key.charAt(0) !== ".")
          .forEach((key) => uci.set(packageName, name, key, entry[key]));
      });
      changes.edits.forEach((edit) => {
        if (edit.value === undefined)
          uci.unset(packageName, edit.section, edit.option);
        else uci.set(packageName, edit.section, edit.option, edit.value);
      });
      const prior = uci.sections(packageName).map((entry) => entry[".name"]);
      if (JSON.stringify(prior) !== JSON.stringify(changes.order))
        changes.order.forEach((name) => uci.move(packageName, name, null));
    },
  });
  const save = map.save;
  map.save = function (callback, silent) {
    return main.ConfigurationPanels.saveGamingDraft(() =>
      save.call(
        this,
        async function () {
          if (callback) await callback();
          await main.ConfigurationPanels.flushGamingDraft();
        },
        silent,
      ),
    );
  };
  const reset = map.reset;
  map.reset = function () {
    main.ConfigurationPanels.resetGamingDraft();
    return reset.apply(this, arguments);
  };
  const option = section.option(form.DummyValue, "_gaming_presets");
  option.depends("gaming_presets_enabled", "1");
  option.retain = true;
  option.render = function (optionIndex, sectionId) {
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
