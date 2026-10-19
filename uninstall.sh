#!/bin/sh
# shellcheck shell=dash
# Independent of installed files: may also be downloaded after a broken install.
set -u
umask 077

KEEP_SETTINGS=1
KEEP_COMPONENTS=1
SETTINGS_CHOSEN=0
COMPONENTS_CHOSEN=0
YES=0
DRY_RUN=0
BACKUP=""
LOCKED=0
REMOVAL_STARTED=0
SUCCESS=0
ROOT=${TRAFIRA_UNINSTALL_ROOT:-}

fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Удаление Trafira: sh uninstall.sh [параметры]
Без параметров — мастер с подтверждением.
  --keep-settings       Сохранить настройки и профили (по умолчанию)
  --purge               Удалить настройки и профили Trafira
  --keep-components     Оставить sing-box, Zapret, Zapret2, ByeDPI (по умолчанию)
  --remove-components   Также удалить установленные пакеты этих компонентов
  --dry-run             Только показать план; ничего не изменять
  --yes                 Выполнить выбранный план без вопросов
  --help                Показать справку
Проверенная резервная копия в /root остаётся даже при --purge.
Конфигурации других программ, VPN-интерфейсы и общие зависимости не очищаются.
EOF
}
for arg in "$@"; do
    case "$arg" in
        --keep-settings) [ "$SETTINGS_CHOSEN" = 0 ] || fail 'Режим настроек указан дважды'; SETTINGS_CHOSEN=1; KEEP_SETTINGS=1 ;;
        --purge) [ "$SETTINGS_CHOSEN" = 0 ] || fail 'Режим настроек указан дважды'; SETTINGS_CHOSEN=1; KEEP_SETTINGS=0 ;;
        --keep-components) [ "$COMPONENTS_CHOSEN" = 0 ] || fail 'Режим компонентов указан дважды'; COMPONENTS_CHOSEN=1; KEEP_COMPONENTS=1 ;;
        --remove-components) [ "$COMPONENTS_CHOSEN" = 0 ] || fail 'Режим компонентов указан дважды'; COMPONENTS_CHOSEN=1; KEEP_COMPONENTS=0 ;;
        --yes) YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Неизвестный параметр: $arg" ;;
    esac
done

