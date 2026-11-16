#!/opt/bin/sh

# ================================
#   CONFIG
# ================================
LOG_DIR="/opt/var/log"
TMP_DIR="/opt/tmp"
IPERF_BIN="/opt/bin/iperf3"
SERVER="st.cheb.ertelecom.ru"

# Порты iperf3 для перебора (строго по порядку)
IPERF_PORT_START=5201
IPERF_PORT_END=5209

MAX_API_DOMAIN="platform-api2.max.ru"

IPERF_LOG="$LOG_DIR/iperf3.log"
DAILY_VALUES="$LOG_DIR/iperf3_daily_values.txt"
DAILY_STATS="$LOG_DIR/iperf3_daily_stats.json"
LAST_RESET_FILE="$LOG_DIR/iperf3_daily_reset.flag"
LOCK_FILE="$TMP_DIR/iperf_monitor.lock"

# --- MONTHLY STATS CONFIG ---
MONTHLY_VALUES="$LOG_DIR/iperf3_monthly_values.txt"
MONTHLY_STATS="$LOG_DIR/iperf3_monthly_stats.json"
LAST_MONTH_FILE="$LOG_DIR/iperf3_monthly_reset.flag"

# Порог критической скорости в Mbps для мгновенного алерта
CRIT_THRESHOLD_MBPS="90.0"

CONFIG_FILE="/opt/etc/proxy_monitor.conf"

if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
fi

CURL="/opt/bin/curl -k -s --connect-timeout 4 --max-time 8"
JQ="/opt/bin/jq"

mkdir -p "$LOG_DIR" "$TMP_DIR"

# ================================
#   LOCK
# ================================
if [ -f "$LOCK_FILE" ]; then
    prev_pid=$(cat "$LOCK_FILE")

    if [ -n "$prev_pid" ] && kill -0 "$prev_pid" 2>/dev/null; then
        proc_name=$(ps | awk -v pid="$prev_pid" '$1 == pid {print $0}')

        if echo "$proc_name" | grep -qE 'sh|iperf'; then
            exit 0
        fi
    fi

    rm -f "$LOCK_FILE"
fi

echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT


# ================================
#   FUNCTIONS
# ================================

send_max_alert() {
    local json_payload

    json_payload=$($JQ -n --arg txt "$1" '{text: $txt}')

    $CURL -X POST "https://$MAX_API_DOMAIN/messages?user_id=$MAX_CHAT_ID" \
        -H "Authorization: $MAX_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$json_payload" >/dev/null 2>&1
}


# ================================
#   EMAIL
# ================================

send_mail() {
    [ "$SMTP_SERVER" = "smtp://" ] && return 0

    local tmp="$TMP_DIR/mail_$$.txt"

    {
        printf "From: %s\r\n" "$MAIL_FROM"
        printf "To: %s\r\n" "$MAIL_TO"
        printf "Subject: %s\r\n" "$1"
        printf "Content-Type: text/plain; charset=UTF-8\r\n"
        printf "Content-Transfer-Encoding: 8bit\r\n"
        printf "\r\n"
        printf "%b\r\n" "$2"
        printf "\r\n"
        printf "Штамп времени: %s\r\n" "$(date)"
        printf "Система: прокси монитор\r\n"
    } > "$tmp"

    $CURL \
        --url "$SMTP_SERVER" \
        --ssl-reqd \
        --user "$SMTP_USER:$SMTP_PASS" \
        --mail-from "$SMTP_USER" \
        --mail-rcpt "$MAIL_TO" \
        --noproxy "*" \
        --cacert /opt/etc/ssl/certs/ca-certificates.crt \
        -T "$tmp" >/dev/null 2>&1

    local result=$?

    rm -f "$tmp"

    if [ "$result" -eq 0 ]; then
        log "Email sent successfully to $MAIL_TO"
        return 0
    else
        log "Email sending failed to $MAIL_TO, curl exit code $result"
        return 1
    fi
}


log() {
    echo "$(date '+%F %T') $1" >> "$IPERF_LOG"
}


# ================================
#   DAILY STATS
# ================================

reset_daily_stats() {
    > "$DAILY_VALUES"

    cat > "$DAILY_STATS" <<EOF
{
  "count": 0,
  "sum_mbps": 0.0,
  "min_mbps": null,
  "max_mbps": null
}
EOF

    date +%F > "$LAST_RESET_FILE"
}


