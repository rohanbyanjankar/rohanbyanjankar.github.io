# Migration to Ministry of Finance Infrastructure

## 1. Objective

Move the complete Revenue Intelligence application from the current personal GitHub Pages and Supabase development arrangement to an environment approved and controlled by the Ministry of Finance (MoF). The intended scope includes source code, frontend hosting, database, authentication, reporting functions, data, classification rules, automation, backups and operational ownership.

This is a technical migration plan, not confirmation that MoF or its hosting authority has approved a particular platform, domain, server or database.

## 2. Target outcome

The application should be available through an MoF-approved route. It may be integrated into the existing `data.mof.gov.np` portal, hosted as a separate application and linked from that portal, or deployed under another approved MoF URL. The portal's current technology and administrative arrangements must be confirmed by the MoF IT team before selecting an integration method.

Recommended target components:
- Government-approved application host.
- Government-controlled PostgreSQL database.
- Approved authentication and identity-management service.
- Scheduled integration worker with network access to FCGO.
- TLS, firewall, monitoring, logging and backup services.
- Staging and production environments.
- Documented ownership, support and change-control process.

## 3. Migration principles

1. Preserve source data and historical auditability.
2. Keep the existing application operational during migration.
3. Never copy secrets into source code or public repositories.
4. Separate staging and production.
5. Reconcile data and calculations before cutover.
6. Retain a tested rollback path.
7. Obtain MoF/hosting authority approval for data location, security and access.
8. Do not assume Supabase SQL can be applied unchanged to a plain PostgreSQL server.

## 4. Phase 0: Governance and discovery

Obtain decisions from the MoF system owner and IT team:
- Who is the business owner and data owner?
- Who approves user roles and access?
- Is the application allowed to run on the existing MoF data portal infrastructure?
- Which government hosting/data-centre service is approved?
- Is Supabase permitted, or must the full backend be self-hosted?
- Which identity provider is approved?
- What are the data classification, retention and backup requirements?
- Who operates the FCGO integration and responds to failures?
- What security assessment and acceptance are required?

Deliverable: signed-off hosting and architecture decision record.

## 5. Phase 1: Technical audit

Before provisioning:
- Record the GitHub repository URL, default branch and commit SHA.
- Inventory every frontend file, asset, workflow and dependency.
- Inventory all SQL migrations and compare them with the live database.
- Export database schema, data, indexes, sequences, functions, triggers, grants and policies.
- Inventory Supabase Auth users and provider configuration without exporting secrets into Git.
- Identify all frontend Supabase endpoints and client-side configuration.
- Inventory GitHub Actions, calendar inputs, generated data and FCGO snapshots.
- Inspect `data/revenue.csv` and establish whether it is test, demonstration or approved production data.
- Identify any hard-coded domains, callback URLs, redirect URLs and external services.
- Document the current live behavior and take baseline screenshots and reconciliation totals.

Deliverable: source-to-target inventory and gap register.

## 6. Phase 2: Provision target environment

The MoF/hosting team should provide:
- A staging application environment.
- A production application environment.
- A supported PostgreSQL version and database.
- Network rules, private access and TLS.
- Approved secrets storage.
- Backup and restore capability.
- Monitoring and application logs.
- A scheduled job/worker capability.
- DNS and portal integration route.

Record server sizing and scaling requirements after measuring database size, request volume and expected concurrent users. Do not guess capacity from the CSV size alone.

## 7. Phase 3: Backend and database migration

### Option A: Retain Supabase
Use this only if MoF formally approves continued use of the current Supabase service and its data location, security, contractual and access arrangements. Transfer project ownership and administrative control under an approved organizational account. This is not a full migration away from Supabase.

### Option B: Self-host the application backend
Use a government PostgreSQL instance and replace Supabase-dependent services. This requires more engineering:
- Replace Supabase Auth with an approved identity provider.
- Replace `auth.uid()`, `auth.users`, `authenticated` and Supabase-specific grants/policies.
- Provide a secure application API or approved PostgreSQL access layer.
- Reimplement RPC calls used by the browser.
- Rebuild role checks, RLS-equivalent controls and session handling.
- Review every SQL function for security-definer behavior and search paths.
- Replace Supabase client calls in the frontend.
- Recreate upload, audit and user-management behavior.

A plain PostgreSQL database alone is not a drop-in replacement for Supabase.

