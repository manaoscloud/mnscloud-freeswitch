# Contributing To MNSCloud

Thank you for your interest in contributing to MNSCloud. MNSCloud is a private company that maintains public repositories so customers, partners, and community contributors can inspect, reuse, and improve selected clients, agents, installers, and connectors.

We welcome contributions, but every change must follow our engineering, security, and product standards before it can be accepted.

## Contribution Model

All contributions must go through a Pull Request. Direct pushes to `main` are not part of the contribution workflow.

Recommended flow:

```bash
git checkout -b feature/clear-change-name
# make changes
# run the repository validation commands
git commit -m "Describe the change clearly"
git push origin feature/clear-change-name
```

Then open a Pull Request against `main`.

## Review And Acceptance

A contribution may be accepted, changed, postponed, or declined at the sole discretion of the MNSCloud maintainers. We review for:

- Product fit and long-term maintainability.
- Security impact and tenant/customer isolation.
- Compatibility with the public API contract.
- Code quality, tests, documentation, and operational safety.
- Consistency with the repository `README.md`, `SKILL.md`, `AGENTS.md`, and domain docs.

Please do not take requested changes personally. Review is part of keeping a production-grade platform trustworthy.

## Paid Contributions, Sponsorships, And Hiring

MNSCloud may, at its discretion, offer paid work, sponsorship, consulting contracts, bounties, or hiring conversations for contributors whose work demonstrates strong technical quality, reliability, and alignment with the platform.

Important terms:

- Opening a Pull Request does not create an obligation for MNSCloud to pay for the work.
- Paid work requires explicit written agreement with MNSCloud before it is considered billable.
- Security-sensitive work, large features, roadmap work, and customer-specific work should be discussed with maintainers before implementation.
- MNSCloud may contact contributors privately when a contribution shows potential for deeper collaboration.

## Security Rules

Never commit or expose:

- Tokens, passwords, API keys, JWTs, private keys, signing secrets, provider credentials, database credentials, or master keys.
- Customer data, production IPs/domains, account IDs, private topology, billing rules, internal policy rules, or non-public business logic.
- Hidden bypasses, static privileged credentials, or client-side-only authorization enforcement.

Use placeholders in examples, such as `<api_base_url>`, `<token>`, `<tenant_domain>`, `<node_uuid>`, and `<environment_uuid>`.

If you discover a vulnerability, do not open a public issue with exploit details. Follow `SECURITY.md` or contact the maintainers privately.

## Public Client Boundary

Public repositories are clients, agents, installers, or edge connectors. They consume the MNSCloud API contract; they are not the source of truth for authorization, tenant scope, billing, routing ownership, policy decisions, or secret resolution.

Those decisions belong in the API/control plane.

## Coding Standards

- Keep documentation and code comments in English unless a file explicitly documents another language requirement.
- Prefer existing repository patterns over new abstractions.
- Keep changes focused. Avoid unrelated refactors.
- Add or update tests/docs when behavior changes.
- Do not add dependencies unless they are necessary and justified in the Pull Request.
- Do not weaken security defaults to make local testing easier.

## Validation

Before opening a Pull Request, run the validation commands documented in the repository `README.md` and `SKILL.md`. At minimum, run the CI-equivalent checks provided by this repository.

## Pull Request Expectations

A good Pull Request includes:

- A clear summary of what changed and why.
- Test/validation evidence.
- Screenshots for UI changes when applicable.
- Notes about API contract, database, installer, or security impact.
- A clear statement if the change introduces new dependencies or operational requirements.

Small, focused Pull Requests are easier to review and more likely to be accepted quickly.
