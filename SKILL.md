# MNSCloud FreeSWITCH Connector Skill

Use this contract when changing the `freeswitch/` module or publishing `manaoscloud/mnscloud-freeswitch`.

## Public Repository Boundary

This module is a public edge connector. It may run on MNSCloud, customer, or partner servers and
consume the MNSCloud API contract. It must be fully standalone and must not depend on the private
monorepo at runtime.

## Security Rules

- Do not commit secrets, tokens, private keys, provider credentials, customer data, production IPs, or
  tenant-specific values.
- Do not copy API-side authorization, billing, tenant scoping, routing ownership, or private business
  rules into this module.
- Do not add hidden API bypasses, static master tokens, default production credentials, or privileged
  shortcuts.
- Use placeholders in examples: `<api_base>`, `<node_uuid>`, `<token>`, `<tenant_domain>`.
- Node UUIDs generated, persisted, displayed, or sent by installers must be normalized to lowercase.
- Local secrets must be generated on the target host and stored with restrictive permissions.
- Permanent provider credentials stay out of source control. SignalWire repository tokens may be
  provided interactively, by protected local file, environment variable, or installer argument.
- UI-generated PABX install commands may expose the server runtime token only once. The API must
  store only its hash, and regenerating the command must replace the previous token.
- Agent remains the preferred executor for remote operational commands after installation.

## Contract

- Product repository: `manaoscloud/mnscloud-freeswitch`
- Local installer: `scripts/install-freeswitch.sh`
- Runtime API consumer: MNSCloud PABX FreeSWITCH endpoints under `/api/v1/pabx/freeswitch/*`
- Local state prefix: `/etc/mnscloud/pabx`
- Install flags: `--api-base`, `--node-uuid`, `--runtime-token`/`--install-token`, and optional
  `--signalwire-token`.

## Checklist

- Validate `scripts/install-freeswitch.sh` with `bash -n`.
- Search the module for sensitive values before publishing.
- Keep all required installer helpers inside this repository.
- Keep the module consuming API contracts only.

## Contribution Governance

- External contributions must be submitted through Pull Requests.
- Follow `CONTRIBUTING.md`, `SECURITY.md`, `AGENTS.md`, and this `SKILL.md` before proposing changes.
- Do not add secrets, customer data, private infrastructure details, production domains/IPs, or hidden bypass logic.
- MNSCloud may choose to pay, sponsor, contract, or hire contributors when work demonstrates strong value, but paid work requires explicit written agreement and is never implied by opening a Pull Request.
- Keep security-sensitive decisions, tenant scope, billing, authorization, routing ownership, and secret resolution in the MNSCloud API/control plane.
