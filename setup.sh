#!/bin/sh
# ======================================================================
#  Установка/удаление автообновления прошивки OpenWrt через ASU
#  Тестовый сервер: https://sysupgrade.routerich.ru/
#  Версия 6.7 (удаляем msmtp, но не curl)
#  Репозиторий: https://github.com/fomslav/rr-openwrt-auto-upgrade
# ======================================================================

set -e

# --- Проверка прав -----------------------------------------------------
if [ "$(id -u)" != "0" ]; then
    echo "❌ Запустите скрипт от root (sudo)."
    exit 1
fi

# --- Конфигурация логов ------------------------------------------------
INSTALL_LOG="/root/auto-upgrade-install.log"
CHECK_LOG="/root/auto-upgrade-check.log"
UPGRADE_LOG="/root/auto-upgrade-upgrade.log"
BACKUP_DIR="/root/backups"

# --- Функция для получения названия дня по номеру ---------------------
day_name() {
    case "$1" in
        0) echo "воскресенье" ;;
        1) echo "понедельник" ;;
        2) echo "вторник" ;;
        3) echo "среда" ;;
        4) echo "четверг" ;;
        5) echo "пятница" ;;
        6) echo "суббота" ;;
        *) echo "$1" ;;
    esac
}

# --- Функция логирования -----------------------------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$INSTALL_LOG"
}

# --- Функция отображения статуса ---------------------------------------
show_status() {
    echo "=== Текущий статус ==="
    if opkg list-installed | grep -q owut; then
        echo "  ✅ owut – установлен"
    else
        echo "  ❌ owut – не установлен"
    fi
    if opkg list-installed | grep -q luci-i18n-attendedsysupgrade-ru; then
        echo "  ✅ luci-i18n-attendedsysupgrade-ru – установлен"
    else
        echo "  ❌ luci-i18n-attendedsysupgrade-ru – не установлен"
    fi
    if [ -f /root/scripts/check-and-notify.sh ]; then
        echo "  ✅ Скрипт проверки – присутствует"
    else
        echo "  ❌ Скрипт проверки – отсутствует"
    fi
    if [ -f /root/scripts/auto-upgrade.sh ]; then
        echo "  ✅ Скрипт обновления – присутствует"
    else
        echo "  ❌ Скрипт обновления – отсутствует"
    fi
    if [ -f /root/scripts/send-success.sh ]; then
        echo "  ✅ Скрипт уведомления об успехе – присутствует"
    else
        echo "  ❌ Скрипт уведомления об успехе – отсутствует"
    fi
    if [ -f /etc/crontabs/root ] && grep -q "check-and-notify.sh" /etc/crontabs/root; then
        echo "  ✅ Задание cron (проверка) – активно"
    else
        echo "  ❌ Задание cron (проверка) – отсутствует"
    fi
    if [ -f /etc/crontabs/root ] && grep -q "auto-upgrade.sh" /etc/crontabs/root; then
        echo "  ✅ Задание cron (обновление) – активно"
    else
        echo "  ❌ Задание cron (обновление) – отсутствует"
    fi
    if [ -f /etc/rc.local ] && grep -q "/root/scripts/send-success.sh" /etc/rc.local; then
        echo "  ✅ Запуск уведомления об успехе в rc.local – присутствует"
    else
        echo "  ❌ Запуск уведомления об успехе в rc.local – отсутствует"
    fi
    SERVER_URL=$(uci get attendedsysupgrade.server.url 2>/dev/null) || true
    if [ -n "$SERVER_URL" ]; then
        echo "  🔗 Сервер ASU: $SERVER_URL"
    else
        echo "  🔗 Сервер ASU: не задан (используется стандартный)"
    fi
    echo "========================"
}

# --- Функция возврата в главное меню -----------------------------------
back_to_main() {
    echo
    read -p "Нажмите Enter, чтобы вернуться в главное меню..."
    main_menu
}