# Filesystem/package fixtures are explicitly gated and never use host package tools.
if [ -n "$ROOT" ]; then
    [ "${TRAFIRA_UNINSTALL_TEST_MODE:-0}" = 1 ] || fail 'Недопустимый тестовый корень'
    case "$ROOT" in /*) ;; *) fail 'Нужен абсолютный тестовый путь' ;; esac
    [ "$ROOT" != / ] && [ -f "$ROOT/.trafira-uninstall-test-root" ] && [ ! -L "$ROOT" ] || fail 'Небезопасный тестовый корень'
    PATH="$ROOT/bin:$PATH"
    export PATH
else
    [ "$(id -u)" = 0 ] || fail 'Запустите мастер от root на роутере'
fi
INIT="$ROOT/etc/init.d/trafira"
HELPER="$ROOT/usr/bin/trafira"
PACKAGE_HELPER="$ROOT/usr/lib/trafira/service/package.uc"
LOCK="$ROOT/tmp/trafira-uninstall.lock"

if [ -n "$ROOT" ]; then
    PM=${TRAFIRA_UNINSTALL_PACKAGE_MANAGER:-apk}
elif command -v apk >/dev/null 2>&1; then PM=apk
elif command -v opkg >/dev/null 2>&1; then PM=opkg
else fail 'Не найден apk или opkg'; fi
case "$PM" in apk|opkg) ;; *) fail 'Неизвестный пакетный менеджер' ;; esac
if [ -n "$ROOT" ]; then
    case "$(command -v "$PM")" in "$ROOT"/bin/*) ;; *) fail 'Не найден тестовый пакетный менеджер' ;; esac
fi
installed() {
    if [ "$PM" = apk ]; then "$PM" info
    else
        names=$("$PM" list-installed) || return 1
        printf '%s\n' "$names" | awk '{print $1}'
    fi
}
PACKAGES=$(installed) || fail 'Не удалось прочитать список установленных пакетов'
has_package() { printf '%s\n' "$PACKAGES" | grep -Fxq "$1"; }
TRAFIRA_PACKAGES=$(printf '%s\n' "$PACKAGES" | grep -E '^(trafira|luci-app-trafira|luci-i18n-trafira-[A-Za-z0-9_-]+)$' || :)
COMPONENT_PACKAGES=$(printf '%s\n' "$PACKAGES" | grep -E '^(sing-box|sing-box-tiny|sing-box-extended|zapret|zapret2|byedpi)$' || :)

ask_yes() {
    printf '%s ' "$1"
    answer=''
    IFS= read -r answer || return 1
    case "$answer" in y|Y|yes|YES|да|Да) return 0 ;; '') [ "$2" = yes ] ;; *) return 1 ;; esac
}
if [ "$YES" = 0 ] && [ "$DRY_RUN" = 0 ]; then
    [ -t 0 ] || [ -n "$ROOT" ] || fail 'Для мастера нужен терминал. Используйте --dry-run или явные параметры с --yes'
    if [ "$SETTINGS_CHOSEN" = 0 ]; then
        if ask_yes 'Сохранить настройки и профили? [Y/n]' yes; then KEEP_SETTINGS=1; else KEEP_SETTINGS=0; fi
    fi
    if [ "$COMPONENTS_CHOSEN" = 0 ]; then
        if ask_yes 'Удалить также пакеты sing-box, Zapret/Zapret2 и ByeDPI? [y/N]' no; then KEEP_COMPONENTS=0; else KEEP_COMPONENTS=1; fi
    fi
fi
printf '\nПакеты Trafira для удаления:\n%s\n' "${TRAFIRA_PACKAGES:-Нет}"
if [ "$KEEP_SETTINGS" = 1 ]; then printf 'Настройки и профили: сохранить\n'; else printf 'Настройки и профили: удалить после успешного удаления пакетов\n'; fi
if [ "$KEEP_COMPONENTS" = 1 ]; then printf 'Компоненты: оставить\n'
else printf 'Пакеты компонентов для удаления:\n%s\n' "${COMPONENT_PACKAGES:-Нет}"; fi
printf 'Резервная копия: /root/trafira-uninstall-XXXXXX/settings.tar.gz (не удаляется автоматически)\n'
[ "$DRY_RUN" = 0 ] || exit 0
if [ "$YES" = 0 ] && ! ask_yes 'Выполнить этот план? [y/N]' no; then printf 'Отменено. Ничего не изменено.\n'; exit 0; fi

if [ "$KEEP_COMPONENTS" = 1 ] && [ -f "$ROOT/etc/init.d/sing-box" ] &&
    grep -Fq 'Trafira managed sing-box service for binary variants' "$ROOT/etc/init.d/sing-box"; then
    grep -Fq 'TRAFIRA_UNINSTALL_KEEP_COMPONENTS' "$PACKAGE_HELPER" ||
        fail 'Эта версия Trafira не умеет сохранять управляемый бинарный sing-box при удалении. Сначала обновите Trafira или явно выберите --remove-components'
fi

restore_settings() {
    [ -n "$BACKUP" ] && [ -f "$BACKUP/settings.tar.gz" ] || return 0
    tar -xzf "$BACKUP/settings.tar.gz" -C "${ROOT:-/}"
}
finish() {
    code=$?
    trap - EXIT HUP INT TERM
    if [ "$REMOVAL_STARTED" = 1 ] && [ "$SUCCESS" = 0 ]; then
        restore_settings || printf 'Не удалось восстановить настройки из %s\n' "$BACKUP" >&2
        printf 'Удаление не завершено. Настройки не очищены; резервная копия: %s\n' "$BACKUP" >&2
    fi
    [ "$LOCKED" = 0 ] || rmdir "$LOCK" 2>/dev/null || :
    exit "$code"
}
mkdir "$LOCK" 2>/dev/null || fail 'Другое удаление Trafira уже выполняется'
LOCKED=1
trap finish EXIT
trap 'exit 1' HUP INT TERM
BACKUP=$(mktemp -d "$ROOT/root/trafira-uninstall-XXXXXX") || fail 'Не удалось создать каталог резервной копии'
chmod 700 "$BACKUP" || fail 'Не удалось защитить резервную копию'
BACKUP_PATHS=''
for path in etc/config/trafira etc/config/trafira.apk-new etc/config/trafira.apk-save etc/config/trafira.opkg-old etc/config/trafira.opkg-dist etc/trafira; do
    if [ -e "$ROOT/$path" ] || [ -L "$ROOT/$path" ]; then BACKUP_PATHS="$BACKUP_PATHS $path"; fi
done
if [ -n "$BACKUP_PATHS" ]; then
    # The list contains fixed owned paths only; filenames never come from user input.
    # shellcheck disable=SC2086
    tar -czf "$BACKUP/settings.tar.gz" -C "${ROOT:-/}" $BACKUP_PATHS || fail 'Резервная копия не создана; удаление остановлено'
    gzip -t "$BACKUP/settings.tar.gz" && tar -tzf "$BACKUP/settings.tar.gz" >/dev/null || fail 'Резервная копия не прошла проверку'
    sha256sum "$BACKUP/settings.tar.gz" > "$BACKUP/SHA256SUMS" || fail 'Не удалось записать контрольную сумму'
fi
printf 'Резервная копия: %s\n' "$BACKUP"
TRAFIRA_UNINSTALL_KEEP_COMPONENTS=$KEEP_COMPONENTS
export TRAFIRA_UNINSTALL_KEEP_COMPONENTS
if has_package trafira; then
    [ -x "$HELPER" ] || fail 'Не найден обработчик восстановления DNS. Восстановите пакет Trafira перед удалением'
    "$HELPER" package_prerm remove || fail 'Не удалось остановить Trafira и восстановить сеть; пакеты не удалены'
    if [ -x "$INIT" ]; then "$INIT" disable || fail 'Не удалось отключить автостарт'; fi
fi
remove_packages() {
    [ "$#" -gt 0 ] || return 0
    if [ "$PM" = apk ]; then "$PM" del "$@" || return 1
    else "$PM" remove "$@" || return 1; fi
    PACKAGES=$(installed) || return 1
    for removed in "$@"; do
        if has_package "$removed"; then printf 'Пакет %s остался установлен (возможна зависимость другой программы).\n' "$removed" >&2; return 1; fi
    done
}
REMOVAL_STARTED=1
# Names are restricted to the package allowlists above; no force/autoremove flags.
# shellcheck disable=SC2086
remove_packages $TRAFIRA_PACKAGES || fail 'Не удалось удалить все пакеты Trafira'
if [ "$KEEP_COMPONENTS" = 0 ]; then
    # shellcheck disable=SC2086
    remove_packages $COMPONENT_PACKAGES || fail 'Не удалось удалить все выбранные компоненты'
fi
if [ "$KEEP_SETTINGS" = 1 ]; then
    restore_settings || fail 'Не удалось вернуть сохранённые настройки'
else
    rm -f "$ROOT/etc/config/trafira" "$ROOT/etc/config/trafira.apk-new" "$ROOT/etc/config/trafira.apk-save" "$ROOT/etc/config/trafira.opkg-old" "$ROOT/etc/config/trafira.opkg-dist" || fail 'Не удалось удалить настройки Trafira'
    rm -rf "$ROOT/etc/trafira" || fail 'Не удалось удалить данные Trafira'
fi
sync || fail 'Не удалось записать изменения на накопитель'
SUCCESS=1
printf '\nTrafira удалена. Резервная копия: %s\nОбновите страницу LuCI.\n' "$BACKUP"
