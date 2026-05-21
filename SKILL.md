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
- Permanent provider credentials stay in the API/control plane.
- If the app generates a PABX install token, the operator must copy/run the generated command on the
  FreeSWITCH host so `/etc/mnscloud/pabx/api.token` matches the API-side hash before installer
  validation.

## Contract

- Product repository: `manaoscloud/mnscloud-freeswitch`
- Local installer: `scripts/install-freeswitch.sh`
- Runtime API consumer: MNSCloud PABX FreeSWITCH endpoints under `/api/v1/pabx/freeswitch/*`
- Local state prefix: `/etc/mnscloud/pabx`
- Token state: `/etc/mnscloud/pabx/api.token` must match `VoipPabxServer.VpsApiTokenHash`.

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
