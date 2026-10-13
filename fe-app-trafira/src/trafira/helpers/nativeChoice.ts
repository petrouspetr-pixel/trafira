// Single-value choices using the same LuCI dropdown as native form options.
export function nativeChoice(
  id: string,
  label: string,
  initial = '',
  choices: Record<string, string> = {},
  custom = false,
  datatype?: string,
) {
  const widget = new ui.Dropdown(initial, choices, {
    id,
    multiple: false,
    optional: true,
    sort: false,
    create: custom,
    select_placeholder: label,
    custom_placeholder: label,
    datatype,
  });
  const node = widget.render();
  node.setAttribute('aria-label', label);
  let updating = false;
  const listeners: Array<() => void> = [];
  node.addEventListener('cbi-dropdown-change', () => {
    if (!updating) for (const listener of listeners) listener();
  });
  function set(value: string) {
    updating = true;
    try {
      if (value)
        widget.addChoices([value], { [value]: choices[value] || value });
      widget.setValue(value);
    } finally {
      updating = false;
    }
  }
  return {
    node,
    get value() {
      return widget.getValue() || '';
    },
    set value(value: string) {
      set(value);
    },
    onChange(listener: () => void) {
      listeners.push(listener);
    },
    setChoices(next: Record<string, string>) {
      const value = widget.getValue() || '';
      updating = true;
      try {
        choices = next;
        widget.clearChoices(true);
        widget.addChoices(Object.keys(next), next);
        if (value && !next[value])
          widget.addChoices([value], { [value]: value });
        widget.setValue(value);
      } finally {
        updating = false;
      }
    },
    setDisabled(disabled: boolean) {
      node.toggleAttribute('disabled', disabled);
      node.setAttribute('aria-disabled', String(disabled));
      for (const input of node.querySelectorAll<HTMLInputElement>('input'))
        input.disabled = disabled;
    },
  };
}
