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
- Local secrets must be generated on the target host and stored with restrictive permissions.
- Permanent provider credentials stay in the API/control plane.

## Contract

- Product repository: `manaoscloud/mnscloud-freeswitch`
- Local installer: `scripts/install-freeswitch.sh`
- Runtime API consumer: MNSCloud PABX FreeSWITCH endpoints under `/api/v1/pabx/freeswitch/*`
- Local state prefix: `/etc/mnscloud/pabx`

## Checklist

- Validate `scripts/install-freeswitch.sh` with `bash -n`.
- Search the module for sensitive values before publishing.
- Keep all required installer helpers inside this repository.
- Keep the module consuming API contracts only.
