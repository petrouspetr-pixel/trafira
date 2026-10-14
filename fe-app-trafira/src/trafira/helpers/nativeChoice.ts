// Single-value choices using the same LuCI dropdown as native form options.
export function nativeChoice(
  id: string,
  label: string,
  initial = '',
  choices: Record<string, string> = {},
  custom = false,
  datatype?: string,
  required = false,
) {
  const widget = new ui.Dropdown(initial, choices, {
    id,
    multiple: false,
    optional: !required,
    sort: false,
    create: custom,
    select_placeholder: label,
    custom_placeholder: label,
    datatype,
  });
  const node = widget.render();
  node.setAttribute('aria-label', label);
  let updating = false;
  let disabled = false;
  const preventDisabledInput = (event: Event) => {
    if (
      !disabled ||
      (event instanceof KeyboardEvent && ['Tab', 'Escape'].includes(event.key))
    )
      return;
    event.preventDefault();
    event.stopImmediatePropagation();
  };
  node.addEventListener('click', preventDisabledInput, true);
  node.addEventListener('mousedown', preventDisabledInput, true);
  node.addEventListener('keydown', preventDisabledInput, true);
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
    setDisabled(value: boolean) {
      disabled = value;
      node.toggleAttribute('disabled', disabled);
      node.setAttribute('tabindex', disabled ? '-1' : '0');
      node.setAttribute('aria-disabled', String(disabled));
      for (const input of node.querySelectorAll<HTMLInputElement>('input'))
        input.disabled = disabled;
    },
  };
}
