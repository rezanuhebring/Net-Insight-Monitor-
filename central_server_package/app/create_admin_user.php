<?php
// --- Configuration ---
$admin_username = 'admin';
$admin_password = 'ChooseAStrongPasswordNow!'; // <-- IMPORTANT: CHANGE THIS!

// --- Script ---
header('Content-Type: text/html; charset=utf-8');
$db_path = '/opt/sla_monitor/app_data/net_insight_monitor.sqlite';
$message = '';
$color = 'red';

try {
    if (!file_exists($db_path)) { throw new Exception("Database file not found. Ensure the server is running."); }
    $pdo = new PDO('sqlite:' . $db_path);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $password_hash = password_hash($admin_password, PASSWORD_ARGON2ID);

    $stmt = $pdo->prepare("SELECT id FROM users WHERE username = ?");
    $stmt->execute([$admin_username]);
    if ($stmt->fetch()) {
        $message = "User '{$admin_username}' already exists. No action taken.";
        $color = "orange";
    } else {
        $stmt = $pdo->prepare("INSERT INTO users (username, password_hash) VALUES (?, ?)");
        $stmt->execute([$admin_username, $password_hash]);
        $message = "Successfully created admin user '{$admin_username}'.";
        $color = "green";
    }
} catch (Exception $e) {
    $message = "Error: " . $e->getMessage();
}
?>
<!DOCTYPE html><html><body style="font-family: sans-serif; text-align: center; padding-top: 50px;">
<div style="max-width: 600px; margin: auto; padding: 2rem; border: 1px solid #ccc; border-radius: 8px;">
    <h1 style="color: <?php echo $color; ?>;"><?php echo $message; ?></h1>
    <h2 style="color: #d93025; font-weight: bold;">CRITICAL: Delete this file (create_admin_user.php) from the server immediately!</h2>
</div>
</body></html>