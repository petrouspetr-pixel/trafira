"use strict";
"require baseclass";
"require form";
"require view.trafira.main as main";

function createRoutingContent(section) {
  const option = section.option(form.DummyValue, "_route_explanation");
  option.render = function (sectionId) {
    main.ConfigurationPanels.init("routing", !this.map.readonly);
    return E(
      "div",
      { id: this.cbid(sectionId), class: "trafira-feature-slot" },
      [E("div", { id: "trafira-route-explanation" })],
    );
  };
}
return baseclass.extend({ createRoutingContent });