### Data migration sequence
1. Take a source backup and verify it can be restored.
2. Create target schema using reviewed migrations or a reconciled schema export.
3. Load fiscal calendar and revenue-head reference data.
4. Load classification rules, preserving both classification levels and omit actions.
5. Load revenue daily observations.
6. Load annual and monthly targets, preserving overrides.
7. Load upload history and audit records where permitted and meaningful.
8. Recreate application users through the approved identity process.
9. Recreate indexes, sequences, constraints, functions and authorization controls.
10. Validate counts, keys and financial totals.

Do not migrate Supabase authentication password hashes into another platform unless supported and approved. A password reset or account re-enrolment may be required.

## 8. Phase 4: Frontend and portal migration

- Deploy the frontend to the approved application host.
- Replace GitHub Pages-specific paths and URLs.
- Configure the approved application API endpoint.
- Configure authentication redirects and session handling.
- Set CSP, CORS and secure cookie policies as appropriate.
- Integrate with `data.mof.gov.np` navigation or an approved link.
- Confirm mobile, desktop and supported browser behavior.
- Ensure no privileged key or database credential is sent to the browser.

The exact portal integration method depends on the existing portal platform and the permissions of its administrators.

## 9. Phase 5: Automation migration

### FCGO
Move `scripts/fetch_fcgo.py` logic to an approved government-hosted worker or scheduled job. Test connectivity from the exact target network. Confirm API series ordering, labels and units with FCGO. Add freshness monitoring, failure alerts, structured logs and snapshot history.

### Fiscal calendar
Move the verified calendar inputs, generator, tests and publication process to a government-controlled repository or deployment pipeline. Keep official source provenance and second-reviewer checks. Do not automatically promote legacy or projected calendar rows.

### Backups
Set automated database and file backups with approved retention, access restrictions and off-host protection. Test restoration to a clean staging environment.

## 10. Phase 6: Parallel testing and reconciliation

Keep the current system live while the target runs in staging. Test:
- Sign-in, sign-out, role assignment and unauthorized access.
- Viewer, editor and admin permissions.
- Revenue CSV and Excel import.
- Duplicate rejection and invalid-row handling.
- Classification 1 and Classification 2.
- Longest-prefix rule matching and omit behavior.
- Annual and monthly targets, including manual overrides.
- Daily, monthly, fiscal-year and multi-year comparisons.
- Fiscal calendar date mapping and cutoffs.
- FCGO snapshot freshness and comparisons.
- Audit history, user administration and lockout behavior.
- Export restrictions and download permissions.
- Backup and restore.
- Performance, accessibility and security.

Reconcile source and target database row counts and financial totals at daily, monthly and fiscal-year levels. Resolve every material difference before production approval.

## 11. Phase 7: Cutover

1. Announce a controlled maintenance window.
2. Stop or restrict writes to the source system.
3. Take a final source backup.
4. Apply final incremental changes to the target.
5. Run final reconciliation.
6. Obtain business owner and IT/security sign-off.
7. Switch the official MoF route to the target application.
8. Monitor logs, imports, dashboard totals and user access.
9. Keep the old system read-only for an agreed rollback period.
10. Decommission the old service only after formal acceptance.

## 12. Rollback

Define in advance:
- Who can authorize rollback.
- How the MoF route is switched back.
- How writes made after cutover are preserved.
- How the target database is isolated for investigation.
- How users are notified.
- How data consistency is re-established.

Do not run two writable production databases without a deliberate synchronization design.

## 13. Deliverables

- Approved architecture and hosting decision.
- Complete source-code inventory and release tag.
- Database schema and migration package.
- Data export, import and reconciliation reports.
- Authentication and authorization design.
- Deployment and configuration guide.
- FCGO integration service and monitoring.
- Fiscal calendar verification record.
- Backup and disaster-recovery plan.
- Security test report.
- User and administrator manuals.
- Go-live and rollback approval record.

## 14. Items not yet verified

The following cannot be established from the GitHub repository alone:
- Whether the current Supabase live database has all migrations applied.
- Current production database size and exact row counts.
- Whether the stored revenue CSV is test or approved production data.
- Current user list, roles and authentication-provider configuration.
- Whether MoF will approve Supabase or require self-hosting.
- The architecture and integration options of `data.mof.gov.np`.
- The exact FCGO series labels and units for all API responses.
- Whether the proposed government host can reach the FCGO endpoint.

These must be confirmed during Phase 0 and Phase 1.
