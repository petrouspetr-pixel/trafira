interface Panel {
  mount(canWrite?: boolean): void | Promise<void>;
  unmount(): void;
}

// Native CBI replaces options when saved and hides tabs without removing them.
// Observe both cases so only the visible instance owns listeners and RPC polls.
export function watchPanel(id: string, panel: Panel, canWrite = true) {
  let mounted: HTMLElement | null = null;
  const refresh = () => {
    const node = document.getElementById(id);
    const visible =
      node?.isConnected && node.offsetParent !== null ? node : null;
    if (mounted === visible) return;
    if (mounted) panel.unmount();
    mounted = visible;
    if (mounted) void panel.mount(canWrite);
  };
  const observer = new MutationObserver(refresh);
  observer.observe(document.body, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['class', 'style', 'hidden', 'data-tab-active'],
  });
  refresh();
  return () => {
    observer.disconnect();
    if (mounted) panel.unmount();
    mounted = null;
  };
}
