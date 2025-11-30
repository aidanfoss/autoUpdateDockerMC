# Docker Setup Guide for Windows

To run containers on Windows (and use the VS Code Docker extension effectively), you need the **Docker Engine** running. The standard way to get this is **Docker Desktop**.

## 1. Install Docker Desktop
1.  **Download**: Go to [https://www.docker.com/products/docker-desktop/](https://www.docker.com/products/docker-desktop/) and download the installer for Windows.
2.  **Install**: Run the installer.
    *   Ensure "Use WSL 2 instead of Hyper-V" is checked (recommended for better performance).
3.  **Restart**: You will likely need to log out and back in, or restart your computer.

## 2. Verify Installation
1.  Open **Docker Desktop** from your Start menu. Wait for the whale icon in the bottom-left status bar to turn **green** (or the engine status to say "Running").
2.  Open a **new** terminal (PowerShell or Command Prompt).
3.  Run:
    ```powershell
    docker --version
    ```
    If this prints a version number, you are ready.

## 3. VS Code Integration
*   The **Docker Extension** in VS Code talks to the Docker Desktop engine.
*   Once Docker Desktop is running, the extension will automatically connect.
*   You can then right-click `docker-compose.test.yml` and select **Compose Up** to run your tests.

## Troubleshooting
*   **"docker command not found"**: You might need to add Docker to your PATH, but the installer usually does this. Try restarting your terminal or computer.
*   **WSL 2 Errors**: If Docker complains about WSL 2, you might need to install the Linux kernel update package from Microsoft. Docker Desktop usually prompts you with a link if this is needed.
