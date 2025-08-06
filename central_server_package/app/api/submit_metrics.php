<?php
// submit_metrics.php - Net-Insight-Monitor API Endpoint V4
// Handles API Key Authentication, Agent Registration, and accepts WiFi signal metrics.

ini_set('display_errors', 0);
ini_set('log_errors', 1);
ini_set('error_log', '/var/log/api.log');

// --- Configuration ---
$db_file = '/opt/sla_monitor/app_data/net_insight_monitor.sqlite';
$log_file_api = '/var/log/api.log';

// --- Helper Functions ---
function api_log($message) {
    file_put_contents($GLOBALS['log_file_api'], date('[Y-m-d H:i:s T] ') . '[SubmitMetrics] ' . $message . PHP_EOL, FILE_APPEND);
}

function get_nested_value($array, array $keys, $type = 'text') {
    $current = $array;
    foreach ($keys as $key) {
        if (!isset($current[$key])) return null;
        $current = $current[$key];
    }
    if ($current === 'N/A' || $current === '' || is_null($current)) return null;
    return $type === 'float' ? (float)$current : ($type === 'int' ? (int)$current : $current);
}

function initialize_database($db) {
    // Create agents table if it doesn't exist
    $db->exec("CREATE TABLE IF NOT EXISTS agents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        isp_profile_id INTEGER NOT NULL,
        agent_hostname TEXT NOT NULL,
        agent_source_ip TEXT,
        agent_type TEXT,
        first_seen TEXT NOT NULL,
        last_seen TEXT NOT NULL,
        UNIQUE(isp_profile_id, agent_hostname)
    )");

    // Add agent_id to sla_metrics if it doesn't exist
    $columns = $db->query("PRAGMA table_info(sla_metrics)");
    $agent_id_exists = false;
    while ($column = $columns->fetchArray(SQLITE3_ASSOC)) {
        if ($column['name'] === 'agent_id') {
            $agent_id_exists = true;
            break;
        }
    }
    if (!$agent_id_exists) {
        $db->exec("ALTER TABLE sla_metrics ADD COLUMN agent_id INTEGER");
        api_log("Database schema updated: Added 'agent_id' to 'sla_metrics' table.");
    }
}

// --- Main Logic ---
header("Content-Type: application/json");

