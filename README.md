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

## Install

```bash
sudo bash scripts/install-freeswitch.sh
```

See `freeswitch.md` and `SECURITY.md` for details.