# ================================
#   MONTHLY STATS
# ================================

reset_monthly_stats() {
    > "$MONTHLY_VALUES"

    cat > "$MONTHLY_STATS" <<EOF
{
  "count": 0,
  "sum_mbps": 0.0,
  "min_mbps": null,
  "max_mbps": null
}
EOF

    date '+%Y-%m' > "$LAST_MONTH_FILE"
}


# ================================
#   SAVE MEASUREMENT
# ================================

append_daily_value() {
    # Для дневного отчета
    echo "$(date '+%Hч%Mм') $1" >> "$DAILY_VALUES"

    # Для месячного отчета:
    # дата + время + скорость
    echo "$(date '+%d.%m.%Y %H:%M') $1" >> "$MONTHLY_VALUES"
}


# ================================
#   UPDATE JSON STATS
# ================================

update_stats_json() {
    local stats_file="$1"
    local val="$2"

    if [ -f "$stats_file" ]; then
        $JQ --argjson nv "$val" '
            .count += 1 |
            (.sum_mbps | tonumber) + $nv as $new_sum |
            .sum_mbps = ($new_sum * 100 | round / 100) |
            .min_mbps = (
                if .min_mbps == null or $nv < (.min_mbps | tonumber)
                then $nv
                else (.min_mbps | tonumber)
                end
            ) |
            .max_mbps = (
                if .max_mbps == null or $nv > (.max_mbps | tonumber)
                then $nv
                else (.max_mbps | tonumber)
                end
            )
        ' "$stats_file" > "${stats_file}.tmp" &&
        mv "${stats_file}.tmp" "$stats_file"
    fi
}


# ================================
#   DAILY SUMMARY
# ================================

