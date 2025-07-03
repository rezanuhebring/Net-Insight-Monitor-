<?php
// get_profile_config.php - Net-Insight-Monitor API Endpoint
// V3 - Provides centralized configuration thresholds to agents.

ini_set('display_errors', 0);
ini_set('log_errors', 1);
ini_set('error_log', '/var/log/api.log'); // Log PHP errors to a dedicated file

// --- Configuration ---
$db_file = '/opt/sla_monitor/app_data/net_insight_monitor.sqlite';
$log_file_api = '/var/log/api.log';

// --- Helper Functions ---
function api_log($message) {
    file_put_contents($GLOBALS['log_file_api'], date('[Y-m-d H:i:s T] ') . '[GetProfileConfig] ' . $message . PHP_EOL, FILE_APPEND);
}


// --- Main Logic ---
header("Content-Type: application/json");

// 1. Get and Validate Input
$agent_identifier = trim($_GET['agent_id'] ?? '');
if (empty($agent_identifier)) {
    http_response_code(400); // Bad Request
    api_log("Request Error: agent_id parameter was missing or empty.");
    echo json_encode(['status' => 'error', 'message' => 'agent_id parameter is required.']);
    exit;
}

$db = null;
try {
    // 2. Connect to Database and Verify Agent Exists
    if (!file_exists($db_file)) { throw new Exception("Database file not found at {$db_file}."); }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READONLY); // Use READONLY for safety
    
    $stmt = $db->prepare("SELECT id, agent_name FROM isp_profiles WHERE agent_identifier = :agent_id LIMIT 1");
    $stmt->bindValue(':agent_id', $agent_identifier, SQLITE3_TEXT);
    $profile = $stmt->execute()->fetchArray(SQLITE3_ASSOC);
    $stmt->close();

    if (!$profile) {
        http_response_code(404); // Not Found
        api_log("Request Info: Agent identifier not found in database: '{$agent_identifier}'");
        echo json_encode(['status' => 'error', 'message' => 'Agent profile not found.']);
        exit;
    }

    api_log("OK: Served config to agent '{$agent_identifier}' (Profile ID: {$profile['id']})");

    // 3. Define and Return the Configuration Payload
    // NOTE: For now, these are hardcoded. In the future, you could add columns
    // to the `isp_profiles` table and query them here for per-agent settings.
    $config_payload = [
        'status' => 'success',
        'agent_name' => $profile['agent_name'],

        // Performance Thresholds
        'rtt_degraded' => 100.0,
        'rtt_poor' => 250.0,
        
        'loss_degraded' => 2.0,
        'loss_poor' => 10.0,
        
        'ping_jitter_degraded' => 30.0,
        'ping_jitter_poor' => 50.0,
        
        'dns_time_degraded' => 300,
        'dns_time_poor' => 800,
        
        'http_time_degraded' => 1.0,
        'http_time_poor' => 2.5,
        
        'speedtest_dl_degraded' => 60.0,
        'speedtest_dl_poor' => 30.0,
        
        'speedtest_ul_degraded' => 20.0,
        'speedtest_ul_poor' => 5.0
    ];

    echo json_encode($config_payload, JSON_PRETTY_PRINT | JSON_NUMERIC_CHECK);

} catch (Exception $e) {
    api_log("FATAL ERROR for agent '{$agent_identifier}': " . $e->getMessage());
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'An internal server error occurred.']);
} finally {
    if ($db) {
        $db->close();
    }
}
?>