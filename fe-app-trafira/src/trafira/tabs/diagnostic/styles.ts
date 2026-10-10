// language=CSS
import { TRAFIRA_UCI_PACKAGE as TRAFIRA_CBI_PREFIX } from '../../../constants';

export const styles = `

#cbi-${TRAFIRA_CBI_PREFIX}-diagnostic-_mount_node > div {
    width: 100%;
}

#cbi-${TRAFIRA_CBI_PREFIX}-diagnostic > h3 {
    display: none;
}

.fkp_diagnostic-page {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(220px, 300px);
    gap: 16px;
    align-items: start;
}

@media (max-width: 1000px) {
    .fkp_diagnostic-page {
        grid-template-columns: 1fr;
    }
}

.fkp_diagnostic-page__right-bar {
    display: grid;
    grid-template-columns: 1fr;
    grid-row-gap: 10px;
}

.fkp_diagnostic-page__right-bar__wiki {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;

    display: grid;
    grid-template-columns: auto;
    grid-row-gap: 10px;
}

.fkp_diagnostic-page__right-bar__wiki--warning {
    border: 2px var(--warn-color-medium, orange) solid;
}
.fkp_diagnostic-page__right-bar__wiki--error {
    border: 2px var(--error-color-medium, red) solid;
}

.fkp_diagnostic-page__right-bar__wiki__content {
    display: grid;
    grid-template-columns: 1fr 5fr;
    grid-column-gap: 10px;
}

.fkp_diagnostic-page__right-bar__wiki__texts {}

.fkp_diagnostic-page__right-bar__actions {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;

    display: grid;
    grid-template-columns: auto;
    grid-row-gap: 10px;

}

.fkp_diagnostic-page__right-bar__actions > .fkp-partial-button {
    width: 100%;
    min-width: 0;
    margin-left: 0;
}

.fkp_diagnostic-page__right-bar__system-info {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;

    display: grid;
    grid-template-columns: auto;
    grid-row-gap: 10px;
}

.fkp_diagnostic-page__right-bar__system-info__title {

}

.fkp_diagnostic-page__right-bar__system-info__row {
    display: grid;
    grid-template-columns: auto 1fr;
    grid-column-gap: 5px;
}

.fkp_diagnostic-page__right-bar__system-info__row__tag {
    padding: 2px 4px;
    border: 1px transparent solid;
    border-radius: 4px;
    margin-left: 5px;
}

.fkp_diagnostic-page__right-bar__system-info__row__tag--neutral {
    border: 1px var(--background-color-high, gray) solid;
    color: var(--text-color-medium, gray);
}

.fkp_diagnostic-page__right-bar__system-info__row__tag--warning {
    border: 1px var(--warn-color-medium, orange) solid;
    color: var(--warn-color-medium, orange);
}

.fkp_diagnostic-page__right-bar__system-info__row__tag--success {
    border: 1px var(--success-color-medium, green) solid;
    color: var(--success-color-medium, green);
}

.fkp_diagnostic-page__left-bar {
    display: grid;
    grid-template-columns: 1fr;
    grid-row-gap: 10px;
}

.fkp_diagnostic-page__run_check_wrapper {}

.fkp_diagnostic-page__run_check_wrapper button {
    width: 100%;
}

.fkp_diagnostic-page__checks {
    display: grid;
    grid-template-columns: 1fr;
    grid-row-gap: 10px;
}

.fkp_diagnostic_alert {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;

    display: grid;
    grid-template-columns: 24px 1fr;
    grid-column-gap: 10px;
    align-items: center;
    padding: 10px;
}

.fkp_diagnostic_alert--loading {
    border: 2px var(--primary-color-high, dodgerblue) solid;
}

.fkp_diagnostic_alert--warning {
    border: 2px var(--warn-color-medium, orange) solid;
    color: var(--warn-color-medium, orange);
}

.fkp_diagnostic_alert--error {
    border: 2px var(--error-color-medium, red) solid;
    color: var(--error-color-medium, red);
}

.fkp_diagnostic_alert--success {
    border: 2px var(--success-color-medium, green) solid;
    color: var(--success-color-medium, green);
}

.fkp_diagnostic_alert--skipped {}

.fkp_diagnostic_alert__icon {}

.fkp_diagnostic_alert__content {}

.fkp_diagnostic_alert__title {
    display: block;
}

.fkp_diagnostic_alert__description {}

.fkp_diagnostic_alert__summary {
    margin-top: 10px;
}

.fkp_diagnostic_alert__summary__item {
    display: grid;
    grid-template-columns: 16px auto 1fr;
    grid-column-gap: 10px;
}

.fkp_diagnostic_alert__summary__item--error {
    color: var(--error-color-medium, red);
}

.fkp_diagnostic_alert__summary__item--warning {
    color: var(--warn-color-medium, orange);
}

.fkp_diagnostic_alert__summary__item--success {
    color: var(--success-color-medium, green);
}

.fkp_diagnostic_alert__summary__item__icon {
    width: 16px;
    height: 16px;
}

.fkp_diagnostic-page > div,
.fkp_diagnostic-page__lower > div {
    min-width: 0;
}

.fkp_diagnostic-page__lower {
    grid-column: 1 / -1;
    display: grid;
    gap: 16px;
}

.fkp_diagnostic-panel,
#trafira-profiles,
#trafira-gaming-presets {
    border: 1px solid var(--background-color-low, lightgray);
    border-radius: 4px;
    padding: 16px;
    min-width: 0;
    overflow-wrap: anywhere;
}

.fkp_diagnostic-panel h3,
#trafira-profiles > h3,
#trafira-gaming-presets > h3 {
    margin-top: 0;
}

.fkp_diagnostic-fields {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 240px), 1fr));
    gap: 12px 16px;
    margin: 12px 0;
}

.fkp_diagnostic-field {
    display: flex;
    flex-direction: column;
    gap: 6px;
    min-width: 0;
}

.fkp_diagnostic-field > input,
.fkp_diagnostic-field > select {
    box-sizing: border-box;
    width: 100%;
    min-width: 0;
    max-width: 100%;
}

.fkp_diagnostic-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin: 12px 0;
}

.fkp_diagnostic-actions > button {
    margin: 0;
    white-space: normal;
    max-width: 100%;
}

.fkp_diagnostic-details {
    margin: 12px 0;
}

.fkp_diagnostic-details > summary {
    cursor: pointer;
    padding: 6px 0;
}

.fkp_diagnostic-snapshots {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 280px), 1fr));
    gap: 12px 24px;
    margin-top: 12px;
}

.fkp_diagnostic-snapshots > div {
    min-width: 0;
    overflow-wrap: anywhere;
    border-top: 1px solid var(--background-color-low, lightgray);
    padding-top: 10px;
}

.fkp_diagnostic-page p {
    max-width: 80ch;
}

.fkp_route-decision {
    padding: 12px;
    margin: 10px 0;
    border: 1px solid var(--border-color-low, #ddd);
    border-left: 3px solid var(--success-color-medium, #39834a);
    border-radius: 4px;
}
.fkp_route-decision--indeterminate,
.fkp_route-decision--blocked {
    border-left-color: var(--warning-color-medium, #b47916);
}
.fkp_route-basis {
    color: var(--text-color-medium, #666);
}
`;
