# Security

This repository is public by design. It contains a FreeSWITCH edge connector that consumes the
MNSCloud API contract.

Do not commit secrets, customer data, private infrastructure details, provider credentials, database
credentials, production IPs, tokens, or private keys.

The MNSCloud API is the source of truth for authorization, tenant scope, routing ownership, billing,
policy, and secret resolution. This connector must only install/configure the local runtime and call
the documented API contract.
