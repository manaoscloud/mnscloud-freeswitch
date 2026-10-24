## Summary

Describe what changed and why.

## Release note

<!-- Required: the MNSCloud merge gate refuses a PR without this block (contract: docs/release-notes.md
in the MNSCloud workspace). Keep ONE shape and delete the others:
A) user-visible change: the fields below, short text for the customer in pt-BR, en and es;
   `breaking` also needs action.pt-BR (what the customer must do).
B) another PR of a feature whose text is in a different repository's PR: only
   `feature-key: <task-slug>` and `lead: false`.
C) nothing a user notices (refactor, tests, CI, docs, dependencies): only `visibility: internal`.
Never write server names, IPs, host names, e-mails, paths, credentials, customers or vulnerability
details. -->

```text
visibility: public
feature-key: <task-slug>
lead: true
type: new | improvement | fix | security | breaking | deprecated
audience: tenant | admin | developer
modules: module.<code> | platform
title.pt-BR: <short title for the customer>
title.en: <...>
title.es: <...>
text.pt-BR: <what changed for the customer>
text.en: <...>
text.es: <...>
```

## Type Of Change

- [ ] Bug fix
- [ ] Feature
- [ ] Documentation
- [ ] Refactor
- [ ] Security hardening
- [ ] Installer/runtime change
- [ ] Other

## Validation

Commands run:

```bash
# paste commands here
```

Result:

- [ ] Passed
- [ ] Passed with warnings explained below
- [ ] Not run, reason:

## Security And Public Client Boundary

- [ ] No secrets, customer data, private domains/IPs, credentials, or private topology were added.
- [ ] No API-side authorization, tenant scope, billing, routing ownership, policy, or secret resolution was moved into a public client.
- [ ] Examples use placeholders only.

## API / Compatibility Impact

- [ ] No API contract changes
- [ ] API contract changes documented
- [ ] Backward compatibility considered
- [ ] Not applicable

## Operational Impact

Describe service restarts, migrations, firewall changes, new packages, or deployment notes.

## Screenshots Or Logs

Add screenshots for UI changes and relevant logs for installer/runtime changes.

## Contributor Note

- [ ] I understand that Pull Requests are reviewed at MNSCloud's discretion.
- [ ] I understand that unpaid Pull Requests do not create a payment obligation unless there is a separate written agreement with MNSCloud.