# --- Функция установки -------------------------------------------------
install_func() {
    log "Начинаем установку и настройку..."

    # 1. Обновление списков пакетов
    log "Обновление списков пакетов..."
    opkg update >>"$INSTALL_LOG" 2>&1

    # 2. Установка базовых пакетов (по отдельности)
    log "Установка owut..."
    opkg install owut >>"$INSTALL_LOG" 2>&1
    log "Установка luci-i18n-attendedsysupgrade-ru (если доступно)..."
    opkg install luci-i18n-attendedsysupgrade-ru >>"$INSTALL_LOG" 2>&1 || true

    # 3. Подключение к тестовому серверу
    log "Подключение к тестовому серверу https://sysupgrade.routerich.ru/"
    uci set attendedsysupgrade.server.url='https://sysupgrade.routerich.ru/'
    uci commit attendedsysupgrade

    # 4. Запрос данных для уведомлений (с возможностью отмены)
    while true; do
        echo
        echo "Выберите способ уведомлений:"
        echo "  1) Telegram (бот)"
        echo "  2) Email"
        echo "  3) Telegram + Email"
        echo "  0) Отменить установку и вернуться в главное меню"
        read -p "Введите номер: " notify_choice

        case "$notify_choice" in
            1|3)
                if [ "$notify_choice" = "1" ] || [ "$notify_choice" = "3" ]; then
                    echo
                    echo "Для Telegram-бота нужны:"
                    read -p "Введите токен бота (например, 123456:ABC-DEF): " TELEGRAM_TOKEN
                    read -p "Введите ваш Chat ID (число): " TELEGRAM_CHATID
                    if ! command -v curl >/dev/null 2>&1; then
                        log "Устанавливаю curl..."
                        opkg install curl >>"$INSTALL_LOG" 2>&1
                    fi
                fi
                if [ "$notify_choice" = "2" ] || [ "$notify_choice" = "3" ]; then
                    echo
                    echo "Для отправки email потребуется настроить SMTP."
                    read -p "Email получателя: " EMAIL_TO
                    read -p "SMTP сервер (например, smtp.gmail.com): " SMTP_SERVER
                    read -p "SMTP порт (обычно 587): " SMTP_PORT
                    read -p "SMTP логин (полный адрес): " SMTP_USER
                    read -p "SMTP пароль: " SMTP_PASS
                    log "Устанавливаю msmtp..."
                    opkg install msmtp >>"$INSTALL_LOG" 2>&1
                    cat > /etc/msmtprc <<EOF
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           $SMTP_SERVER
port           $SMTP_PORT
from           $SMTP_USER
user           $SMTP_USER
password       $SMTP_PASS
EOF
                    chmod 600 /etc/msmtprc
                fi
                break
                ;;
            0)
                log "Установка отменена пользователем."
                echo "Возврат в главное меню."
                return
                ;;
            *)
                echo "❌ Неверный ввод, попробуйте ещё раз."
                ;;
        esac
    done

    # Сохраняем параметры уведомлений в конфигурационный файл
    cat > /root/notify_config <<EOF
NOTIFY_TYPE="$notify_choice"
TELEGRAM_TOKEN="$TELEGRAM_TOKEN"
TELEGRAM_CHATID="$TELEGRAM_CHATID"
EMAIL_TO="$EMAIL_TO"
EOF
    chmod 600 /root/notify_config

    # 5. Запрос времени проверки и обновления
    echo
    echo "Введите день недели и время для ПРОВЕРКИ обновлений"
    echo "(день недели: 0-6, где 0 - воскресенье, 6 - суббота; время в формате HH:MM)"
    echo "Пример: 6 20:00 (суббота 20:00)"
    read -p "Оставьте пустым, чтобы оставить по умолчанию: 6 20:00: " check_schedule
    if [ -z "$check_schedule" ]; then
        check_schedule="6 20:00"
    fi
    check_day=$(echo "$check_schedule" | awk '{print $1}')
    check_time=$(echo "$check_schedule" | awk '{print $2}')

    echo
    echo "Введите день недели и время для УСТАНОВКИ обновлений"
    echo "(день недели: 0-6, где 0 - воскресенье, 6 - суббота; время в формате HH:MM)"
    echo "Пример: 0 03:00 (воскресенье 3:00)"
    read -p "Оставьте пустым, чтобы оставить по умолчанию: 0 03:00: " upgrade_schedule
    if [ -z "$upgrade_schedule" ]; then
        upgrade_schedule="0 03:00"
    fi
    upgrade_day=$(echo "$upgrade_schedule" | awk '{print $1}')
    upgrade_time=$(echo "$upgrade_schedule" | awk '{print $2}')

    # 6. Создание скриптов
    mkdir -p /root/scripts

    # Скрипт проверки (check-and-notify.sh)
    cat > /root/scripts/check-and-notify.sh <<'EOF'
