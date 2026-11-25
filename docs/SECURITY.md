# Security, Backup and Continuity

## 1. Security objectives

Revenue Intelligence handles fiscal information and administrative accounts. Official deployment should follow MoF and government IT security policies. This document is a baseline checklist, not a substitute for a formal security assessment.

## 2. Secrets and configuration

Never commit:
- PostgreSQL passwords or connection strings with passwords.
- Supabase service-role keys.
- OAuth client secrets.
- GitHub personal access tokens.
- SSH private keys.
- Backup encryption keys.
- Production API credentials.

Use a government-approved secrets manager or protected environment variables. Rotate credentials if exposure is suspected. The browser must never receive a privileged database or service-role credential.

## 3. Identity and authorization

- Use individual accounts, not shared credentials.
- Apply least privilege.
- Review administrator accounts periodically.
- Require strong authentication and MFA where supported.
- Disable access promptly when staff change roles or leave.
- Log privileged actions.
- Protect account recovery and password reset.
- Apply server-side rate limiting and monitoring.

The repository includes viewer access-code and lockout-related migrations. These controls must be security-reviewed and tested in the actual deployment. Browser-side or IP/browser lockout alone is not a robust authentication boundary.

## 4. Database controls

- Restrict database network access to approved application hosts and administrators.
- Use separate database roles for application runtime, migration and backup.
- Avoid superuser use by the application.
- Review grants, RLS policies and security-definer functions.
- Use parameterized queries.
- Keep production and staging isolated.
- Encrypt backups and restrict their access.
- Log administrative and data-correction operations.

## 5. Data governance

Before moving data, classify:
- Publicly publishable aggregates.
- Internal operational records.
- User account and audit information.
- Raw daily collection records.
- Any data restricted by law or government policy.

Do not assume that a dataset is public merely because the dashboard is accessible. Obtain MoF approval for publication and retention.

## 6. Backups

Define and approve:
- Backup frequency.
- Retention period.
- Encryption and key custody.
- Off-host or separate-site copy.
- Backup monitoring and failure alert.
- Recovery point objective (RPO).
- Recovery time objective (RTO).
- Named recovery owner.

A backup is not proven until it has been restored and checked. Perform periodic restore exercises in a separate environment.

## 7. Continuity and incident response

Maintain:
- Application and database logs.
- Scheduled-job logs.
- Import history.
- Security events.
- Backup status.
- FCGO snapshot freshness.
- A named incident contact and escalation route.

For suspected compromise, preserve evidence, restrict affected accounts or services, notify the designated MoF security authority and follow the approved incident response process. Do not delete logs or make unrecorded database changes.

## 8. Pre-production security gate

Production must not proceed until:
- Secrets scan is clean.
- HTTPS is enforced.
- Authentication and role checks are tested.
- Direct database exposure is blocked.
- Authorization tests pass for every role.
- Privileged functions and grants are reviewed.
- Upload validation and size limits are tested.
- Rate limiting and lockout controls are tested.
- Backup restoration is demonstrated.
- Vulnerability/security assessment is completed.
- MoF IT/security owner signs off.
