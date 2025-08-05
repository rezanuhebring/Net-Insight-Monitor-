#!/bin/bash
# Net-Insight Monitor Agent Script (Linux)
# V3 - FINAL PRODUCTION VERSION
# Includes WiFi signal monitoring and all previous features.

# --- Configuration & Setup ---
AGENT_CONFIG_FILE="/opt/sla_monitor/agent_config.env"
LOG_FILE="/var/log/internet_sla_monitor_agent.log"
LOCK_FILE="/tmp/sla_monitor_agent.lock"

# --- Helper Functions ---
log_message() { echo "$(date '+%Y-%m-%d %H:%M:%S %Z'): [$AGENT_IDENTIFIER] $1"; }

# --- Lock File Logic ---
if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    log_message "[LOCK] Previous instance is still running. Exiting."
    exit 1
fi
# Automatically remove the lock file when the script exits, for any reason.
trap 'rm -rf "$LOCK_FILE"' EXIT

# --- Source and Validate Configuration ---
if [ -f "$AGENT_CONFIG_FILE" ]; then set -a; source "$AGENT_CONFIG_FILE"; set +a; fi
DEFAULT_PING_HOSTS=("8.8.8.8" "1.1.1.1" "google.com")
PING_HOSTS=("${PING_HOSTS[@]:-${DEFAULT_PING_HOSTS[@]}}")
AGENT_IDENTIFIER="${AGENT_IDENTIFIER:-<UNIQUE_AGENT_ID>}"
AGENT_TYPE="${AGENT_TYPE:-ISP}"
CENTRAL_API_URL="${CENTRAL_API_URL:-http://<YOUR_CENTRAL_SERVER_IP>/api/submit_metrics.php}"
CENTRAL_API_KEY="${CENTRAL_API_KEY:-}"
PING_COUNT=${PING_COUNT:-10}
PING_TIMEOUT=${PING_TIMEOUT:-5}
DNS_CHECK_HOST="${DNS_CHECK_HOST:-www.google.com}"
DNS_SERVER_TO_QUERY="${DNS_SERVER_TO_QUERY:-}"
HTTP_CHECK_URL="${HTTP_CHECK_URL:-https://www.google.com}"
HTTP_TIMEOUT=${HTTP_TIMEOUT:-10}
ENABLE_PING=${ENABLE_PING:-true}
ENABLE_DNS=${ENABLE_DNS:-true}
ENABLE_HTTP=${ENABLE_HTTP:-true}
ENABLE_SPEEDTEST=${ENABLE_SPEEDTEST:-true}
ENABLE_WIFI=${ENABLE_WIFI:-true} # New feature flag for WiFi test
NETWORK_INTERFACE_TO_MONITOR="${NETWORK_INTERFACE_TO_MONITOR:-}"
SPEEDTEST_ARGS="${SPEEDTEST_ARGS:-}"

log_message "Starting Net-Insight Monitor Agent Script. Type: ${AGENT_TYPE}"

