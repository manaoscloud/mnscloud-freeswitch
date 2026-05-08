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

1. OS check (Debian 12).
2. Repo setup using SignalWire `fsget` (requires token).
3. Package install (`freeswitch-meta-all`, `unixodbc`, `odbc-mariadb`, `libbcg729-0`,
   `libbcg729-dev`).
   The installer also installs troubleshooting tools: `sngrep`, `tcpdump`, `ngrep`, `dnsutils`,
   `traceroute`, `mtr-tiny`, `netcat-openbsd`, and `jq`.
4. Module enablement in `/etc/freeswitch/autoload_configs/modules.conf.xml`.
5. XML Curl config generation at `/etc/freeswitch/autoload_configs/xml_curl.conf.xml`.
6. Clean SIP profile generation at `/etc/freeswitch/sip_profiles/internal.xml`.
7. Static demo directory cleanup under `/etc/freeswitch/directory`.
8. Optional ODBC DSN creation in `/etc/odbc.ini`.
9. `systemctl enable --now freeswitch`.

Before replacing any managed FreeSWITCH file or directory, the installer creates a one-time
`.bkp` copy beside the original path. Existing `.bkp` files are preserved.

XML Curl uses this endpoint:
`/api/v1/pabx/freeswitch` with FreeSWITCH native POST form payload.

The installer creates a persistent node UUID in `/etc/mnscloud/pabx/node.uuid` and sends it as
`node_uuid` in the XML Curl URL. The API also accepts `X-PABX-Node-UUID` for manual integrations.
The node UUID identifies the physical FreeSWITCH installation. The API resolves that value to
`VoipPabxServer.VpsUUID` internally, so FreeSWITCH does not need to know the database record UUID.

The installer tries to bind the local node UUID to `VoipPabxServer.VpsNodeUUID` using the local
hostname, FQDN, and public/private IPs already registered in the database. Discovery requires
database connectivity through the DB variables in `.env`. If multiple active server records match,
copy the generated node UUID into the correct PABX server record manually.

## Codecs

The Manaos default media order is:

```text
OPUS,PCMU,PCMA,G729,G722,H264
```

G.729 is standardized on the free `bcg729` library from the Debian repositories. The installer
installs `libbcg729-0` and `libbcg729-dev`, disables the commercial `mod_com_g729` if it is
present in `modules.conf.xml`, and enables `mod_bcg729` only when the module exists in the
configured repositories/system. It does not install or enable the paid SignalWire G.729 module.

H.264 is enabled as a video codec/pass-through capability. The Provider `Default Audio Codecs`
and `Default Video Codecs` selections are the source of truth for generated directory/gateway
configuration; extension and trunk codec selections override Provider defaults only when filled.

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
- Node UUID: `/etc/mnscloud/pabx/node.uuid`
- ODBC DSN: `/etc/odbc.ini`
- Logs: `/var/log/freeswitch/xml_curl`

## Troubleshooting

- If packages are missing, set `FREESWITCH_REPO_SUITE=bookworm` and rerun.
- Ensure the SignalWire token is valid and has repo access.
- If node binding fails, confirm the registered PABX server has `VpsHostname`, `VpsPublicIP`, or
  `VpsPrivateIP` matching this host, or copy `/etc/mnscloud/pabx/node.uuid` into `VpsNodeUUID`.
- Confirm the API is reachable at `${FREESWITCH_API_BASE}/api/v1/pabx/freeswitch`.
- Confirm media support with `fs_cli -x "show codecs" | grep -Ei "G729|H264"` and
  `fs_cli -x "module_exists mod_bcg729"`.
- Confirm the module load log shows bindings such as `[directory]` and `[dialplan]`, not `[]`.
- Keep SIP domains dynamic for multitenant PABX. Do not hard-code a single tenant domain in
  `sip_profiles/internal.xml`; use the domain/realm sent by the SIP client.
