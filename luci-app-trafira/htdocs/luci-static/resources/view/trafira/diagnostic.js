"use strict";
"require baseclass";
"require form";
"require ui";
"require uci";
"require fs";
"require view.trafira.main as main";

function createDiagnosticContent(section) {
  const o = section.option(form.DummyValue, "_mount_node");
  o.render = function (sectionId) {
    main.DiagnosticTab.initController();
    return E(
      "div",
      { id: this.cbid(sectionId), class: "trafira-feature-slot" },
      [main.DiagnosticTab.render()],
    );
  };
}

const EntryPoint = {
  createDiagnosticContent,
};

return baseclass.extend(EntryPoint);
