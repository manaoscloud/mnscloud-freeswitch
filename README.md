# MNSCloud FreeSWITCH

Public standalone FreeSWITCH edge connector for MNSCloud.

This repository installs and configures local FreeSWITCH runtime assets that consume the MNSCloud API
contract. It can run on MNSCloud, customer, or partner infrastructure.

## Boundary

- This repository is public and auditable by design.
- It must remain standalone and must not depend on the private MNSCloud monorepo at runtime.
- The MNSCloud API is the source of truth for authorization, tenant scope, routing ownership, billing,
  policy, and secret resolution.
- Do not commit secrets, customer data, production infrastructure values, provider credentials, or
  private business rules.

## Contract

- Product/runtime: `mnscloud-freeswitch`
- Project directory: `/opt/mnscloud/mnscloud-freeswitch`
- Installer: `scripts/install-freeswitch.sh`
- Normal update: `scripts/update-latest-freeswitch.sh`
- Explicit update: `scripts/update-freeswitch.sh --ref <release-tag>`
- Validation: `scripts/validate-freeswitch.sh`
- Rollback: `scripts/rollback-freeswitch.sh --ref <known-good-release-tag>`
- Shared package installer: `mnscloud-runtime-kit`
- Service: `freeswitch.service`
- Local state prefix: `/etc/mnscloud/pabx`
- Node UUID: `/etc/mnscloud/pabx/node.uuid`
- API base URL: `/etc/mnscloud/pabx/api.base`
- SignalWire repository token: `/etc/mnscloud/pabx/signalwire-repo.token`
- ESL secret: `/etc/mnscloud/pabx/freeswitch-esl.secret`
- FreeSWITCH config directory: `/etc/freeswitch`
- FreeSWITCH recordings: `/var/lib/freeswitch/recordings`
- XML Curl config: `/etc/freeswitch/autoload_configs/xml_curl.conf.xml`
- Event Socket config: `/etc/freeswitch/autoload_configs/event_socket.conf.xml`
- Runtime sync script: `scripts/sync-freeswitch-runtime.sh`

## Install

Install GitHub CLI if needed:
[cli/cli installation](https://github.com/cli/cli#installation).

Authenticate GitHub CLI:

```bash
gh auth login
```

Clone the private repository and install:

```bash
sudo install -d -m 0755 /opt/mnscloud
cd /opt/mnscloud
gh repo clone manaoscloud/mnscloud-freeswitch
cd /opt/mnscloud/mnscloud-freeswitch
sudo bash scripts/install-freeswitch.sh
```

The recommended production flow is to create the FreeSWITCH PABX server in MNSCloud and use
**Generate Install Command**. The platform returns a visible-once runtime token, stores only its hash,
and generates a command that clones/updates this repository and runs:

```bash
sudo bash scripts/install-freeswitch.sh \
  --api-base <api_base> \
  --node-uuid <node_uuid> \
  --runtime-token <visible_once_runtime_token>
```

FreeSWITCH package installation still requires the SignalWire repository token. In the recommended
flow, configure it once in Master Parameters > Integrations and the installer fetches it from the API
with the node UUID and visible-once runtime token. You can still provide it interactively when
prompted, through the local `/etc/mnscloud/pabx/signalwire-repo.token` file, or through
`SIGNALWIRE_REPO_TOKEN`/`--signalwire-token`. Do not commit this provider token.

Before installing FreeSWITCH PABX, enroll `mnscloud-agent` on the host. The installer validates the
shared Agent prerequisite contract with
`/opt/mnscloud/mnscloud-agent/scripts/validate-agent.sh --require-active --require-enrolled`.
After FreeSWITCH is installed, the Agent derives and reports `voip.freeswitch.manage`.

See `freeswitch.md` and `SECURITY.md` for details.

## Update

The normal operator path resolves the latest approved release at execution
time. It retains the node identity and credentials in `/etc/mnscloud/pabx/`,
reapplies the managed FreeSWITCH configuration, validates the service, and
automatically restores the previous checkout if the update cannot validate.

```bash
cd /opt/mnscloud/mnscloud-freeswitch
sudo ./scripts/update-latest-freeswitch.sh
```

Older installations that predate the lifecycle scripts need this one-time
bootstrap. It intentionally retrieves only the signed repository scripts; the
helper then checks out the approved release tag and performs the full update.

```bash
cd /opt/mnscloud/mnscloud-freeswitch
sudo git fetch origin main --tags --prune
sudo git checkout origin/main -- scripts/update-freeswitch.sh scripts/update-latest-freeswitch.sh scripts/validate-freeswitch.sh scripts/rollback-freeswitch.sh
sudo chmod +x scripts/{update-freeswitch,update-latest-freeswitch,validate-freeswitch,rollback-freeswitch}.sh
sudo ./scripts/update-latest-freeswitch.sh
```

For a planned rollback, use an explicit known-good release tag. This is the
only supported rollback path; do not use `git pull` as an operational update.

```bash
cd /opt/mnscloud/mnscloud-freeswitch
sudo ./scripts/rollback-freeswitch.sh --ref v0.1.4
```

Validate the installed runtime at any time:

```bash
sudo ./scripts/validate-freeswitch.sh
```

## Runtime synchronization

The MNSCloud Agent is the only control-plane executor for PABX runtime changes. When a trunk,
route, dial plan, or dial-plan rule changes, the API queues an Agent job for the server assigned to
that PABX. For FreeSWITCH, the Agent runs `scripts/sync-freeswitch-runtime.sh`, which retrieves the
authorized canonical Sofia configuration, replaces `sofia.conf.xml` atomically, reloads XML, and
rescans the external Sofia profile. The script does not store tenant routing data locally and does
not log the runtime token.
