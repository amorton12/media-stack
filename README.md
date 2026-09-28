# media-stack

This repository is the GitHub-safe backup of a working self-hosted media stack. It contains the deployable configuration and app settings that should be versioned, while leaving live runtime state, cache files, logs, and secrets local and untracked.

## What this repo contains

- Docker Compose definitions for the stack
- Service config files that are safe to back up
- A checked-in example environment template for local setup
- Git ignore rules that exclude cache, state, secrets, and generated data

## What is intentionally not tracked

The real `.env` file and container-generated runtime data are not stored in Git. This includes:

- downloads and incomplete downloads
- caches and MediaCover artwork folders
- logs, metadata, session data, and app state
- secrets and local-only config

## Stack overview

This stack includes services such as:

- Gluetun / VPN
- qBittorrent
- Radarr
- Sonarr
- Lidarr
- Prowlarr
- Jellyfin
- Seerr / Jellyseerr
- Slskd
- Multi-Scrobbler
- Audiobookshelf
- Additional companion services

## Local setup

1. Copy the example file to your live local config:

```bash
cp .env.example .env
```

2. Fill in the real values in `.env`.

3. Start the stack:

```bash
docker compose --profile vpn up -d
```

Use the profile that matches your deployment if needed.

## GitHub-safe repo pattern

- `.env` stays local and is ignored by Git
- `.env.example` is the checked-in template
- runtime data is excluded by `.gitignore`
- only config and compose files are intended for GitHub backup

## Useful commands

```bash
docker compose ps
docker compose logs -f
docker compose down
```

## Notes

- This repo preserves the working configuration, not the generated state of the containers.
- To restore the stack from GitHub, copy `.env.example` to `.env` and replace placeholders with your real values before starting containers.
- Do not commit the live `.env` file or any runtime download/cache directories.
