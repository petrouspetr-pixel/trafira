"use strict";
"require baseclass";
"require form";
"require view.trafira.main as main";

function createProfilesContent(section) {
  const option = section.option(form.DummyValue, "_profiles");
  option.render = function (sectionId) {
    main.ConfigurationPanels.init("profiles", !this.map.readonly);
    return E(
      "div",
      { id: this.cbid(sectionId), class: "trafira-feature-slot" },
      [E("div", { id: "trafira-profiles" })],
    );
  };
}

return baseclass.extend({ createProfilesContent });