if [[ "$CENTRAL_API_URL" == *"YOUR_CENTRAL_SERVER_IP"* ]] || [ -z "$CENTRAL_API_URL" ]; then log_message "FATAL: CENTRAL_API_URL not configured in ${AGENT_CONFIG_FILE}. Exiting."; exit 1; fi
if [[ "$AGENT_IDENTIFIER" == *"<UNIQUE_AGENT_ID>"* ]] || [ -z "$AGENT_IDENTIFIER" ]; then log_message "FATAL: AGENT_IDENTIFIER not configured in ${AGENT_CONFIG_FILE}. Exiting."; exit 1; fi
if [ ${#PING_HOSTS[@]} -eq 0 ]; then log_message "WARN: PING_HOSTS array not defined in ${AGENT_CONFIG_FILE}. Disabling ping test for this run."; ENABLE_PING=false; fi

# --- Fetch Profile & Thresholds from Central Server ---
CENTRAL_PROFILE_CONFIG_URL="${CENTRAL_API_URL/submit_metrics.php/get_profile_config.php}?agent_id=${AGENT_IDENTIFIER}"
# Add the API key header for authenticated access to the config endpoint
_profile_json_from_central=$(curl -s -m 10 -G --header "X-API-KEY: ${CENTRAL_API_KEY}" "$CENTRAL_PROFILE_CONFIG_URL")
if [ -n "$_profile_json_from_central" ] && echo "$_profile_json_from_central" | jq -e . > /dev/null 2>&1; then
    log_message "Successfully fetched profile config from central server."
    RTT_THRESHOLD_DEGRADED=$(echo "$_profile_json_from_central" | jq -r ".rtt_degraded // 100")
    RTT_THRESHOLD_POOR=$(echo "$_profile_json_from_central" | jq -r ".rtt_poor // 250")
    LOSS_THRESHOLD_DEGRADED=$(echo "$_profile_json_from_central" | jq -r ".loss_degraded // 2")
    LOSS_THRESHOLD_POOR=$(echo "$_profile_json_from_central" | jq -r ".loss_poor // 10")
    PING_JITTER_THRESHOLD_DEGRADED=$(echo "$_profile_json_from_central" | jq -r ".ping_jitter_degraded // 30")
    PING_JITTER_THRESHOLD_POOR=$(echo "$_profile_json_from_central" | jq -r ".ping_jitter_poor // 50")
    DNS_TIME_THRESHOLD_DEGRADED=$(echo "$_profile_json_from_central" | jq -r ".dns_time_degraded // 300")
    DNS_TIME_THRESHOLD_POOR=$(echo "$_profile_json_from_central" | jq -r ".dns_time_poor // 800")
    HTTP_TIME_THRESHOLD_DEGRADED=$(echo "$_profile_json_from_central" | jq -r ".http_time_degraded // 1.0")
    HTTP_TIME_THRESHOLD_POOR=$(echo "$_profile_json_from_central" | jq -r ".http_time_poor // 2.5")
    SPEEDTEST_DL_THRESHOLD_DEGRADED=$(echo "$_profile_json_from_central" | jq -r ".speedtest_dl_degraded // 60")
    SPEEDTEST_DL_THRESHOLD_POOR=$(echo "$_profile_json_from_central" | jq -r ".speedtest_dl_poor // 30")
    SPEEDTEST_UL_THRESHOLD_DEGRADED=$(echo "$_profile_json_from_central" | jq -r ".speedtest_ul_degraded // 20")
    SPEEDTEST_UL_THRESHOLD_POOR=$(echo "$_profile_json_from_central" | jq -r ".speedtest_ul_poor // 5")
else
    log_message "WARN: Failed to fetch profile config. Using hardcoded script defaults for thresholds."
    RTT_THRESHOLD_DEGRADED=100; RTT_THRESHOLD_POOR=250; LOSS_THRESHOLD_DEGRADED=2; LOSS_THRESHOLD_POOR=10; PING_JITTER_THRESHOLD_DEGRADED=30; PING_JITTER_THRESHOLD_POOR=50; DNS_TIME_THRESHOLD_DEGRADED=300; DNS_TIME_THRESHOLD_POOR=800; HTTP_TIME_THRESHOLD_DEGRADED=1.0; HTTP_TIME_THRESHOLD_POOR=2.5; SPEEDTEST_DL_THRESHOLD_DEGRADED=60; SPEEDTEST_DL_THRESHOLD_POOR=30; SPEEDTEST_UL_THRESHOLD_DEGRADED=20; SPEEDTEST_UL_THRESHOLD_POOR=5;
fi

# Auto-detect speedtest command.
SPEEDTEST_COMMAND_PATH="";
if command -v speedtest &>/dev/null; then SPEEDTEST_COMMAND_PATH=$(command -v speedtest);
elif command -v speedtest-cli &>/dev/null; then SPEEDTEST_COMMAND_PATH=$(command -v speedtest-cli); fi

# --- Main Logic ---
LOG_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
AGENT_SOURCE_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}' 2>/dev/null || hostname -I | awk '{print $1}')
AGENT_HOSTNAME_LOCAL=$(hostname -s)
declare -A results_map

# --- PING TESTS ---
if [ "$ENABLE_PING" = true ]; then
    log_message "Performing ping tests..."; ping_interface_arg=""; if [ -n "$NETWORK_INTERFACE_TO_MONITOR" ]; then ping_interface_arg="-I $NETWORK_INTERFACE_TO_MONITOR"; fi
    total_rtt_sum=0.0; total_loss_sum=0; total_jitter_sum=0.0; ping_targets_up=0
    for host in "${PING_HOSTS[@]}"; do
        ping_output=$(sudo LANG=C ping ${ping_interface_arg} -c "$PING_COUNT" -W "$PING_TIMEOUT" -q "$host" 2>&1)
        if [ $? -eq 0 ]; then
            log_message "Ping to $host: SUCCESS"; packet_loss=$(echo "$ping_output" | grep -oP '\d+(?=% packet loss)'); rtt_line=$(echo "$ping_output" | grep 'rtt min/avg/max/mdev'); avg_rtt=$(echo "$rtt_line" | cut -d'=' -f2 | cut -d'/' -f2); avg_jitter=$(echo "$rtt_line" | cut -d'=' -f2 | cut -d'/' -f4 | sed 's/\s*ms//');
            ((ping_targets_up++)); total_rtt_sum=$(awk "BEGIN {print $total_rtt_sum + $avg_rtt}"); if [[ "$avg_jitter" =~ ^[0-9.]+$ ]]; then total_jitter_sum=$(awk "BEGIN {print $total_jitter_sum + $avg_jitter}"); fi; total_loss_sum=$((total_loss_sum + packet_loss));
        else
            log_message "Ping to $host: FAIL"
        fi
    done
    if [ "$ping_targets_up" -gt 0 ]; then results_map[ping_status]="UP"; results_map[ping_rtt]=$(awk "BEGIN {printf \"%.2f\", $total_rtt_sum / $ping_targets_up}"); results_map[ping_jitter]=$(awk "BEGIN {printf \"%.2f\", $total_jitter_sum / $ping_targets_up}"); results_map[ping_loss]=$(awk "BEGIN {printf \"%.1f\", $total_loss_sum / ${#PING_HOSTS[@]}}");
    else results_map[ping_status]="DOWN"; fi
fi

# --- DNS RESOLUTION TEST ---
if [ "$ENABLE_DNS" = true ]; then
    log_message "Performing DNS resolution test..."; source_ip_arg_for_dig=""; if [ -n "$NETWORK_INTERFACE_TO_MONITOR" ]; then _source_ip_agent=$(ip -4 addr show "$NETWORK_INTERFACE_TO_MONITOR" | grep -oP 'inet \K[\d.]+'); if [ -n "$_source_ip_agent" ]; then source_ip_arg_for_dig="+source=$_source_ip_agent"; fi; fi; dig_server_arg=""; if [ -n "$DNS_SERVER_TO_QUERY" ]; then dig_server_arg="@${DNS_SERVER_TO_QUERY}"; fi;
    start_time_dns=$(date +%s.%N); dns_output=$(dig +short +time=2 +tries=1 $source_ip_arg_for_dig $dig_server_arg "$DNS_CHECK_HOST" 2>&1);
    if [ $? -eq 0 ] && [ -n "$dns_output" ]; then end_time_dns=$(date +%s.%N); results_map[dns_status]="OK"; results_map[dns_time]=$(awk "BEGIN {printf \"%.0f\", ($end_time_dns - $start_time_dns) * 1000}"); else results_map[dns_status]="FAILED"; fi
fi

# --- HTTP CHECK ---
if [ "$ENABLE_HTTP" = true ]; then
    log_message "Performing HTTP check..."; interface_arg=""; if [ -n "$NETWORK_INTERFACE_TO_MONITOR" ]; then interface_arg="--interface $NETWORK_INTERFACE_TO_MONITOR"; fi
    curl_output_stats=$(curl ${interface_arg} -L -s -o /dev/null -w "http_code=%{http_code}\ntime_total=%{time_total}" --max-time "$HTTP_TIMEOUT" "$HTTP_CHECK_URL");
    if [ $? -eq 0 ]; then
        results_map[http_code]=$(echo "$curl_output_stats" | grep "http_code" | cut -d'=' -f2); results_map[http_time]=$(echo "$curl_output_stats" | grep "time_total" | cut -d'=' -f2 | sed 's/,/./');
        if [[ "${results_map[http_code]}" -ge 200 && "${results_map[http_code]}" -lt 400 ]]; then results_map[http_status]="OK"; else results_map[http_status]="ERROR_CODE"; fi
    else results_map[http_status]="FAILED_REQUEST"; fi
fi

# --- SPEEDTEST ---
if [ "$ENABLE_SPEEDTEST" = true ]; then
    if [ -n "$SPEEDTEST_COMMAND_PATH" ]; then
        log_message "Performing speedtest with '$SPEEDTEST_COMMAND_PATH' and args '$SPEEDTEST_ARGS'..."; speedtest_interface_arg=""; if [ -n "$NETWORK_INTERFACE_TO_MONITOR" ]; then _source_ip_agent=$(ip -4 addr show "$NETWORK_INTERFACE_TO_MONITOR" | grep -oP 'inet \K[\d.]+'); if [ -n "$_source_ip_agent" ]; then if [[ "$SPEEDTEST_ARGS" == *"--source"* ]]; then speedtest_interface_arg="--source $_source_ip_agent"; elif [[ "$SPEEDTEST_ARGS" == *"--interface"* ]]; then speedtest_interface_arg="--interface $NETWORK_INTERFACE_TO_MONITOR"; fi; fi; fi;
        speedtest_json_output=$(timeout 120s $SPEEDTEST_COMMAND_PATH $SPEEDTEST_ARGS $speedtest_interface_arg);
        if [ $? -eq 0 ] && echo "$speedtest_json_output" | jq -e . > /dev/null 2>&1; then
            if echo "$speedtest_json_output" | jq -e '.download.bandwidth' > /dev/null 2>&1; then
                log_message "Parsing speedtest output as Ookla JSON format."; dl_bytes_per_sec=$(echo "$speedtest_json_output" | jq -r '.download.bandwidth // 0'); ul_bytes_per_sec=$(echo "$speedtest_json_output" | jq -r '.upload.bandwidth // 0'); results_map[st_dl]=$(awk "BEGIN {printf \"%.2f\", $dl_bytes_per_sec * 8 / 1000000}"); results_map[st_ul]=$(awk "BEGIN {printf \"%.2f\", $ul_bytes_per_sec * 8 / 1000000}"); results_map[st_ping]=$(echo "$speedtest_json_output" | jq -r '.ping.latency // "null"'); results_map[st_jitter]=$(echo "$speedtest_json_output" | jq -r '.ping.jitter // "null"'); results_map[st_status]="COMPLETED";
            elif echo "$speedtest_json_output" | jq -e '.download' > /dev/null 2>&1; then
                log_message "Parsing speedtest output as community speedtest-cli JSON format."; st_dl_bps=$(echo "$speedtest_json_output" | jq -r '.download // 0'); st_ul_bps=$(echo "$speedtest_json_output" | jq -r '.upload // 0'); results_map[st_dl]=$(awk "BEGIN {printf \"%.2f\", $st_dl_bps / 1000000}"); results_map[st_ul]=$(awk "BEGIN {printf \"%.2f\", $st_ul_bps / 1000000}"); results_map[st_ping]=$(echo "$speedtest_json_output" | jq -r '.ping // "null"'); results_map[st_jitter]="null"; results_map[st_status]="COMPLETED";
            else log_message "Speedtest FAILED: JSON format not recognized."; results_map[st_status]="FAILED_PARSE"; fi
        else log_message "Speedtest FAILED: Command failed or produced non-JSON output."; results_map[st_status]="FAILED_EXEC"; fi
    else log_message "Speedtest SKIPPED: No speedtest command found."; results_map[st_status]="SKIPPED_NO_CMD"; fi
fi

# --- NEW: WIFI SIGNAL STRENGTH ---
if [ "$ENABLE_WIFI" = true ]; then
    log_message "Performing WiFi signal test..."
    if command -v nmcli &> /dev/null; then
        # Use nmcli as it's the modern standard and provides all necessary details.
        # We ask for the fields we need in one go to be efficient.
        wifi_details=$(nmcli -g IN-USE,SSID,BSSID,SIGNAL,CHAN,FREQ,RATE,SECURITY,WPA-FLAGS,RSN-FLAGS dev wifi list | grep '^*' | head -1)
        if [ -n "$wifi_details" ]; then
            # Safely parse the colon-delimited output from nmcli
            IFS=':' read -r _ in_use ssid bssid signal chan freq rate security wpa_flags rsn_flags <<<"$wifi_details"
            
            results_map[wifi_percent]=$signal
            results_map[wifi_ssid]=$ssid
            results_map[wifi_bssid]=$bssid
            results_map[wifi_channel]=$chan
            
            # Determine frequency band
            if (( $(echo "$freq" | sed 's/\s*MHz//' | cut -d' ' -f1) > 5000 )); then
                results_map[wifi_frequency_band]="5 GHz"
            else
                results_map[wifi_frequency_band]="2.4 GHz"
            fi

            # Determine radio type from the bit rate
            rate_num=$(echo "$rate" | sed 's/\s*Mbit\/s//' | cut -d' ' -f1)
            if (( rate_num > 866 )); then results_map[wifi_radio_type]="802.11ac/ax (Wi-Fi 5/6)";
            elif (( rate_num > 300 )); then results_map[wifi_radio_type]="802.11n (Wi-Fi 4)";
            else results_map[wifi_radio_type]="802.11g/a"; fi

            # Determine authentication type
            auth="Unknown"
            if [[ -n "$security" ]]; then
                if [[ "$security" == *"WPA3"* ]]; then auth="WPA3";
                elif [[ "$security" == *"WPA2"* ]]; then auth="WPA2";
                elif [[ "$security" == *"WPA1"* ]]; then auth="WPA1";
                elif [[ "$security" == *"WEP"* ]]; then auth="WEP";
                else auth=$security; fi
                if [[ "$wpa_flags" == *"psk"* || "$rsn_flags" == *"psk"* ]]; then auth+=" (Personal)";
                elif [[ "$wpa_flags" != "none" || "$rsn_flags" != "none" ]]; then auth+=" (Enterprise)"; fi
            else auth="Open"; fi
            results_map[wifi_authentication]=$auth

            log_message "WiFi Details (nmcli): SSID='$ssid', BSSID='$bssid', Signal=$signal%, Chan=$chan, Freq=${results_map[wifi_frequency_band]}, Auth=$auth"

            # Fallback for dBm if possible, as nmcli signal is just a percentage
            if command -v iwconfig &> /dev/null;
            then
                wifi_interface=$(iwconfig 2>/dev/null | grep "ESSID:\"$ssid\"" | grep -o '^[a-zA-Z0-9]*' | head -1)
                if [ -n "$wifi_interface" ]; then
                    dbm_val=$(iwconfig $wifi_interface | grep -o 'Signal level=[-0-9]* dBm' | grep -o '[-0-9]*')
                    if [ -n "$dbm_val" ]; then results_map[wifi_dbm]=$dbm_val; fi
                fi
            fi
        else
            log_message "WiFi test: Not connected to a WiFi network (nmcli)."
        fi
    else
        log_message "WiFi test SKIPPED: nmcli command not found. Cannot collect detailed WiFi metrics."
    fi
fi



# --- DETAILED HEALTH SUMMARY & SLA CALCULATION ---
log_message "Calculating health summary..."
health_summary="UNKNOWN"; sla_met_interval=0; is_greater() { awk -v n1="$1" -v n2="$2" 'BEGIN {exit !(n1 > n2)}'; };
rtt_val=${results_map[ping_rtt]:-9999}; loss_val=${results_map[ping_loss]:-100}; jitter_val=${results_map[ping_jitter]:-999}; dns_val=${results_map[dns_time]:-99999}; http_val=${results_map[http_time]:-999}; dl_val=${results_map[st_dl]:-0}; ul_val=${results_map[st_ul]:-0};
if [ "${results_map[ping_status]}" == "DOWN" ]; then health_summary="CONNECTIVITY_DOWN";
elif [ "${results_map[dns_status]}" == "FAILED" ] || [ "${results_map[http_status]}" == "FAILED_REQUEST" ]; then health_summary="CRITICAL_SERVICE_FAILURE";
else
    is_poor=false; is_degraded=false;
    if is_greater "$rtt_val" "$RTT_THRESHOLD_POOR" || is_greater "$loss_val" "$LOSS_THRESHOLD_POOR" || is_greater "$jitter_val" "$PING_JITTER_THRESHOLD_POOR" || is_greater "$dns_val" "$DNS_TIME_THRESHOLD_POOR" || is_greater "$http_val" "$HTTP_TIME_THRESHOLD_POOR"; then is_poor=true; fi
    if [ "${results_map[st_status]}" == "COMPLETED" ]; then if is_greater "$SPEEDTEST_DL_THRESHOLD_POOR" "$dl_val" || is_greater "$SPEEDTEST_UL_THRESHOLD_POOR" "$ul_val"; then is_poor=true; fi; fi
    if [ "$is_poor" = false ]; then
        if is_greater "$rtt_val" "$RTT_THRESHOLD_DEGRADED" || is_greater "$loss_val" "$LOSS_THRESHOLD_DEGRADED" || is_greater "$jitter_val" "$PING_JITTER_THRESHOLD_DEGRADED" || is_greater "$dns_val" "$DNS_TIME_THRESHOLD_DEGRADED" || is_greater "$http_val" "$HTTP_TIME_THRESHOLD_DEGRADED"; then is_degraded=true; fi
        if [ "${results_map[st_status]}" == "COMPLETED" ]; then if is_greater "$SPEEDTEST_DL_THRESHOLD_DEGRADED" "$dl_val" || is_greater "$SPEEDTEST_UL_THRESHOLD_DEGRADED" "$ul_val"; then is_degraded=true; fi; fi
    fi
    if [ "$is_poor" = true ]; then health_summary="POOR_PERFORMANCE"; elif [ "$is_degraded" = true ]; then health_summary="DEGRADED_PERFORMANCE"; else health_summary="GOOD_PERFORMANCE"; fi
fi
if [ "$health_summary" == "GOOD_PERFORMANCE" ]; then sla_met_interval=1; fi
log_message "Health Summary: $health_summary"
results_map[detailed_health_summary]="$health_summary"
results_map[current_sla_met_status]=$(if [ $sla_met_interval -eq 1 ]; then echo "MET"; else echo "NOT_MET"; fi)

# --- Construct Final JSON Payload ---
log_message "Constructing final JSON payload..."
payload=$(jq -n \
    --arg     timestamp                  "$LOG_DATE" \
    --arg     agent_identifier           "$AGENT_IDENTIFIER" \
    --arg     agent_type                 "${AGENT_TYPE:-ISP}" \
    --arg     agent_hostname             "$AGENT_HOSTNAME_LOCAL" \
    --arg     agent_source_ip            "$AGENT_SOURCE_IP" \
    --arg     detailed_health_summary    "${results_map[detailed_health_summary]}" \
    --arg     current_sla_met_status     "${results_map[current_sla_met_status]}" \
    --argjson ping_summary               "$(jq -n --arg status "${results_map[ping_status]:-N/A}" --arg rtt "${results_map[ping_rtt]:-null}" --arg loss "${results_map[ping_loss]:-null}" --arg jitter "${results_map[ping_jitter]:-null}" '{status: $status, average_rtt_ms: ($rtt | tonumber? // null), average_packet_loss_percent: ($loss | tonumber? // null), average_jitter_ms: ($jitter | tonumber? // null)}')" \
    --argjson dns_resolution             "$(jq -n --arg status "${results_map[dns_status]:-N/A}" --arg time "${results_map[dns_time]:-null}" '{status: $status, resolve_time_ms: ($time | tonumber? // null)}')" \
    --argjson http_check                 "$(jq -n --arg status "${results_map[http_status]:-N/A}" --arg code "${results_map[http_code]:-null}" --arg time "${results_map[http_time]:-null}" '{status: $status, response_code: ($code | tonumber? // null), total_time_s: ($time | tonumber? // null)}')" \
    --argjson speed_test                 "$(jq -n --arg status "${results_map[st_status]:-SKIPPED}" --arg dl "${results_map[st_dl]:-null}" --arg ul "${results_map[st_ul]:-null}" --arg ping "${results_map[st_ping]:-null}" --arg jitter "${results_map[st_jitter]:-null}" '{status: $status, download_mbps: ($dl | tonumber? // null), upload_mbps: ($ul | tonumber? // null), ping_ms: ($ping | tonumber? // null), jitter_ms: ($jitter | tonumber? // null)}' )" \
    --argjson wifi_summary               "$(jq -n --arg dbm "${results_map[wifi_dbm]:-null}" --arg perc "${results_map[wifi_percent]:-null}" --arg ssid "${results_map[wifi_ssid]:-null}" --arg bssid "${results_map[wifi_bssid]:-null}" --arg chan "${results_map[wifi_channel]:-null}" --arg freq "${results_map[wifi_frequency_band]:-null}" --arg radio "${results_map[wifi_radio_type]:-null}" --arg auth "${results_map[wifi_authentication]:-null}" '{signal_dbm: ($dbm | tonumber? // null), signal_percent: ($perc | tonumber? // null), ssid: $ssid, bssid: $bssid, channel: ($chan | tonumber? // null), frequency_band: $freq, radio_type: $radio, authentication: $auth}')" \
    '$ARGS.named'
)

if ! echo "$payload" | jq . > /dev/null; then log_message "FATAL: Agent failed to generate valid final JSON. Aborting submission."; exit 1; fi

# --- Submit Data to Central API ---
log_message "Submitting data to central API: $CENTRAL_API_URL"
curl_headers=("-H" "Content-Type: application/json")
if [ -n "$CENTRAL_API_KEY" ]; then
    curl_headers+=("-H" "X-API-KEY: $CENTRAL_API_KEY")
else
    log_message "WARN: CENTRAL_API_KEY is not set. Submission will likely be rejected."
fi
api_response_file=$(mktemp); api_http_code=$(curl --silent --show-error --fail "${curl_headers[@]}" -X POST -d "$payload" "$CENTRAL_API_URL" --output "$api_response_file" --write-out "%{http_code}"); api_curl_exit_code=$?; api_response_body=$(cat "$api_response_file"); rm -f "$api_response_file"
if [ "$api_curl_exit_code" -eq 0 ]; then log_message "Data successfully submitted. HTTP code: $api_http_code. Response: $api_response_body"; else log_message "ERROR: Failed to submit data to central API. Curl exit: $api_curl_exit_code, HTTP code: $api_http_code. Response: $api_response_body"; fi

log_message "Agent monitor script finished."
exit 0