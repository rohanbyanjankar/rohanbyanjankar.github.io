# Revenue Intelligence: Technical Documentation

This documentation describes the current repository implementation and provides an operational and migration guide for the Ministry of Finance (MoF).

## Start here

| Document | Purpose |
|---|---|
| [System architecture](SYSTEM_ARCHITECTURE.md) | Components, data flows and hosting model |
| [Repository inventory](REPOSITORY_INVENTORY.md) | Important folders, files and workflows |
| [Database reference](DATABASE.md) | Tables, roles, policies, functions and migration history |
| [Operations manual](OPERATIONS.md) | Routine administration, imports, targets and troubleshooting |
| [FCGO integration](FCGO_INTEGRATION.md) | Current API fetcher, output format and known limitation |
| [Nepali fiscal calendar](FISCAL_CALENDAR.md) | Calendar source policy, generation and import |
| [MoF migration plan](MOF_MIGRATION.md) | End-to-end migration to government infrastructure |
| [Security and continuity](SECURITY.md) | Access, secrets, backups, recovery and go-live controls |
| [Acceptance checklist](ACCEPTANCE_CHECKLIST.md) | Tests required before official production use |

## Scope and status

The repository contains a static browser frontend, Supabase SQL migrations, a Python FCGO fetcher, GitHub Actions workflows, fiscal-calendar generation code and supporting data files.

This documentation is based on the repository contents inspected on 25 November 2026. It describes code and configuration present in GitHub. It does **not** establish that every SQL migration has been applied to the live Supabase project, that the live database matches the repository, or that every feature has passed production testing.

The FCGO workflow has been observed failing from GitHub-hosted runners because the runner cannot establish a connection to `dailybudgetary.fcgo.gov.np:443`, even after retries. The current automation should therefore be treated as implemented but not operationally reliable from GitHub Actions.

The generated calendar status currently reports `no_verified_calendar`. The calendar generator intentionally publishes only source-verified years. Do not infer that the generated calendar outputs are complete merely because a legacy CSV exists.

## Important production rule

Do not place database passwords, Supabase service-role keys, OAuth client secrets, GitHub personal access tokens, private keys or other credentials in this repository, browser JavaScript, screenshots or documentation. Use an approved secrets manager or protected server environment variables.

## Current public application

The repository is currently configured for GitHub Pages. The public repository address is:

https://github.com/rohanbyanjankar/rohanbyanjankar.github.io

The current GitHub Pages address has been used as the development deployment. For official MoF use, follow [the MoF migration plan](MOF_MIGRATION.md) and obtain written approval for hosting, domain, data handling and security arrangements.