#!/bin/sh
# Скрипт проверки обновлений (суббота 20:00)
# Логирование
LOG_FILE="/root/auto-upgrade-check.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Запуск проверки обновлений" >> "$LOG_FILE"

# Загружаем конфиг уведомлений
. /root/notify_config

# Функция отправки уведомления
send_notification() {
    local message="$1"
    local subject="Обновление прошивки роутера"
    # Отправка в Telegram
    case "$NOTIFY_TYPE" in
        1|3)
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
                 -d chat_id="${TELEGRAM_CHATID}" -d text="$message" >/dev/null
            ;;
    esac
    # Отправка Email через msmtp
    case "$NOTIFY_TYPE" in
        2|3)
            if command -v msmtp >/dev/null 2>&1; then
                echo -e "Subject: $subject\n\n$message" | msmtp "$EMAIL_TO"
            else
                echo "msmtp не установлен, отправка email невозможна" >> "$LOG_FILE"
            fi
            ;;
    esac
}

CURRENT_VER=$(cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_RELEASE | cut -d"'" -f2)

# Проверяем наличие обновления, перехватываем ошибки
OWUT_OUT=$(owut check 2>&1)
OWUT_EXIT=$?
if [ $OWUT_EXIT -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Ошибка при проверке обновлений: $OWUT_OUT" >> "$LOG_FILE"
    send_notification "❌ Ошибка при проверке обновлений на сервере. Код ошибки: $OWUT_EXIT. Подробности в логе."
    rm -f /tmp/do_upgrade
    exit 1
fi

echo "$OWUT_OUT" >> "$LOG_FILE"

if echo "$OWUT_OUT" | grep -qi "upgrade available"; then
    NEW_VER=$(echo "$OWUT_OUT" | grep -i "New version" | head -1 | sed -e 's/.*New version: //' -e 's/ .*//')
    [ -z "$NEW_VER" ] && NEW_VER="неизвестна"
    touch /tmp/do_upgrade
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Обновление доступно, создан флаг /tmp/do_upgrade" >> "$LOG_FILE"

    MESSAGE="🔔 Внимание! Автоматическое обновление прошивки запланировано на сегодня в 3:00.
Текущая версия: $CURRENT_VER
Новая версия: $NEW_VER

Для отмены обновления до 3:00 выполните на роутере:
  rm /tmp/do_upgrade

Если вы согласны, ничего не делайте — обновление произойдёт автоматически."
    send_notification "$MESSAGE"
else
    rm -f /tmp/do_upgrade
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Обновлений не найдено" >> "$LOG_FILE"
fi
EOF

    # Скрипт обновления (auto-upgrade.sh)
    cat > /root/scripts/auto-upgrade.sh <<'EOF'
#!/bin/sh
# Скрипт автоматического обновления (воскресенье 3:00)
LOG_FILE="/root/auto-upgrade-upgrade.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Запуск скрипта обновления" >> "$LOG_FILE"

if [ ! -f /tmp/do_upgrade ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Флаг обновления отсутствует, выходим" >> "$LOG_FILE"
    exit 0
fi

# Удаляем флаг, чтобы избежать повторного запуска
rm -f /tmp/do_upgrade

# 1. Создание бэкапа конфигурации
BACKUP_DIR="/root/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/backup-$(date '+%Y%m%d-%H%M%S').tar.gz"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Создание бэкапа /etc/config в $BACKUP_FILE" >> "$LOG_FILE"
tar -czf "$BACKUP_FILE" /etc/config 2>>"$LOG_FILE"
if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ОШИБКА создания бэкапа" >> "$LOG_FILE"
fi

# 2. Запуск обновления
echo "$(date '+%Y-%m-%d %H:%M:%S') - Запуск owut upgrade -y --keep-settings" >> "$LOG_FILE"
owut upgrade -y --keep-settings >>"$LOG_FILE" 2>&1
OWUT_EXIT=$?

if [ $OWUT_EXIT -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Обновление успешно установлено" >> "$LOG_FILE"
    # Создаём флаг успешного обновления для уведомления после перезагрузки
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Создание флага /root/upgrade_success" >> "$LOG_FILE"
    echo "success" > /root/upgrade_success
    # Перезагружаем роутер (если owut не перезагрузила сама)
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Перезагрузка системы" >> "$LOG_FILE"
    reboot
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ОШИБКА обновления, код: $OWUT_EXIT" >> "$LOG_FILE"
    # Отправляем уведомление об ошибке (используем тот же конфиг)
    . /root/notify_config
    MESSAGE="❌ Ошибка при обновлении прошивки. Код: $OWUT_EXIT. Проверьте лог $LOG_FILE"
    # Отправка уведомления (аналогично check-and-notify.sh)
    case "$NOTIFY_TYPE" in
        1|3)
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
                 -d chat_id="${TELEGRAM_CHATID}" -d text="$MESSAGE" >/dev/null
            ;;
    esac
    case "$NOTIFY_TYPE" in
        2|3)
            if command -v msmtp >/dev/null 2>&1; then
                echo -e "Subject: Ошибка обновления роутера\n\n$MESSAGE" | msmtp "$EMAIL_TO"
            fi
            ;;
    esac
fi
EOF

    # Скрипт отправки уведомления об успешном старте (запускается из rc.local с задержкой)
    cat > /root/scripts/send-success.sh <<'EOF'
#!/bin/sh
# Скрипт отправки уведомления об успешном обновлении после загрузки
# Запускается с задержкой 2 минуты из rc.local

sleep 120  # ждём 2 минуты, чтобы система полностью загрузилась

if [ -f /root/upgrade_success ]; then
    . /root/notify_config
    MESSAGE="✅ Роутер успешно обновлён и перезагружен! Текущая версия: $(cat /etc/openwrt_release | grep DISTRIB_RELEASE | cut -d"'" -f2)"
    # Отправка в Telegram
    case "$NOTIFY_TYPE" in
        1|3)
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
                 -d chat_id="${TELEGRAM_CHATID}" -d text="$MESSAGE" >/dev/null
            ;;
    esac
    # Отправка Email через msmtp
    case "$NOTIFY_TYPE" in
        2|3)
            if command -v msmtp >/dev/null 2>&1; then
                echo -e "Subject: Успешное обновление роутера\n\n$MESSAGE" | msmtp "$EMAIL_TO"
            fi
            ;;
    esac
    rm -f /root/upgrade_success