$db = null;
try {
    if (!file_exists($db_file)) { throw new Exception("Database file not found at {$db_file}."); }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READWRITE);
    $db->exec("PRAGMA journal_mode=WAL;");
    
    initialize_database($db);

    // 1. API Key Authentication & Agent Identification
    $api_key = $_SERVER['HTTP_X_API_KEY'] ?? '';
    if (empty($api_key)) {
        http_response_code(401); api_log("Auth Error: Missing API key.");
        echo json_encode(['status' => 'error', 'message' => 'API key missing']);
        exit;
    }

    // Authenticate the key against a known valid key.
    // This can be the first profile's key or a dedicated one.
    $stmt_auth = $db->prepare("SELECT id FROM isp_profiles WHERE api_key = :api_key LIMIT 1");
    $stmt_auth->bindValue(':api_key', $api_key, SQLITE3_TEXT);
    $auth_profile = $stmt_auth->execute()->fetchArray(SQLITE3_ASSOC);
    $stmt_auth->close();

    if (!$auth_profile) {
        http_response_code(403); api_log("Auth Error: Invalid API key provided.");
        echo json_encode(['status' => 'error', 'message' => 'Invalid API key']);
        exit;
    }

    // 2. Process Input Data
    $input_data = json_decode(file_get_contents('php://input'), true);
    if (json_last_error() !== JSON_ERROR_NONE || !isset($input_data['timestamp'])) {
        http_response_code(400); api_log("Bad Request: Invalid JSON or missing timestamp.");
        echo json_encode(['status' => 'error', 'message' => 'Invalid JSON or missing timestamp.']);
        exit;
    }
    
    $agent_hostname = htmlspecialchars($input_data['agent_hostname'] ?? 'unknown', ENT_QUOTES, 'UTF-8');
    if ($agent_hostname === 'unknown') {
        http_response_code(400); api_log("Bad Request: Agent hostname is missing.");
        echo json_encode(['status' => 'error', 'message' => 'Agent hostname is required.']);
        exit;
    }
    
    $agent_identifier = htmlspecialchars($input_data['agent_identifier'] ?? $agent_hostname, ENT_QUOTES, 'UTF-8');
    $agent_type = htmlspecialchars($input_data['agent_type'] ?? 'Client', ENT_QUOTES, 'UTF-8');
    $now_utc = gmdate("Y-m-d\TH:i:s\Z");

    $db->exec('BEGIN IMMEDIATE TRANSACTION');

    // 3. Find or Create ISP Profile based on Agent Hostname
    $stmt_profile = $db->prepare("SELECT id FROM isp_profiles WHERE agent_name = :agent_name LIMIT 1");
    $stmt_profile->bindValue(':agent_name', $agent_hostname, SQLITE3_TEXT);
    $profile_row = $stmt_profile->execute()->fetchArray(SQLITE3_ASSOC);
    $stmt_profile->close();

    $isp_profile_id = null;
    if ($profile_row) {
        $isp_profile_id = (int)$profile_row['id'];
        // Update last heard from timestamp
        $update_profile_stmt = $db->prepare("UPDATE isp_profiles SET last_heard_from = :now, agent_type = :type WHERE id = :id");
        $update_profile_stmt->bindValue(':now', $now_utc, SQLITE3_TEXT);
        $update_profile_stmt->bindValue(':type', $agent_type, SQLITE3_TEXT);
        $update_profile_stmt->bindValue(':id', $isp_profile_id, SQLITE3_INTEGER);
        $update_profile_stmt->execute();
        $update_profile_stmt->close();
    } else {
        // Profile not found, create a new one
        api_log("Profile for '{$agent_hostname}' not found. Creating a new profile.");
        $insert_profile_stmt = $db->prepare(
            "INSERT INTO isp_profiles (agent_name, agent_identifier, agent_type, api_key, is_active, last_heard_from) 
             VALUES (:agent_name, :agent_identifier, :agent_type, :api_key, 1, :now)"
        );
        $insert_profile_stmt->bindValue(':agent_name', $agent_hostname, SQLITE3_TEXT);
        $insert_profile_stmt->bindValue(':agent_identifier', $agent_identifier, SQLITE3_TEXT);
        $insert_profile_stmt->bindValue(':agent_type', $agent_type, SQLITE3_TEXT);
        $insert_profile_stmt->bindValue(':api_key', $api_key, SQLITE3_TEXT); // Use the submitted key for the new profile
        $insert_profile_stmt->bindValue(':now', $now_utc, SQLITE3_TEXT);
        $insert_profile_stmt->execute();
        $isp_profile_id = $db->lastInsertRowID();
        $insert_profile_stmt->close();
        api_log("New profile created for '{$agent_hostname}' with ID {$isp_profile_id}.");
    }

    // 4. Register or Update Agent (in the 'agents' table)
    $agent_source_ip = filter_var($input_data['agent_source_ip'] ?? 'invalid', FILTER_VALIDATE_IP) ?: 'invalid';

    $stmt_agent = $db->prepare("SELECT id FROM agents WHERE isp_profile_id = :isp_id AND agent_hostname = :hostname");
    $stmt_agent->bindValue(':isp_id', $isp_profile_id, SQLITE3_INTEGER);
    $stmt_agent->bindValue(':hostname', $agent_hostname, SQLITE3_TEXT);
    $agent_row = $stmt_agent->execute()->fetchArray(SQLITE3_ASSOC);
    $stmt_agent->close();

    $agent_id = null;
    if ($agent_row) {
        $agent_id = (int)$agent_row['id'];
        $update_agent_stmt = $db->prepare("UPDATE agents SET last_seen = :now, agent_source_ip = :ip, agent_type = :type WHERE id = :id");
        $update_agent_stmt->bindValue(':now', $now_utc, SQLITE3_TEXT);
        $update_agent_stmt->bindValue(':ip', $agent_source_ip, SQLITE3_TEXT);
        $update_agent_stmt->bindValue(':type', $agent_type, SQLITE3_TEXT);
        $update_agent_stmt->bindValue(':id', $agent_id, SQLITE3_INTEGER);
        $update_agent_stmt->execute();
        $update_agent_stmt->close();
    } else {
        $insert_agent_stmt = $db->prepare("INSERT INTO agents (isp_profile_id, agent_hostname, agent_source_ip, agent_type, first_seen, last_seen) VALUES (:isp_id, :hostname, :ip, :type, :now, :now)");
        $insert_agent_stmt->bindValue(':isp_id', $isp_profile_id, SQLITE3_INTEGER);
        $insert_agent_stmt->bindValue(':hostname', $agent_hostname, SQLITE3_TEXT);
        $insert_agent_stmt->bindValue(':ip', $agent_source_ip, SQLITE3_TEXT);
        $insert_agent_stmt->bindValue(':type', $agent_type, SQLITE3_TEXT);
        $insert_agent_stmt->bindValue(':now', $now_utc, SQLITE3_TEXT);
        $insert_agent_stmt->execute();
        $agent_id = $db->lastInsertRowID();
        $insert_agent_stmt->close();
        api_log("New agent '{$agent_hostname}' registered for profile ID {$isp_profile_id} with agent ID {$agent_id}.");
    }

    // 4. Prepare Metrics for Insertion
    $sql = "INSERT OR IGNORE INTO sla_metrics (isp_profile_id, agent_id, timestamp, overall_connectivity, avg_rtt_ms, avg_loss_percent, avg_jitter_ms, dns_status, dns_resolve_time_ms, http_status, http_response_code, http_total_time_s, speedtest_status, speedtest_download_mbps, speedtest_upload_mbps, speedtest_ping_ms, speedtest_jitter_ms, wifi_signal_percent, wifi_signal_dbm, wifi_ssid, wifi_bssid, wifi_channel, wifi_frequency_band, wifi_radio_type, wifi_authentication, detailed_health_summary, sla_met_interval) VALUES (:isp_id, :agent_id, :ts, :conn, :rtt, :loss, :jitter, :dns_stat, :dns_time, :http_stat, :http_code, :http_time, :st_stat, :st_dl, :st_ul, :st_ping, :st_jit, :wifi_perc, :wifi_dbm, :wifi_ssid, :wifi_bssid, :wifi_chan, :wifi_freq, :wifi_radio, :wifi_auth, :health, :sla_met)";
    $stmt = $db->prepare($sql);

    // Bind all values
    $stmt->bindValue(':isp_id', $isp_profile_id, SQLITE3_INTEGER);
    $stmt->bindValue(':agent_id', $agent_id, SQLITE3_INTEGER);
    $stmt->bindValue(':ts', $input_data['timestamp'], SQLITE3_TEXT);
    $stmt->bindValue(':conn', get_nested_value($input_data, ['ping_summary', 'status']));
    $stmt->bindValue(':rtt', get_nested_value($input_data, ['ping_summary', 'average_rtt_ms'], 'float'), SQLITE3_FLOAT);
    $stmt->bindValue(':loss', get_nested_value($input_data, ['ping_summary', 'average_packet_loss_percent'], 'float'), SQLITE3_FLOAT);
    $stmt->bindValue(':jitter', get_nested_value($input_data, ['ping_summary', 'average_jitter_ms'], 'float'), SQLITE3_FLOAT);
    $stmt->bindValue(':dns_stat', get_nested_value($input_data, ['dns_resolution', 'status']));
    $stmt->bindValue(':dns_time', get_nested_value($input_data, ['dns_resolution', 'resolve_time_ms'], 'int'), SQLITE3_INTEGER);
    $stmt->bindValue(':http_stat', get_nested_value($input_data, ['http_check', 'status']));
    $stmt->bindValue(':http_code', get_nested_value($input_data, ['http_check', 'response_code'], 'int'), SQLITE3_INTEGER);
    $stmt->bindValue(':http_time', get_nested_value($input_data, ['http_check', 'total_time_s'], 'float'), SQLITE3_FLOAT);
    $stmt->bindValue(':st_stat', get_nested_value($input_data, ['speed_test', 'status']));
    $stmt->bindValue(':st_dl', get_nested_value($input_data, ['speed_test', 'download_mbps'], 'float'), SQLITE3_FLOAT);
    $stmt->bindValue(':st_ul', get_nested_value($input_data, ['speed_test', 'upload_mbps'], 'float'), SQLITE3_FLOAT);
    $stmt->bindValue(':st_ping', get_nested_value($input_data, ['speed_test', 'ping_ms'], 'float'), SQLITE3_FLOAT);
    $stmt->bindValue(':st_jit', get_nested_value($input_data, ['speed_test', 'jitter_ms'], 'float'), SQLITE3_FLOAT);
    $stmt->bindValue(':wifi_perc', get_nested_value($input_data, ['wifi_summary', 'signal_percent'], 'int'), SQLITE3_INTEGER);
    $stmt->bindValue(':wifi_dbm', get_nested_value($input_data, ['wifi_summary', 'signal_dbm'], 'int'), SQLITE3_INTEGER);
    $stmt->bindValue(':wifi_ssid', get_nested_value($input_data, ['wifi_summary', 'ssid']));
    $stmt->bindValue(':wifi_bssid', get_nested_value($input_data, ['wifi_summary', 'bssid']));
    $stmt->bindValue(':wifi_chan', get_nested_value($input_data, ['wifi_summary', 'channel'], 'int'), SQLITE3_INTEGER);
    $stmt->bindValue(':wifi_freq', get_nested_value($input_data, ['wifi_summary', 'frequency_band']));
    $stmt->bindValue(':wifi_radio', get_nested_value($input_data, ['wifi_summary', 'radio_type']));
    $stmt->bindValue(':wifi_auth', get_nested_value($input_data, ['wifi_summary', 'authentication']));
    $stmt->bindValue(':health', htmlspecialchars(get_nested_value($input_data, ['detailed_health_summary']) ?? 'UNKNOWN', ENT_QUOTES, 'UTF-8'));
    $stmt->bindValue(':sla_met', (get_nested_value($input_data, ['current_sla_met_status']) === 'MET' ? 1 : 0), SQLITE3_INTEGER);

    // 5. Execute and Finalize
    if ($stmt->execute()) {
        $db->exec('COMMIT');
        api_log("OK: Metrics from agent '{$agent_hostname}' (ID: {$agent_id}) inserted for profile ID {$isp_profile_id}.");
        echo json_encode(['status' => 'success', 'message' => 'Metrics received.']);
    } else {
        throw new Exception("Failed to insert metrics: " . $db->lastErrorMsg());
    }
    
} catch (Exception $e) {
    if ($db && $db->inTransaction()) { $db->exec('ROLLBACK'); }
    api_log("FATAL ERROR for profile ID {$isp_profile_id}: " . $e->getMessage());
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'Server error: ' . $e->getMessage()]);
} finally {
    if ($db) { $db->close(); }
}
?>
