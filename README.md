# Net-Insight Monitor

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A comprehensive, self-hosted network performance and Service Level Agreement (SLA) monitoring system. It uses a central server to collect, store, and visualize time-series metrics from lightweight agents running on Linux and Windows clients.

This system is designed to provide clear insights into network health, helping you track uptime, performance degradation, and verify that your Internet Service Provider (ISP) is meeting their obligations.

## Key Features

- ✅ **Centralized Web Dashboard:** A clean, modern web interface to view system-wide health and drill down into individual agent performance.
- ✅ **Flexible Deployment:** An interactive setup script provides two modes:
    - **Development:** A simple HTTP setup for local testing.
    - **Production:** A secure, one-command setup with Nginx, HTTPS, and free SSL certificates from Let's Encrypt.
- ✅ **Secure by Design:**
    - **User Authentication:** The web dashboard is protected by a username and password.
    - **API Key Authentication:** Agents must use a unique, secret API key to submit data, preventing unauthorized access.
- ✅ **Cross-Platform Agents:** Lightweight monitoring agents for both **Linux (bash)** and **Windows (PowerShell)**.
- ✅ **Comprehensive Metrics:**
    - **Ping:** RTT, Jitter, and Packet Loss.
    - **DNS:** Resolution status and time.
    - **HTTP:** Web service availability and response time.
    - **Speedtest:** Download and Upload bandwidth.
    - **WiFi:** Signal strength (% and dBm) for wireless clients.
- ✅ **Data Preservation:** The setup script can run in a "migration mode" that preserves all existing data while upgrading the application stack.
- ✅ **Clean Uninstallation:** A thorough uninstaller script to cleanly remove the application, its data, and Docker components.

## Architecture

The system uses a modern, containerized architecture for security and easy deployment.

+----------------+ +----------------+ +--------------------------+
| Linux Agent | | Windows Agent | | Web Browser |
+----------------+ +----------------+ +--------------------------+
| (HTTPS API Call) | (HTTPS API Call) | (HTTPS UI Access)
| w/ API Key | w/ API Key | w/ Login Session
| | |
V V V
+--------------------------------------------------------------------------+
| Your Server (Host OS) |
| |
| +------------------------------------------------------------------+ |
| | Docker Environment | |
| | | |
| | +----------------+ +-----------------------------------+ | |
| | | Nginx Proxy |----->| App Container | | |
| | | (Ports 80/443) | | (PHP / Apache) | | |
| | +----------------+ +-----------------------------------+ | |
| | | (Internal Mount) | |
| +---------------------------------------|--------------------------+ |
| | |
| V |
| +----------------------------------------------+ |
| | /srv/net_insight_monitor/data/ (Host Path) | |
| | - net_insight_monitor.sqlite (Database) | |
| | - api.log, apache_logs/ | |
| +----------------------------------------------+ |
| |
+--------------------------------------------------------------------------+


## Prerequisites

- A Linux server (Ubuntu 20.04/22.04 recommended) with `sudo` access.
- For Production mode: A public IP address and a domain name (e.g., `monitor.yourcompany.com`) pointed to that IP.
- `git` installed (`sudo apt-get install git`).

## Server Installation

The interactive setup script handles all dependencies, configuration, and deployment.

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/your-username/Net-Insight-Monitor.git
    cd Net-Insight-Monitor/central_server_package
    ```

2.  **Run the setup script:**
    ```bash
    sudo ./setup.sh
    ```

3.  **Follow the on-screen prompts:**
    - Choose between **Development** and **Production** mode.
    - If in Production mode, enter your domain name and email address when prompted.
    - The script will automatically generate an API key for your first agent. **Copy this key and save it in a safe place.** You will need it for your first agent setup.

4.  **Create a Web Admin User (CRITICAL Security Step):**
    - After the setup script finishes, copy the `create_admin_user.php` file into the `app/` directory.
      ```bash
      # You must do this from within the central_server_package directory
      # This file is intentionally NOT included in the directory by default for safety.
      # You need to create it manually with the content provided.
      ```
    - Access the script from your browser to create the user:
      - **Production:** `https://your.domain.com/create_admin_user.php`
      - **Development:** `http://<your-server-ip>:8080/create_admin_user.php`
    - **IMMEDIATELY DELETE THE SCRIPT** from the `app/` directory after you see the success message.
      ```bash
      sudo rm ./app/create_admin_user.php
      ```

## Agent Installation

Follow these steps on each machine you want to monitor.

### Linux Agent

1.  Copy the `linux_agent_package` directory to the target Linux machine.
2.  Navigate into the directory and run the setup script:
    ```bash
    cd /path/to/linux_agent_package
    sudo ./setup_agent_linux.sh
    ```
3.  **Configure the agent (CRITICAL):**
    - Open the configuration file with a text editor:
      ```bash
      sudo nano /opt/sla_monitor/agent_config.env
      ```
    - You **must** set the following three variables:
      - `AGENT_IDENTIFIER`: A unique name for this agent (e.g., `Main-Office-Router`).
      - `CENTRAL_API_URL`: The full URL to your server's API endpoint.
      - `CENTRAL_API_KEY`: The unique API key you generated for this agent.

### Windows Agent

1.  Copy the `windows_agent_package` directory to the target Windows machine.
2.  Open **PowerShell as an Administrator**.
3.  Navigate to the directory and run the setup script:
    ```powershell
    cd C:\path\to\windows_agent_package
    .\setup_agent_windows.ps1
    ```
4.  **Configure the agent (CRITICAL):**
    - Open the configuration file with a text editor (like Notepad):
      ```powershell
      notepad C:\NetInsightAgent\agent_config.ps1
      ```
    - You **must** set the following three variables:
      - `$script:AGENT_IDENTIFIER`: A unique name for this agent (e.g., `Sales-Laptop-01`).
      - `$script:CENTRAL_API_URL`: The full URL to your server's API endpoint.
      - `$script:CENTRAL_API_KEY`: The unique API key you generated for this agent.

## Uninstallation

To completely remove the server and its data, run the uninstaller script from the `central_server_package` directory. The script will prompt you for confirmation before deleting data and SSL certificates.

```bash
sudo ./uninstall.sh

License
This project is licensed under the MIT License.