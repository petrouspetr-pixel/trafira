interface IRenderWidgetProps {
  loading: boolean;
  failed: boolean;
  title: string;
  items: Array<{
    key: string;
    value: string;
    attributes?: {
      class?: string;
    };
  }>;
}

function renderFailedState() {
  return E(
    'div',
    {
      id: '',
      style: 'height: 78px',
      class: 'fkp_dashboard-page__widgets-section__item centered',
    },
    _('Currently unavailable'),
  );
}

function renderLoadingState() {
  return E(
    'div',
    {
      id: '',
      style: 'height: 78px',
      class: 'fkp_dashboard-page__widgets-section__item skeleton',
    },
    '',
  );
}

function renderDefaultState({ title, items, loading }: IRenderWidgetProps) {
  return E(
    'div',
    {
      class: 'fkp_dashboard-page__widgets-section__item',
      'aria-busy': loading ? 'true' : 'false',
    },
    [
      E(
        'b',
        { class: 'fkp_dashboard-page__widgets-section__item__title' },
        title,
      ),
      ...items.map((item) =>
        E(
          'div',
          {
            class: `fkp_dashboard-page__widgets-section__item__row ${item?.attributes?.class || ''}`,
          },
          [
            E(
              'span',
              { class: 'fkp_dashboard-page__widgets-section__item__row__key' },
              `${item.key}: `,
            ),
            E(
              'span',
              {
                class: 'fkp_dashboard-page__widgets-section__item__row__value',
              },
              item.value,
            ),
          ],
        ),
      ),
    ],
  );
}

export function renderWidget(props: IRenderWidgetProps) {
  // Keep labelled cards in place while sockets connect; no invented zeroes
  // and no stale measurements when the connection is unavailable.
  if (props.title && props.items.length && (props.loading || props.failed)) {
    return renderDefaultState({
      ...props,
      items: props.items.map((item) => ({
        ...item,
        value: props.loading ? _('Loading...') : _('Currently unavailable'),
      })),
    });
  }
  if (props.loading) {
    return renderLoadingState();
  }

  if (props.failed) {
    return renderFailedState();
  }

  return renderDefaultState(props);
}