fi
EOF

    chmod +x /root/scripts/check-and-notify.sh
    chmod +x /root/scripts/auto-upgrade.sh
    chmod +x /root/scripts/send-success.sh

    # 7. Настройка cron с комментариями, содержащими названия дней
    log "Настройка заданий cron..."
    # Удаляем старые записи
    sed -i '/check-and-notify.sh/d' /etc/crontabs/root 2>/dev/null
    sed -i '/auto-upgrade.sh/d' /etc/crontabs/root 2>/dev/null
    sed -i '/# Проверка обновлений/d' /etc/crontabs/root 2>/dev/null
    sed -i '/# Автоматическое обновление/d' /etc/crontabs/root 2>/dev/null
    # Добавляем новые с комментариями
    echo "# Проверка обновлений и уведомление ($(day_name $check_day) в $check_time)" >> /etc/crontabs/root
    echo "$check_time * * $check_day /root/scripts/check-and-notify.sh" >> /etc/crontabs/root
    echo "# Автоматическое обновление ($(day_name $upgrade_day) в $upgrade_time)" >> /etc/crontabs/root
    echo "$upgrade_time * * $upgrade_day /root/scripts/auto-upgrade.sh" >> /etc/crontabs/root
    /etc/init.d/cron restart

    # 8. Настройка rc.local для запуска send-success.sh после загрузки
    log "Настройка rc.local для отправки уведомления об успехе..."
    sed -i '/send-success.sh/d' /etc/rc.local 2>/dev/null
    sed -i '/exit 0/d' /etc/rc.local 2>/dev/null
    echo "/root/scripts/send-success.sh &" >> /etc/rc.local
    echo "exit 0" >> /etc/rc.local

    # 9. Итоговый экран (с названиями дней)
    check_day_name=$(day_name "$check_day")
    upgrade_day_name=$(day_name "$upgrade_day")
    echo
    echo "============================================================"
    echo "✅ Установка и настройка завершены!"
    echo "============================================================"
    echo "📌 Расписание:"
    echo "   - Проверка обновлений: $check_day_name в $check_time"
    echo "   - Установка обновлений: $upgrade_day_name в $upgrade_time"
    echo
    echo "📩 Уведомления:"
    case "$notify_choice" in
        1) echo "   - Telegram" ;;
        2) echo "   - Email" ;;
        3) echo "   - Telegram + Email" ;;
    esac
    echo "🌐 Сервер ASU: https://sysupgrade.routerich.ru/"
    echo
    echo "📁 Логи и бэкапы:"
    echo "   - Лог установки:      $INSTALL_LOG"
    echo "   - Лог проверок:       $CHECK_LOG"
    echo "   - Лог обновлений:     $UPGRADE_LOG"
    echo "   - Бэкапы конфигов:    $BACKUP_DIR/"
    echo
    echo "🔔 Уведомление об успешном обновлении будет отправлено"
    echo "   через 2 минуты после перезагрузки."
    echo "============================================================"
    log "Установка завершена успешно."
    read -p "Нажмите Enter, чтобы вернуться в главное меню..."
}

