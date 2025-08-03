<?php
// submit_metrics.php - Net-Insight-Monitor API Endpoint V3
// Handles API Key Authentication and accepts WiFi signal metrics.

ini_set('display_errors', 0);
ini_set('log_errors', 1);
ini_set('error_log', '/var/log/api.log'); // Log PHP errors to a dedicated file

// --- Configuration ---
// The DB path inside the container, as defined by the volume mount in setup.sh.
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

    if ($type === 'text') {
        // Sanitize text values to prevent stored XSS.
        return htmlspecialchars((string)$current, ENT_QUOTES, 'UTF-8');
    }

    return $type === 'float' ? (float)$current : ($type === 'int' ? (int)$current : $current);
}


// --- Main Logic ---
header("Content-Type: application/json");

// 1. API Key Authentication
$api_key = $_SERVER['HTTP_X_API_KEY'] ?? '';
if (empty($api_key)) {
    http_response_code(401); api_log("Authentication Error: API key missing from X-API-KEY header.");
    echo json_encode(['status' => 'error', 'message' => 'API key missing']);
    exit;
}

$db = null; $isp_profile_id = null;
try {
    if (!file_exists($db_file)) { throw new Exception("Database file not found at {$db_file}. Check setup script volumes."); }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READWRITE);
    $db->exec("PRAGMA journal_mode=WAL;");

    // Validate the API Key and get the profile ID
    $stmt_profile = $db->prepare("SELECT id FROM isp_profiles WHERE api_key = :api_key LIMIT 1");
    $stmt_profile->bindValue(':api_key', $api_key, SQLITE3_TEXT);
    $profile_row = $stmt_profile->execute()->fetchArray(SQLITE3_ASSOC);
    $stmt_profile->close();
    
    if (!$profile_row) {
        http_response_code(403); api_log("Authentication Error: Invalid API key provided.");
        echo json_encode(['status' => 'error', 'message' => 'Invalid API key']);
        exit;
    }
    $isp_profile_id = (int)$profile_row['id'];
    
    // 2. Process Input Data
    $input_data = json_decode(file_get_contents('php://input'), true);
    if (json_last_error() !== JSON_ERROR_NONE || !isset($input_data['timestamp'])) {
        http_response_code(400); api_log("Invalid JSON payload or missing timestamp.");
        echo json_encode(['status' => 'error', 'message' => 'Invalid JSON payload or missing timestamp.']);
        exit;
    }
    
    api_log("Authenticated metrics for profile ID: " . $isp_profile_id);
    $db->exec('BEGIN IMMEDIATE TRANSACTION');
    
    // 3. Update Profile 'last seen' information
    $update_stmt = $db->prepare("UPDATE isp_profiles SET last_heard_from = :now, last_reported_hostname = :hostname, last_reported_source_ip = :source_ip, agent_type = :agent_type WHERE id = :isp_id");
    $update_stmt->bindValue(':now', gmdate("Y-m-d\TH:i:s\Z"));
    $update_stmt->bindValue(':hostname', htmlspecialchars($input_data['agent_hostname'] ?? 'unknown', ENT_QUOTES, 'UTF-8'));
    $update_stmt->bindValue(':source_ip', filter_var($input_data['agent_source_ip'] ?? 'invalid', FILTER_VALIDATE_IP) ?: 'invalid');
    $update_stmt->bindValue(':agent_type', htmlspecialchars($input_data['agent_type'] ?? 'Client', ENT_QUOTES, 'UTF-8'));
    $update_stmt->bindValue(':isp_id', $isp_profile_id, SQLITE3_INTEGER);
    $update_stmt->execute();
    $update_stmt->close();
    
    // 4. Prepare Metrics for Insertion
    $sql = "INSERT OR IGNORE INTO sla_metrics (isp_profile_id, timestamp, overall_connectivity, avg_rtt_ms, avg_loss_percent, avg_jitter_ms, dns_status, dns_resolve_time_ms, http_status, http_response_code, http_total_time_s, speedtest_status, speedtest_download_mbps, speedtest_upload_mbps, speedtest_ping_ms, speedtest_jitter_ms, wifi_signal_percent, wifi_signal_dbm, detailed_health_summary, sla_met_interval) VALUES (:isp_id, :ts, :conn, :rtt, :loss, :jitter, :dns_stat, :dns_time, :http_stat, :http_code, :http_time, :st_stat, :st_dl, :st_ul, :st_ping, :st_jit, :wifi_perc, :wifi_dbm, :health, :sla_met)";
    $stmt = $db->prepare($sql);

    // Bind all values
    $stmt->bindValue(':isp_id', $isp_profile_id, SQLITE3_INTEGER);
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
    // The get_nested_value function now handles sanitization for 'text' type.
    $stmt->bindValue(':health', get_nested_value($input_data, ['detailed_health_summary']) ?? 'UNKNOWN');
    $stmt->bindValue(':sla_met', (get_nested_value($input_data, ['current_sla_met_status']) === 'MET' ? 1 : 0), SQLITE3_INTEGER);

    // 5. Execute and Finalize
    if ($stmt->execute()) {
        $db->exec('COMMIT');
        api_log("OK: Metrics inserted for profile ID: {$isp_profile_id}");
        echo json_encode(['status' => 'success', 'message' => 'Metrics received.']);
    } else {
        throw new Exception("Failed to insert metrics data: " . $db->lastErrorMsg());
    }
    
} catch (Exception $e) {
    if ($db) { $db->exec('ROLLBACK'); }
    api_log("FATAL ERROR for profile ID {$isp_profile_id}: " . $e->getMessage());
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'Server error: ' . $e->getMessage()]);
} finally {
    if ($db) { $db->close(); }
}
?>