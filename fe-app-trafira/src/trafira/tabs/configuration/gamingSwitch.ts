// Return draft UCI edits only. The native LuCI Save/Apply flow owns persistence.
export function gamingSwitchChanges(
  sections: Record<string, unknown>[],
  enabled: boolean,
) {
  const edits: Array<{ section: string; option: string; value?: string }> = [];
  for (const section of sections) {
    if (!section.preset_owner || typeof section['.name'] !== 'string') continue;
    const clean: Record<string, unknown> = {};
    for (const key of Object.keys(section).sort()) {
      if (key.startsWith('.') || key.startsWith('preset_')) continue;
      const value = section[key];
      if (Array.isArray(value) && !value.length) continue;
      const scalar = (v: unknown) =>
        v === true ? '1' : v === false ? '0' : String(v);
      clean[key] = Array.isArray(value) ? value.map(scalar) : scalar(value);
    }
    const name = section['.name'];
    const prior =
      section.enabled === undefined ||
      ['1', 'true', 'yes', 'on', 1, true].includes(
        section.enabled as string | number | boolean,
      )
        ? '1'
        : '0';
    const resume = section.preset_resume_enabled;
    const next = enabled
      ? resume === undefined
        ? prior
        : resume === '1'
          ? '1'
          : '0'
      : '0';
    if (enabled) {
      if (resume !== undefined)
        edits.push({ section: name, option: 'preset_resume_enabled' });
    } else if (resume === undefined)
      edits.push({
        section: name,
        option: 'preset_resume_enabled',
        value: prior,
      });
    edits.push({ section: name, option: 'enabled', value: next });
    // Keep the backend's canonical spelling, including whitespace. Do not hide manual edits.
    const original = section.preset_original_digest;
    if (typeof original === 'string')
      try {
        if (JSON.stringify(JSON.parse(original)) === JSON.stringify(clean))
          edits.push({
            section: name,
            option: 'preset_original_digest',
            value: original.replace(
              /("enabled"\s*:\s*")[^"]*(")/,
              (_match, prefix: string, suffix: string) =>
                prefix + next + suffix,
            ),
          });
      } catch {
        /* An invalid fingerprint remains edited. */
      }
  }
  return edits;
}
