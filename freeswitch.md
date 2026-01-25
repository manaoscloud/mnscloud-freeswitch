# FreeSWITCH

## Overview
This project includes a Debian 12-only FreeSWITCH installer that:
- Installs FreeSWITCH from the official SignalWire repo.
- Enables XML Curl modules for PABX integration.
- Optionally configures ODBC (MariaDB) for FreeSWITCH.
- Registers and starts the FreeSWITCH service.

Supported OS: Debian 12 only.

## How it works
The installer lives at `scripts/install-freeswitch.sh` and performs:
1) OS check (Debian 12).
2) Repo setup using SignalWire `fsget` (requires token).
3) Package install (`freeswitch-meta-all`, `unixodbc`, `odbc-mariadb`).
4) Module enablement in `/etc/freeswitch/autoload_configs/modules.conf.xml`.
5) XML Curl config generation at `/etc/freeswitch/autoload_configs/xml_curl.conf.xml`.
6) Optional ODBC DSN creation in `/etc/odbc.ini`.
7) `systemctl enable --now freeswitch`.

XML Curl uses this endpoint:
`/api/v1/pabx/{tenant}` with query parameters for FreeSWITCH sections.

## Install
Before running, ensure `.env` exists and required variables are present. The same security step used by the app can be run to generate/validate `.env` and secrets:
```bash
./scripts/application-security.sh
```

Then run via the installer (as root):
```bash
./install.sh
```

## Required environment variables
The installer reads from `.env` (if present) and also allows overrides via env vars:
- `FREESWITCH_REPO_TOKEN` (required) Token for SignalWire repo access.
- `FREESWITCH_TENANT` or `PABX_TENANT` (optional, default: `default`).
- `FREESWITCH_API_BASE` (optional, default: `https://dev1.publichost.cloud`).

## Optional DB (ODBC) configuration
If these are provided, the installer writes `/etc/odbc.ini`:
- `FS_DB_HOST` (or `DB_HOST`)
- `FS_DB_PORT` (or `DB_PORT`, default `3306`)
- `FS_DB_NAME` (or `DB_NAME`)
- `FS_DB_USER` (or `DB_USER`)
- `FS_DB_PASS` (or `DB_PASS`)

## Output files
- XML Curl config: `/etc/freeswitch/autoload_configs/xml_curl.conf.xml`
- ODBC DSN: `/etc/odbc.ini`
- Logs: `/var/log/freeswitch/xml_curl`

## Troubleshooting
- If packages are missing, set `FREESWITCH_REPO_SUITE=bookworm` and rerun.
- Ensure the SignalWire token is valid and has repo access.
- Confirm the API is reachable at `${FREESWITCH_API_BASE}/api/v1/pabx/{tenant}`.