# --- Функция удаления --------------------------------------------------
uninstall_func() {
    log "Начинаем удаление всех компонентов..."

    # 1. Удаление пакетов, которые мы устанавливаем (кроме curl)
    for pkg in owut luci-i18n-attendedsysupgrade-ru msmtp; do
        if opkg list-installed | grep -q "^$pkg -"; then
            log "Удаляю пакет $pkg..."
            opkg remove $pkg >>"$INSTALL_LOG" 2>&1
        else
            log "Пакет $pkg не установлен, пропускаем."
        fi
    done

    # 2. Удаление скриптов и папки
    if [ -d /root/scripts ]; then
        log "Удаляю директорию /root/scripts/ ..."
        rm -rf /root/scripts
    fi

    # 3. Удаление конфига msmtp (если создан)
    if [ -f /etc/msmtprc ]; then
        log "Удаляю /etc/msmtprc ..."
        rm -f /etc/msmtprc
    fi

    # 4. Удаление файла конфигурации уведомлений
    if [ -f /root/notify_config ]; then
        log "Удаляю /root/notify_config"
        rm -f /root/notify_config
    fi

    # 5. Удаление флагов
    rm -f /tmp/do_upgrade /root/upgrade_success

    # 6. Удаление заданий cron
    log "Удаляю задания cron..."
    sed -i '/check-and-notify.sh/d' /etc/crontabs/root 2>/dev/null
    sed -i '/auto-upgrade.sh/d' /etc/crontabs/root 2>/dev/null
    sed -i '/# Проверка обновлений/d' /etc/crontabs/root 2>/dev/null
    sed -i '/# Автоматическое обновление/d' /etc/crontabs/root 2>/dev/null
    /etc/init.d/cron restart

    # 7. Удаление записей из rc.local
    log "Удаляю запись о send-success.sh из /etc/rc.local"
    sed -i '/send-success.sh/d' /etc/rc.local 2>/dev/null

    # 8. Удаление настройки сервера ASU
    if uci get attendedsysupgrade.server.url >/dev/null 2>&1; then
        log "Удаляю настройку сервера ASU (uci delete)..."
        uci delete attendedsysupgrade.server.url
        uci commit attendedsysupgrade
    fi

    # 9. Логи и бэкапы остаются (не удаляем, чтобы не потерять данные)
    echo "============================================================"
    echo "✅ Все компоненты удалены."
    echo "============================================================"
    echo "📁 Логи и бэкапы сохранены в:"
    echo "   - $INSTALL_LOG (если есть)"
    echo "   - $CHECK_LOG (если есть)"
    echo "   - $UPGRADE_LOG (если есть)"
    echo "   - $BACKUP_DIR/ (если есть)"
    echo "   Вы можете удалить их вручную."
    echo "============================================================"
    log "Удаление завершено."
    read -p "Нажмите Enter, чтобы вернуться в главное меню..."
}

