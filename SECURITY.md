# Security Policy

## Reporting a vulnerability

Please do not open a public GitHub issue for a suspected security problem.

Preferred reporting path:

- Use GitHub's private vulnerability reporting or Security Advisories flow for this repository, if it is enabled.

Fallback reporting path:

- Email The Budget Lab at Yale at `budgetlab@yale.edu` with the subject line `tariff-rate-tracker security report`.

Please include:

- a short description of the issue
- affected files, scripts, or commands
- steps to reproduce
- whether credentials, unpublished data, or local file paths may be exposed
- any suggested mitigation if you already have one

We will try to acknowledge reports within 5 business days and follow up as we confirm scope and remediation.

## Scope

The highest-priority issues for this repository include:

- leaked credentials or token-handling mistakes
- CI or dependency-chain issues that could affect released code
- bugs that expose local files, unpublished inputs, or private comparison data
- downloader or scraper behavior that can overwrite unintended files

## Supported fixes

Security fixes are applied on the default branch. We do not currently maintain backported security patches for older snapshots.

## Public disclosure

Please wait to disclose a vulnerability publicly until a fix or mitigation is available and the maintainers have had a reasonable chance to respond.
