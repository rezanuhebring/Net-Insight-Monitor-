<?php
// --- Configuration ---
$admin_username = 'admin';
$db_path = '/opt/sla_monitor/app_data/net_insight_monitor.sqlite';
$message = '';
$color = 'red';
$show_form = true;

// --- Password Strength Check ---
function is_password_strong($password) {
    // Requirements: 8+ chars, 1 uppercase, 1 lowercase, 1 number, 1 special char.
    return strlen($password) >= 8 &&
           preg_match('/[A-Z]/', $password) &&
           preg_match('/[a-z]/', $password) &&
           preg_match('/[0-9]/', $password) &&
           preg_match('/[\W_]/', $password); // \W is any non-word character
}

// --- Main Logic ---
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $admin_password = $_POST['password'] ?? '';
    $password_confirm = $_POST['password_confirm'] ?? '';

    if (empty($admin_password)) {
        $message = "Password cannot be empty.";
    } elseif ($admin_password !== $password_confirm) {
        $message = "Passwords do not match.";
    } elseif (!is_password_strong($admin_password)) {
        $message = "Password is not strong enough. It must be at least 8 characters long and include an uppercase letter, a lowercase letter, a number, and a special character.";
    } else {
        try {
            if (!file_exists($db_path)) { throw new Exception("Database file not found. Ensure the server is running."); }
            $pdo = new PDO('sqlite:' . $db_path);
            $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

            $stmt = $pdo->prepare("SELECT id FROM users WHERE username = ?");
            $stmt->execute([$admin_username]);
            if ($stmt->fetch()) {
                $message = "User '{$admin_username}' already exists. No action taken.";
                $color = "orange";
            } else {
                $password_hash = password_hash($admin_password, PASSWORD_ARGON2ID);
                $stmt = $pdo->prepare("INSERT INTO users (username, password_hash) VALUES (?, ?)");
                $stmt->execute([$admin_username, $password_hash]);
                $message = "Successfully created admin user '{$admin_username}'.";
                $color = "green";
                $show_form = false; // Hide form on success
            }
        } catch (Exception $e) {
            $message = "Error: " . $e->getMessage();
        }
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Create Admin User</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; background: #f0f2f5; margin: 0; }
        .container { background: #ffffff; padding: 2.5rem; box-shadow: 0 4px 12px rgba(0,0,0,0.15); border-radius: 8px; width: 100%; max-width: 480px; text-align: center; }
        h1 { margin-bottom: 1.5rem; }
        .message { padding: 1rem; border-radius: 5px; margin-bottom: 1.5rem; font-weight: 500; }
        .message.red { background-color: #f8d7da; color: #721c24; }
        .message.green { background-color: #d4edda; color: #155724; }
        .message.orange { background-color: #fff3cd; color: #856404; }
        form { display: flex; flex-direction: column; gap: 1rem; }
        input { width: 100%; padding: 0.9rem; border: 1px solid #e0e0e0; border-radius: 5px; box-sizing: border-box; }
        button { padding: 0.9rem; background: #007bff; color: white; border: none; border-radius: 5px; font-size: 1rem; cursor: pointer; }
        .password-rules { text-align: left; font-size: 0.9em; color: #666; padding: 1rem; background: #f8f9fa; border-radius: 5px; margin-top: 1rem;}
        .critical-warning { color: #d93025; font-weight: bold; margin-top: 2rem; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Create Initial Admin User</h1>
        
        <?php if (!empty($message)): ?>
            <div class="message <?php echo $color; ?>"><?php echo htmlspecialchars($message); ?></div>
        <?php endif; ?>

        <?php if ($show_form): ?>
            <form action="create_admin_user.php" method="post">
                <input type="text" name="username" value="admin" disabled>
                <input type="password" name="password" placeholder="Enter a Strong Password" required>
                <input type="password" name="password_confirm" placeholder="Confirm Password" required>
                <button type="submit">Create User</button>
            </form>
            <div class="password-rules">
                <strong>Password Requirements:</strong>
                <ul>
                    <li>At least 8 characters long</li>
                    <li>At least one uppercase letter (A-Z)</li>
                    <li>At least one lowercase letter (a-z)</li>
                    <li>At least one number (0-9)</li>
                    <li>At least one special character (e.g., !@#$%^&*)</li>
                </ul>
            </div>
        <?php endif; ?>

        <h2 class="critical-warning">CRITICAL: Delete this file (create_admin_user.php) from the server immediately after use!</h2>
    </div>
</body>
</html>