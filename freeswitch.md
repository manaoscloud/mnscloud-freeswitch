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
3. Package install with explicit FreeSWITCH runtime modules, avoiding `freeswitch-meta-all`
   because that meta package pulls voicemail/mail transport dependencies such as `ssmtp`.
   The base package set includes `freeswitch`, `freeswitch-systemd`, `freeswitch-conf-vanilla`,
   SIP/XML Curl/XML dialplan/audio file runtime modules, build tools, `unixodbc`,
   `odbc-mariadb`, `libbcg729-0`, and `libbcg729-dev`.
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

During an interactive install, the node UUID is generated near the start of the run. The installer
first tries to bind the host through `POST /api/v1/pabx/freeswitch/bootstrap`. If the API cannot
locate a compatible server, it prints the UUID and waits so the operator can register that UUID on
the FreeSWITCH `VoipPabxServer` record. It then validates the registration through the heartbeat API
before continuing. If the registration cannot be validated, the installer continues and falls back
to public IPv4 discovery for SIP/RTP advertisement, then `auto-nat`.

The confirmation prompt reads and writes through `/dev/tty`, so it still works when the installer is
started by a wrapper script that uses standard input internally. Only fully non-interactive sessions
without a controlling terminal skip this wait.

The preferred and supported flow is API bootstrap plus API heartbeat. The installer does not execute
direct SQL to bind `VpsNodeUUID`; pass `FREESWITCH_API_TOKEN`, `PABX_API_TOKEN`, or
`WORKER_PABX_TOKEN` when automatic bootstrap is required.

## Codecs

The mnscloud default media order is:

```text
OPUS,PCMU,PCMA,G729,G722,H264
```

G.729 is standardized on the free `bcg729` library from the Debian repositories. The installer
installs `libbcg729-0` and `libbcg729-dev`, disables the commercial `mod_com_g729` if it is
present in `modules.conf.xml`, disables `mod_g729`, removes `freeswitch-mod-g729` from previous
installer attempts, and enables `mod_bcg729` only when the module exists.

If the configured repositories do not provide a ready `freeswitch-mod-bcg729` package, the
installer tries to build `mod_bcg729.so` from the local source in
`freeswitch/codecs/mod_bcg729`. The local source keeps reinstalls from depending on online
downloads. If the local directory is missing, the fallback source is configured by
`FREESWITCH_BCG729_SOURCE_URL` and `FREESWITCH_BCG729_SOURCE_REF`; the default is
`https://github.com/xadhoom/mod_bcg729.git` pinned at commit
`4203247dee4719545005ec7ab9ea536fc83df1d8`. The build uses the system `libbcg729` library and
FreeSWITCH headers. It does not install or enable the paid/ambiguous SignalWire G.729 module.

H.264 is enabled as a video codec/pass-through capability. The Provider `Default Audio Codecs`
and `Default Video Codecs` selections are the source of truth for generated directory/gateway
configuration; extension and trunk codec selections override Provider defaults only when filled.

The generated `xml_curl.conf.xml` creates explicit bindings:

- `directory`: extension authentication and directory lookup.
- `dialplan`: inbound DID routing lookup.
- `configuration`: complete `sofia.conf` rendering, including managed profiles and gateways.

Do not bind XML Curl without a `bindings` attribute. The `configuration` binding must only return
complete FreeSWITCH configuration XML. For `sofia.conf`, the API must render the full Sofia config
with profile settings and managed gateways; returning only dynamic gateways replaces the local
profile with an incomplete profile and Sofia will fail with `No Settings, check the new config!`.

## Install

Then run via the installer (as root):

```bash
./install.sh
```

## Required environment variables

The installer still accepts a small set of runtime variables. `.env` may be present for legacy
deployments, but SIP/RTP public IP selection is intentionally not driven by `.env`:

- `FREESWITCH_REPO_TOKEN` (required) Token for SignalWire repo access.
- `FREESWITCH_API_TOKEN` or `PABX_API_TOKEN` (optional) Bearer token sent by XML Curl to the mnscloud API.
- `FREESWITCH_API_BASE` (optional, default: `https://dev1.publichost.cloud`).
- `FREESWITCH_LOCAL_IP` (optional, default: `$${local_ip_v4}` in FreeSWITCH config).
- `FREESWITCH_EXT_SIP_IP` (optional runtime-only override) Explicit public SIP IP.
- `FREESWITCH_EXT_RTP_IP` (optional runtime-only override) Explicit public RTP IP.
- `FREESWITCH_AUTO_DISCOVER_PUBLIC_IP` (optional runtime-only, default: `1`) Set to `0` to disable
  automatic public IPv4 discovery and keep `auto-nat` unless explicit external IPs are provided.
- `FREESWITCH_ESL_ALLOWED_IPS` (recommended) CIDR list allowed to access ESL, for example
  `172.17.0.10/32`.
- `FREESWITCH_ESL_PORT` (optional, default: `8021`).
- `FREESWITCH_ESL_LISTEN_IP` (optional, default: `0.0.0.0`). ESL access is still restricted by
  the generated `mnscloud-control` ACL.

External SIP/RTP IPs are resolved in this order: explicit runtime env override, API-validated
`VoipPabxServer.VpsPublicIPv4`, public IPv4 discovery over HTTPS, then `auto-nat`. The installer does
not read `FREESWITCH_EXT_SIP_IP`, `FREESWITCH_EXT_RTP_IP`, or
`FREESWITCH_AUTO_DISCOVER_PUBLIC_IP` from `.env`; keep those as per-run overrides only.

## Managed FreeSWITCH files

The installer treats these paths as mnscloud-managed and writes clean versions:

- `/etc/freeswitch/autoload_configs/modules.conf.xml`
- `/etc/freeswitch/autoload_configs/sofia.conf.xml`
- `/etc/freeswitch/autoload_configs/xml_curl.conf.xml`
- `/etc/freeswitch/autoload_configs/event_socket.conf.xml`
- `/etc/freeswitch/autoload_configs/acl.conf.xml`
- `/etc/fs_cli.conf`
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
- ESL secret: `/etc/mnscloud/pabx/freeswitch-esl.secret`
- Local `fs_cli` config: `/etc/fs_cli.conf`
- Node UUID: `/etc/mnscloud/pabx/node.uuid`
- ODBC DSN: `/etc/odbc.ini`
- Logs: `/var/log/freeswitch/xml_curl`

## Troubleshooting

- If packages are missing, set `FREESWITCH_REPO_SUITE=bookworm` and rerun.
- Ensure the SignalWire token is valid and has repo access.
- If node binding fails, confirm the registered PABX server has `VpsHostname`, `VpsPublicIPv4`,
  `VpsPublicIPv6`, `VpsPrivateIPv4`, or `VpsPrivateIPv6` matching this host, or copy
  `/etc/mnscloud/pabx/node.uuid` into `VpsNodeUUID`.
- Confirm the API is reachable at `${FREESWITCH_API_BASE}/api/v1/pabx/freeswitch`.
- Confirm media support with `fs_cli -x "show codecs" | grep -Ei "G729|H264"` and
  `fs_cli -x "module_exists mod_bcg729"`.
- Confirm the module load log shows bindings such as `[directory]`, `[dialplan]`, and
  `[configuration]`, not `[]`.
- Confirm ESL is restricted by `mnscloud-control`; the installer always allows `127.0.0.1/32` for
  local `fs_cli` and adds the API/worker source IPs for remote control.
- Keep SIP domains dynamic for multitenant PABX. Do not hard-code a single tenant domain in
  `sip_profiles/internal.xml`; use the domain/realm sent by the SIP client.
