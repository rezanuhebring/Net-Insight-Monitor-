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

// 1. API Key Authentication
$api_key = $_SERVER['HTTP_X_API_KEY'] ?? '';
if (empty($api_key)) {
    http_response_code(401);
    api_log("Authentication Error: API key missing from X-API-KEY header.");
    echo json_encode(['status' => 'error', 'message' => 'API key missing']);
    exit;
}

$db = null; $agent_identifier_for_log = 'unknown';
try {
    // 2. Connect to Database and Fetch Profile
    if (!file_exists($db_file)) { throw new Exception("Database file not found at {$db_file}."); }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READONLY);
    
    // Validate the API Key and get the profile info
    $stmt = $db->prepare("SELECT id, agent_name, agent_identifier FROM isp_profiles WHERE api_key = :api_key LIMIT 1");
    $stmt->bindValue(':api_key', $api_key, SQLITE3_TEXT);
    $profile = $stmt->execute()->fetchArray(SQLITE3_ASSOC);
    $stmt->close();

    if (!$profile) {
        http_response_code(404); // Not Found
        api_log("Authentication Error: Invalid API key provided, profile not found.");
        echo json_encode(['status' => 'error', 'message' => 'Agent profile not found for the provided API key.']);
        exit;
    }

    $agent_identifier_for_log = $profile['agent_identifier']; // For logging context
    api_log("OK: Served config to agent '{$agent_identifier_for_log}' (Profile ID: {$profile['id']})");

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
    api_log("FATAL ERROR for agent '{$agent_identifier_for_log}': " . $e->getMessage());
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'An internal server error occurred.']);
} finally {
    if ($db) {
        $db->close();
    }
}
?>