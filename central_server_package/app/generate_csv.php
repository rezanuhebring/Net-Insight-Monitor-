<?php
// generate_csv.php - FINAL PRODUCTION VERSION
// This script dynamically includes the jitter column only if data exists.

// --- Configuration ---
$db_file = '/opt/sla_monitor/central_sla_data.sqlite';

// --- Security and Input Validation ---
if (!isset($_GET['isp_id']) || !filter_var($_GET['isp_id'], FILTER_VALIDATE_INT)) {
    http_response_code(400); // Bad Request
    die("Error: Invalid or missing Agent ID provided.");
}
$isp_id = (int)$_GET['isp_id'];

try {
    // --- Database Connection (Read-Only) ---
    if (!file_exists($db_file)) {
        throw new Exception("Central database file not found.");
    }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READONLY);
    if (!$db) {
        throw new Exception("Could not connect to the central database.");
    }

    // --- Get Agent Name for Filename ---
    $profile_stmt = $db->prepare("SELECT agent_name FROM isp_profiles WHERE id = :id");
    $profile_stmt->bindValue(':id', $isp_id, SQLITE3_INTEGER);
    $profile_result = $profile_stmt->execute()->fetchArray(SQLITE3_ASSOC);
    $agent_name = $profile_result ? preg_replace('/[^a-zA-Z0-9_]/', '_', $profile_result['agent_name']) : 'unknown_agent';
    $filename = "sla_history_{$agent_name}.csv";
    $profile_stmt->close();

    // --- Set HTTP Headers for CSV Download ---
    header('Content-Type: text/csv; charset=utf-8');
    header('Content-Disposition: attachment; filename="' . $filename . '"');
    $output = fopen('php://output', 'w');

    // --- Optimized: Check for Jitter Data Existence First ---
    // This query is lightweight and checks if there's any valid jitter data at all.
    $jitter_check_stmt = $db->prepare("SELECT 1 FROM sla_metrics WHERE isp_profile_id = :id AND speedtest_jitter_ms IS NOT NULL AND speedtest_jitter_ms != '' LIMIT 1");
    $jitter_check_stmt->bindValue(':id', $isp_id, SQLITE3_INTEGER);
    $has_jitter_data = (bool) $jitter_check_stmt->execute()->fetchArray();
    $jitter_check_stmt->close();

    // --- Optimized: Stream Data Row-by-Row ---
    $data_stmt = $db->prepare("SELECT * FROM sla_metrics WHERE isp_profile_id = :id ORDER BY timestamp ASC");
    $data_stmt->bindValue(':id', $isp_id, SQLITE3_INTEGER);
    $results = $data_stmt->execute();
    if (!$results) {
        throw new Exception("Failed to retrieve metrics for the agent.");
    }

    $is_first_row = true;
    while ($row = $results->fetchArray(SQLITE3_ASSOC)) {
        // On the first row, determine and write headers
        if ($is_first_row) {
            $headers = array_keys($row);
            if (!$has_jitter_data) {
                // If no jitter data exists anywhere, remove the column from the headers
                $headers = array_filter($headers, function($header) {
                    return $header !== 'speedtest_jitter_ms';
                });
            }
            fputcsv($output, $headers);
            $is_first_row = false;
        }

        // Prepare and write the data row
        if (!$has_jitter_data) {
            unset($row['speedtest_jitter_ms']);
        }
        fputcsv($output, $row);
    }

    // If the loop never ran (no data), write a message
    if ($is_first_row) {
        fputcsv($output, ['No data available for this agent.']);
    }

    // --- Clean up ---
    $data_stmt->close();
    $db->close();
    fclose($output);
    exit();

} catch (Exception $e) {
    // If something goes wrong, send an error response instead of a broken file
    http_response_code(500); // Internal Server Error
    header('Content-Type: text/plain'); // Reset content type
    die("Server Error: Could not generate the CSV file. Please check server logs. Details: " . $e->getMessage());
}
?>