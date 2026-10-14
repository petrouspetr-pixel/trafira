"use strict";
"require baseclass";
"require form";
"require view.trafira.main as main";

function createGamingContent(section) {
  const option = section.option(form.DummyValue, "_gaming_presets");
  option.render = function (sectionId) {
    main.ConfigurationPanels.init("gaming", !this.map.readonly);
    return E(
      "div",
      { id: this.cbid(sectionId), class: "trafira-feature-slot" },
      [E("div", { id: "trafira-gaming-presets" })],
    );
  };
}

return baseclass.extend({ createGamingContent });
