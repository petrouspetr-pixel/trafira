import { watchPanel } from '../../helpers/panelLifecycle';
import { snapshots } from '../diagnostic/renderSnapshots';
import { profilesPanel } from '../diagnostic/renderProfiles';
import { gamingPresetsPanel } from '../diagnostic/renderGamingPresets';

const panels = {
  lists: { id: 'fkp_diagnostic-page-snapshots', controller: snapshots },
  profiles: { id: 'trafira-profiles', controller: profilesPanel },
  gaming: { id: 'trafira-gaming-presets', controller: gamingPresetsPanel },
};
const watchers = new Map<keyof typeof panels, () => void>();

export const ConfigurationPanels = {
  init(kind: keyof typeof panels, canWrite = true) {
    watchers.get(kind)?.();
    const panel = panels[kind];
    watchers.set(kind, watchPanel(panel.id, panel.controller, canWrite));
  },
};
