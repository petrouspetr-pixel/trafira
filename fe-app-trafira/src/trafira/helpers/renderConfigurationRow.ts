// Keep custom configuration tools aligned with LuCI's native form options.
export function renderConfigurationRow(
  label: string,
  id: string,
  children: Node[],
) {
  const title = E('label', { class: 'cbi-value-title' }, label);
  if (id) (title as HTMLLabelElement).htmlFor = id;
  return E('div', { class: 'cbi-value' }, [
    title,
    E('div', { class: 'cbi-value-field' }, [
      E('div', { class: 'trafira-form-controls' }, children),
    ]),
  ]);
}
