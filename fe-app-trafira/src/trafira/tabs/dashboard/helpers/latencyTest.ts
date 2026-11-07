import { Trafira } from '../../../types';
export function getSectionLatencyTarget(section: Trafira.OutboundGroup): {
  type: Trafira.LatencyActionState['latency_type'];
  tag: string;
  timeout?: string;
} | null {
  const available = section.outbounds.filter(
    (item) => item.runtimeAvailable !== false && item.code,
  );
  if (!available.length) return null;
  if (section.withTagSelect) {
    const tags = section.latencyTestCodes?.filter(
      (tag) =>
        !section.outbounds.some(
          (item) => item.code === tag && item.runtimeAvailable === false,
        ),
    );
    return tags?.length
      ? { type: 'proxy_list', tag: JSON.stringify(tags) }
      : { type: 'group', tag: section.latencyTestCode || section.code };
  }
  return {
    type: 'proxy',
    tag: available[0].code,
    timeout: section.latencyTestTimeout,
  };
}
export async function testAllSectionsLatency(
  sections: Trafira.OutboundGroup[],
  test: (section: Trafira.OutboundGroup) => Promise<void>,
  isActive: () => boolean,
) {
  for (const section of sections) {
    if (!isActive()) break;
    if (!getSectionLatencyTarget(section)) continue;
    try {
      await test(section);
    } catch {
      /* Continue with the next independent connection. */
    }
  }
}