# --- Главное меню ------------------------------------------------------
main_menu() {
#    clear
    echo "============================================================"
    echo "   Настройка / удаление автообновления прошивки OpenWrt"
    echo "   Тестовый сервер: https://sysupgrade.routerich.ru/"
    echo "   Репозиторий: https://github.com/fomslav/rr-openwrt-auto-upgrade"
    echo "============================================================"
    show_status
    echo
    echo "Выберите действие:"
    echo "  1) Установить и настроить автообновление"
    echo "  2) Удалить все созданные компоненты"
    echo "  0) Выход"
    read -p "Введите номер: " action

    case "$action" in
        1)
            echo
            echo "Вы выбрали УСТАНОВКУ и настройку."
            echo "Будут выполнены следующие действия:"
            echo "  - Установка пакетов: owut, luci-i18n-attendedsysupgrade-ru"
            echo "  - Подключение к тестовому серверу: https://sysupgrade.routerich.ru/"
            echo "  - Создание скриптов в /root/scripts/"
            echo "  - Настройка cron для проверки и установки обновлений"
            echo "  - Настройка выбранного способа уведомлений (Telegram или Email)"
            echo "  - Настройка автоматического уведомления об успехе после перезагрузки"
            echo "  - Логирование всех операций"
            echo
            read -p "Продолжить? (y/N): " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                install_func
            else
                echo "Отмена."
                read -p "Нажмите Enter, чтобы продолжить..."
            fi
            main_menu
            ;;
        2)
            echo
            echo "Вы выбрали УДАЛЕНИЕ всех компонентов."
            echo "Будут выполнены следующие действия:"
            echo "  - Удаление пакетов: owut, luci-i18n-attendedsysupgrade-ru, msmtp (если установлены)"
            echo "  - Удаление скриптов из /root/scripts/"
            echo "  - Удаление конфигурационных файлов (/etc/msmtprc, /root/notify_config)"
            echo "  - Удаление заданий cron, связанных с обновлением"
            echo "  - Удаление записей из rc.local"
            echo "  - Удаление настройки сервера ASU (параметр url)"
            echo "  - Удаление временных флагов"
            echo "  - Логи и бэкапы останутся нетронутыми"
            echo "  - Пакет curl НЕ удаляется (может использоваться системой)"
            echo
            read -p "Продолжить? (y/N): " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                uninstall_func
            else
                echo "Отмена."
                read -p "Нажмите Enter, чтобы продолжить..."
            fi
            main_menu
            ;;
        0)
            echo "Выход."
            exit 0
            ;;
        *)
            echo "❌ Неверный ввод."
            read -p "Нажмите Enter, чтобы продолжить..."
            main_menu
            ;;
    esac
}

# --- Запуск -----------------------------------------------------------
main_menu
