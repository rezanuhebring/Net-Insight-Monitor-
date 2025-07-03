<?php
session_start();
if (isset($_SESSION['loggedin']) && $_SESSION['loggedin'] === true) {
    header('Location: index.php');
    exit;
}
$error_message = '';
if ($_SERVER['REQUEST_METHOD'] == 'POST') {
    $db_path = '/opt/sla_monitor/app_data/net_insight_monitor.sqlite';
    try {
        $pdo = new PDO('sqlite:' . $db_path);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $username = $_POST['username'] ?? '';
        $password = $_POST['password'] ?? '';
        $stmt = $pdo->prepare("SELECT * FROM users WHERE username = ?");
        $stmt->execute([$username]);
        $user = $stmt->fetch(PDO::FETCH_ASSOC);
        if ($user && password_verify($password, $user['password_hash'])) {
            session_regenerate_id(true);
            $_SESSION['loggedin'] = true;
            $_SESSION['username'] = $user['username'];
            header('Location: index.php');
            exit;
        } else {
            $error_message = 'Invalid username or password.';
        }
    } catch (Exception $e) {
        error_log("Login Error: " . $e->getMessage());
        $error_message = 'A server error occurred. Please try again later.';
    }
}
?>
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><title>Login - Net-Insight Monitor</title><meta name="viewport" content="width=device-width, initial-scale=1.0"><style>:root { --bg-color: #f0f2f5; --card-bg: #ffffff; --link-color: #007bff; --border-color: #e0e0e0;} body {font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; background: var(--bg-color);} .login-box { background: var(--card-bg); padding: 2.5rem; box-shadow: 0 4px 12px rgba(0,0,0,0.15); border-radius: 8px; width: 100%; max-width: 380px; } h2 { text-align: center; margin-bottom: 2rem; color: #333;} input { width: 100%; padding: 0.9rem; margin-bottom: 1.2rem; border: 1px solid var(--border-color); border-radius: 5px; box-sizing: border-box; } button { width: 100%; padding: 0.9rem; background: var(--link-color); color: white; border: none; border-radius: 5px; font-size: 1rem; cursor: pointer; } .error { text-align: center; color: #dc3545; margin-top: 1.5rem; height: 1em; }</style></head><body><div class="login-box"><h2>Net-Insight Monitor Login</h2><form action="login.php" method="post"><input type="text" name="username" placeholder="Username" required autofocus><input type="password" name="password" placeholder="Password" required><button type="submit">Login</button></form><p class="error"><?php echo htmlspecialchars($error_message); ?></p></div></body></html>