send_daily_summary() {
    local date_prev="$1"
    local count sum min max avg all_values msg

    count=$($JQ -r '.count // 0' "$DAILY_STATS")
    sum=$($JQ -r '.sum_mbps // 0.0' "$DAILY_STATS")
    min=$($JQ -r '.min_mbps // "N/A"' "$DAILY_STATS")
    max=$($JQ -r '.max_mbps // "N/A"' "$DAILY_STATS")

    if [ "$count" -eq 0 ]; then
        avg="0.00"
    else
        avg=$(awk "BEGIN {printf \"%.2f\", $sum / $count}")
    fi

    if [ -f "$DAILY_VALUES" ]; then
        all_values=$(awk '
        {
            speed=$2

            if (speed > 100)
                marker="🟢"
            else if (speed >= 50)
                marker="🟡"
            else
                marker="🔴"

            printf "%-8s | %06.2f Mbps | %s\n", \
                   $1, speed, marker
        }' "$DAILY_VALUES")
    else
        all_values="Нет данных"
    fi

    msg="📊 Средняя скорость за $date_prev: ${avg} Mbps
Количество замеров: $count
Минимум: $min Mbps
Максимум: $max Mbps

${all_values}

Сервер: ${SERVER}
Порты: ${IPERF_PORT_START}-${IPERF_PORT_END}
Режим: reverse (-R)
$(date '+%F %T')"

    log "Daily summary processed for $date_prev"

    # Если нужен ежедневный отчет в MAX:
    # send_max_alert "$msg"
}


# ================================
#   MONTHLY SUMMARY
# ================================

send_monthly_summary() {
    local month_prev="$1"
    local count sum min max avg all_values msg

    count=$($JQ -r '.count // 0' "$MONTHLY_STATS")
    sum=$($JQ -r '.sum_mbps // 0.0' "$MONTHLY_STATS")
    min=$($JQ -r '.min_mbps // "N/A"' "$MONTHLY_STATS")
    max=$($JQ -r '.max_mbps // "N/A"' "$MONTHLY_STATS")

    if [ "$count" -eq 0 ]; then
        avg="0.00"
    else
        avg=$(awk "BEGIN {printf \"%.2f\", $sum / $count}")
    fi

    if [ -s "$MONTHLY_VALUES" ]; then
        all_values=$(awk '
        {
            date=$1
            time=$2
            speed=$3

            if (speed > 100)
                marker="🟢"
            else if (speed >= 50)
                marker="🟡"
            else
                marker="🔴"

            printf "%-12s %-8s %8.2f Mbps  %s\n", \
                   date, time, speed, marker
        }' "$MONTHLY_VALUES")
    else
        all_values="Нет данных за месяц"
    fi


    # ================================
    #   MAX MESSAGE
    # ================================

    msg="📊 [iPerf3] Ежемесячный отчет по скорости за $month_prev

🔹 Всего замеров: $count
🔹 Средняя скорость: ${avg} Mbps
🔹 Минимальная скорость: $min Mbps
🔹 Максимальная скорость: $max Mbps

Сервер: ${SERVER}
Порты: ${IPERF_PORT_START}-${IPERF_PORT_END}
Режим: reverse (-R)
$(date '+%F %T')"

    log "Monthly summary for $month_prev"

    # Краткий отчет в MAX
    send_max_alert "$msg"


    # ================================
    #   FULL EMAIL REPORT
    # ================================

    msg="📊 [iPerf3] Полный отчет за ${month_prev}

Количество замеров: ${count}
Средняя скорость: ${avg} Mbps
Минимальная скорость: ${min} Mbps
Максимальная скорость: ${max} Mbps

Сервер: ${SERVER}
Порты: ${IPERF_PORT_START}-${IPERF_PORT_END}
Режим: reverse (-R)

Все замеры за месяц:
------------------------------------------------------------
Дата         Время       Скорость
------------------------------------------------------------
${all_values}
------------------------------------------------------------

Порог критической скорости: ${CRIT_THRESHOLD_MBPS} Mbps

🟢 > 100 Mbps
🟡 50-100 Mbps
🔴 < 50 Mbps

Отчет сформирован: $(date '+%F %T')"

    send_mail "[iPerf3] Полный отчет за ${month_prev}" "$msg"

    log "Monthly full email report processed for $month_prev"
}


# ================================
#   IPERF3 CORE RUNNER
# ================================

run_iperf_single() {
    local tmp="$TMP_DIR/iperf_$$.json"
    local err="$TMP_DIR/iperf_$$.err"
    local iperf_pid exit_code port used_port=""
    local error_msg bps mbps is_low_speed

    for port in $(seq "$IPERF_PORT_START" "$IPERF_PORT_END")
    do
        log "iperf3: trying port $port"

        rm -f "$tmp" "$err"

        "$IPERF_BIN" \
            -c "$SERVER" \
            -p "$port" \
            -t 30 \
            -P 4 \
            -4 \
            -R \
            -J \
            --connect-timeout 5000 \
            > "$tmp" 2> "$err" &

        iperf_pid=$!

        # Активное ожидание завершения
        local t=0

        while [ $t -lt 40 ]; do
            if ! kill -0 "$iperf_pid" 2>/dev/null; then
                break
            fi

            sleep 1
            t=$((t + 1))
        done

        # Если iperf3 завис — убиваем
        if kill -0 "$iperf_pid" 2>/dev/null; then
            kill -9 "$iperf_pid" 2>/dev/null
            wait "$iperf_pid" 2>/dev/null || true

            log "iperf3: port $port timeout (hung up)"
            continue
        fi

        wait "$iperf_pid"
        exit_code=$?

        if [ "$exit_code" -ne 0 ]; then
            if [ -s "$err" ]; then
                log "iperf3: port $port failed, code $exit_code. Stderr: $(head -n 20 "$err" | tr '\n' '|')"
            else
                log "iperf3: port $port failed, code $exit_code, no stderr"
            fi

            continue
        fi

        if [ ! -s "$tmp" ]; then
            log "iperf3: port $port returned empty JSON"
            continue
        fi

        error_msg=$($JQ -r '.error // empty' "$tmp")

        if [ -n "$error_msg" ]; then
            log "iperf3: port $port server error: $error_msg"
            continue
        fi

        bps=$($JQ -r '.end.sum_received.bits_per_second // .end.sum_sent.bits_per_second // empty' "$tmp")

        if [ -z "$bps" ] || [ "$bps" = "null" ]; then
            log "iperf3: port $port has no valid speed value"
            continue
        fi

        if ! echo "$bps" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
            log "iperf3: port $port returned invalid speed: '$bps'"
            continue
        fi

        used_port="$port"
        break
    done

    if [ -z "$used_port" ]; then
        log "iperf3: all ports ${IPERF_PORT_START}-${IPERF_PORT_END} failed"

        rm -f "$tmp" "$err"

        return 1
    fi


    # ================================
    #   CONVERT TO MBPS
    # ================================

    mbps=$(awk "BEGIN {printf \"%.2f\", $bps / 1000000}" | tr ',' '.')


    # ================================
    #   SAVE STATS
    # ================================

    append_daily_value "$mbps"

    update_stats_json "$DAILY_STATS" "$mbps"
    update_stats_json "$MONTHLY_STATS" "$mbps"


    # ================================
    #   LOG RESULT
    # ================================

    log "iperf3 success: ${mbps} Mbps on port ${used_port}"

    echo "$mbps" > "$TMP_DIR/iperf_last_mbps.txt"
    echo "$used_port" > "$TMP_DIR/iperf_last_port.txt"


    # ================================
    #   CRITICAL SPEED ALERT
    # ================================

    is_low_speed=$(awk "BEGIN {print ($mbps < $CRIT_THRESHOLD_MBPS) ? 1 : 0}")

    if [ "$is_low_speed" -eq 1 ]; then

        log "Alert triggered: speed ${mbps} Mbps is below threshold ${CRIT_THRESHOLD_MBPS} Mbps on port ${used_port}"

        send_max_alert "🚨 [iPerf3] Внимание! Низкая скорость соединения!

Текущая: ${mbps} Mbps
Порог: ${CRIT_THRESHOLD_MBPS} Mbps
Сервер: ${SERVER}:${used_port}
Режим: reverse (-R)
$(date '+%F %T')"
    fi


    rm -f "$tmp" "$err"

    return 0
}


# ================================
#   RETRIES LOGIC
# ================================

run_iperf_with_retries() {
    local max_retries=3
    local delay=10
    local attempt=1

    while [ "$attempt" -le "$max_retries" ]; do

        log "Starting iperf3 attempt ${attempt}/${max_retries}"

        if run_iperf_single; then
            return 0
        fi

        if [ "$attempt" -lt "$max_retries" ]; then

            log "iperf3 attempt ${attempt} failed, retrying in ${delay} seconds"

            sleep "$delay"

            delay=$(expr "$delay" + 10)
        fi

        attempt=$(expr "$attempt" + 1)
    done


    log "All iperf3 attempts failed (3 retries)"

    send_max_alert "⚠️ [iPerf3] Все попытки теста не удались!

Сервер: ${SERVER}
Проверены порты: ${IPERF_PORT_START}-${IPERF_PORT_END}
Попыток: 3
Режим: reverse (-R)
$(date '+%F %T')"

    return 1
}


# ================================
#   INITIALIZE DATABASES
# ================================

if [ ! -f "$DAILY_STATS" ]; then
    reset_daily_stats
fi

if [ ! -f "$MONTHLY_STATS" ]; then
    reset_monthly_stats
fi


# ================================
#   ROTATION BEFORE NEW MEASUREMENT
# ================================

# ----------------
# DAILY ROTATION
# ----------------

TODAY=$(date +%F)
LAST_RESET=""

if [ -f "$LAST_RESET_FILE" ]; then
    LAST_RESET=$(cat "$LAST_RESET_FILE")
else
    date +%F > "$LAST_RESET_FILE"
    LAST_RESET="$TODAY"
fi

if [ "$TODAY" != "$LAST_RESET" ] && [ -n "$LAST_RESET" ]; then

    log "New day detected. Sending summary for $LAST_RESET and resetting daily stats."

    send_daily_summary "$LAST_RESET"

    reset_daily_stats
fi


# ----------------
# MONTHLY ROTATION
# ----------------

CURRENT_MONTH=$(date '+%Y-%m')
LAST_MONTH_RESET=""

if [ -f "$LAST_MONTH_FILE" ]; then
    LAST_MONTH_RESET=$(cat "$LAST_MONTH_FILE")
else
    date '+%Y-%m' > "$LAST_MONTH_FILE"
    LAST_MONTH_RESET="$CURRENT_MONTH"
fi

if [ "$CURRENT_MONTH" != "$LAST_MONTH_RESET" ] && [ -n "$LAST_MONTH_RESET" ]; then

    log "New month detected. Sending full monthly report for $LAST_MONTH_RESET."

    # Отправляем отчет за предыдущий месяц
    send_monthly_summary "$LAST_MONTH_RESET"

    # После отправки начинаем новый месяц
    reset_monthly_stats
fi


# ================================
#   MAIN — RUN IPERF3
# ================================

run_iperf_with_retries


# ================================
#   EXIT
# ================================

exit 0
