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
6) Clean SIP profile generation at `/etc/freeswitch/sip_profiles/internal.xml`.
7) Static demo directory cleanup under `/etc/freeswitch/directory`.
8) Optional ODBC DSN creation in `/etc/odbc.ini`.
9) `systemctl enable --now freeswitch`.

Before replacing any managed FreeSWITCH file or directory, the installer creates a one-time
`.bkp` copy beside the original path. Existing `.bkp` files are preserved.

XML Curl uses this endpoint:
`/api/v1/pabx/freeswitch/{serverUUID}` with FreeSWITCH native POST form payload.

The generated `xml_curl.conf.xml` creates two explicit bindings:
- `directory`: extension authentication and directory lookup.
- `dialplan`: inbound DID routing lookup.

Do not bind XML Curl to every section. The `gateway-url` parameter must include the FreeSWITCH
`bindings` attribute, otherwise `mod_xml_curl` can intercept `configuration` requests such as
`sofia.conf`, `loopback.conf`, and `timezones.conf`, which can prevent SIP profiles from loading.

## Install
Then run via the installer (as root):
```bash
./install.sh
```

## Required environment variables
The installer reads from `.env` (if present) and also allows overrides via env vars:
- `FREESWITCH_REPO_TOKEN` (required) Token for SignalWire repo access.
- `FREESWITCH_API_TOKEN` or `PABX_API_TOKEN` (optional) Bearer token sent by XML Curl to the Manaos API.
- `FREESWITCH_SERVER_UUID` or `PABX_SERVER_UUID` (required) UUID of the registered PABX server.
- `FREESWITCH_API_BASE` (optional, default: `https://dev1.publichost.cloud`).
- `FREESWITCH_LOCAL_IP` (optional, default: `$${local_ip_v4}` in FreeSWITCH config).
- `FREESWITCH_EXT_SIP_IP` (optional, default: `auto-nat`).
- `FREESWITCH_EXT_RTP_IP` (optional, default: `auto-nat`).

## Managed FreeSWITCH files
The installer treats these paths as Manaos-managed and writes clean versions:
- `/etc/freeswitch/autoload_configs/modules.conf.xml`
- `/etc/freeswitch/autoload_configs/xml_curl.conf.xml`
- `/etc/freeswitch/sip_profiles/internal.xml`
- `/etc/freeswitch/directory`
- `/etc/odbc.ini` when ODBC env vars are provided

The generated internal SIP profile is domain-neutral for multitenant PABX. It intentionally does
not set `force-register-domain`, `force-subscription-domain`, or `force-register-db-domain`.
SIP clients must register using the tenant PABX domain as realm/domain.

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
- Confirm the API is reachable at `${FREESWITCH_API_BASE}/api/v1/pabx/freeswitch/{serverUUID}`.
- Confirm the module load log shows bindings such as `[directory]` and `[dialplan]`, not `[]`.
- Keep SIP domains dynamic for multitenant PABX. Do not hard-code a single tenant domain in
  `sip_profiles/internal.xml`; use the domain/realm sent by the SIP client.
