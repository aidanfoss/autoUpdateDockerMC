# Modrinth Optional Mod Updater

A lightweight, container-friendly shell script to automatically manage and update Minecraft mods from Modrinth. It supports **required** mods (strict dependency) and **optional** mods (best-effort), with smart version resolution and caching.

## Features

*   **Smart Version Resolution**: Automatically finds the highest common Minecraft version supported by all your *Required* mods.
*   **Required vs. Optional**:
    *   **Required**: Script fails if a mod is missing or incompatible.
    *   **Optional**: Script skips the mod if no compatible version is found (great for client-side mods like Sodium/Iris that might lag behind).
*   **Caching**: Caches downloaded jars to speed up subsequent runs and save bandwidth.
*   **Manual Mod Protection**: Tracks installed mods in `.modrinth_mods.list`. Any jar file in your mods folder *not* in this list is treated as "manually installed" and is preserved during updates.
*   **Dependency Handling**: Recursively downloads required dependencies for all mods.
*   **Docker Ready**: Designed to run as an init container or sidecar.

## Usage

### Environment Variables

| Variable | Description | Default |
| :--- | :--- | :--- |
| `REQUIRED_MODS` | List of Modrinth slugs/IDs (newline or space separated). | *(Required)* |
| `OPTIONAL_MODS` | List of optional slugs/IDs. | *(Empty)* |
| `MC_VERSION` | Force a specific Minecraft version. If unset, it is auto-resolved. | *(Auto)* |
| `LOADER` | Mod loader (`fabric`, `forge`, `neoforge`, `quilt`). | `fabric` |
| `APPLY_MODE` | `replace` (updates `/mods` directly) or `stage` (downloads to `/mods_next`). | `replace` |
| `SERVER_DIR` | Base directory containing the `mods` folder. | `.` |
| `REQUIRED_ALLOWED_VERSION_TYPE` | Allowed release types for required mods (`release`, `beta`, `alpha`). | `release` |
| `OPTIONAL_ALLOWED_VERSION_TYPE` | Allowed release types for optional mods. | `release` |

### Docker Example (Init Container Pattern)

The most robust way to use this is as an **init container**. The updater runs, ensures all mods are correct, and *then* the Minecraft server starts.

See [docker-compose.sample.yml](docker-compose.sample.yml) for a complete, copy-pasteable example.

```yaml
services:
  # The Updater
  mod-updater:
    build: .
    volumes:
      - ./minecraft-data:/data
    environment:
      SERVER_DIR: "/data"
      LOADER: "fabric"
      REQUIRED_MODS: "fabric-api lithium"
      OPTIONAL_MODS: "sodium"

  # The Server
  mc:
    image: itzg/minecraft-server
    depends_on:
      mod-updater:
        condition: service_completed_successfully
    volumes:
      - ./minecraft-data:/data
    environment:
      EULA: "TRUE"
      TYPE: "FABRIC"
```

### Manual Run

```bash
export SERVER_DIR="/path/to/server"
export REQUIRED_MODS="fabric-api lithium"
./update-optional-mods.sh
```

## How it Works

1.  **Resolution**: It queries Modrinth for all `REQUIRED_MODS` to find the latest Minecraft version that *all* of them support (e.g., if Mod A supports 1.20.1 & 1.20.4, and Mod B supports 1.20.1 only, it picks 1.20.1).
2.  **Download**: It downloads the correct version of all Required and Optional mods to a build directory.
3.  **Apply**:
    *   It reads `.modrinth_mods.list` to identify previously script-managed mods.
    *   It moves those old managed jars to a backup folder.
    *   It installs the new jars.
    *   **Crucially**, any jar file in `/mods` that was *not* in the list (e.g., `my-custom-mod.jar`) is left untouched.

## Development & Testing

Tests are containerized using Docker Compose to ensure a consistent environment.

```bash
# Run integration tests
docker compose -f docker-compose.test.yml up --build
```
