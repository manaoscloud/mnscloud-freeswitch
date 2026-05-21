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
- Service: `freeswitch.service`
- Local state prefix: `/etc/mnscloud/pabx`
- Node UUID: `/etc/mnscloud/pabx/node.uuid`
- API token: `/etc/mnscloud/pabx/api.token`
- API base URL: `/etc/mnscloud/pabx/api.base`
- SignalWire repository token: `/etc/mnscloud/pabx/signalwire-repo.token`
- ESL secret: `/etc/mnscloud/pabx/freeswitch-esl.secret`
- FreeSWITCH config directory: `/etc/freeswitch`
- FreeSWITCH recordings: `/var/lib/freeswitch/recordings`
- XML Curl config: `/etc/freeswitch/autoload_configs/xml_curl.conf.xml`
- Event Socket config: `/etc/freeswitch/autoload_configs/event_socket.conf.xml`

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

See `freeswitch.md` and `SECURITY.md` for details.
