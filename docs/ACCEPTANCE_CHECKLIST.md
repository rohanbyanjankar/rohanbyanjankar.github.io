# Production Acceptance Checklist

Use this checklist in staging before moving Revenue Intelligence to an official MoF production environment. Record evidence, test date, tester and outcome for each item.

## Governance and infrastructure
- [ ] MoF business owner and data owner formally identified.
- [ ] Hosting and data-location approval obtained.
- [ ] Integration route through `data.mof.gov.np` or approved URL confirmed.
- [ ] Staging and production environments separated.
- [ ] TLS, DNS, firewall and monitoring configured.
- [ ] Support and incident escalation owners assigned.

## Source and release
- [ ] Repository commit SHA and release version recorded.
- [ ] Dependencies and runtime versions documented.
- [ ] No credentials or secrets committed.
- [ ] All environment-specific URLs and settings reviewed.
- [ ] Deployment can be repeated from documented instructions.

## Database
- [ ] Live source schema compared with repository migrations.
- [ ] Destination schema reviewed and approved.
- [ ] All required tables, constraints, indexes and sequences exist.
- [ ] All required functions, triggers, grants and policies exist.
- [ ] Source backup completed and restore tested.
- [ ] Source and destination row counts reconciled.
- [ ] Daily, monthly and fiscal-year monetary totals reconciled.
- [ ] Classification rules and both classification levels reconciled.
- [ ] Omit actions reconciled and tested.
- [ ] Targets and manual overrides reconciled.
- [ ] Audit and upload history migration reviewed.

## Authentication and security
- [ ] Viewer, editor and administrator permissions tested.
- [ ] Unauthorized direct API access denied.
- [ ] Privileged secrets absent from browser assets.
- [ ] Account lifecycle and recovery tested.
- [ ] MFA and rate limits configured where required.
- [ ] Lockout behavior tested without relying solely on client-side controls.
- [ ] Security assessment completed and findings resolved.

## Data operations
- [ ] Standard CSV import tested.
- [ ] Original FCGO Excel import tested.
- [ ] Collection date assignment tested.
- [ ] Invalid and negative values rejected.
- [ ] Duplicate date/code rows rejected.
- [ ] Existing descriptions are not silently overwritten.
- [ ] Correction procedure documented and audited.

## Analytics and reporting
- [ ] Total revenue reconciled.
- [ ] Tax and non-tax revenue reconciled.
- [ ] Classification 1 and Classification 2 views tested.
- [ ] Revenue-head drill-down tested.
- [ ] Daily and cumulative comparisons tested.
- [ ] Fiscal-year and prior-year cutoffs tested.
- [ ] Five-year comparisons tested.
- [ ] Monthly and annual targets tested.
- [ ] Growth, share and concentration indicators independently checked.
- [ ] Exports and download restrictions tested.

## FCGO and calendar
- [ ] FCGO API connectivity tested from production network.
- [ ] API series labels/order and units confirmed with FCGO.
- [ ] Stale-data warning tested.
- [ ] Fetch failure alert tested.
- [ ] Official calendar source documents retained.
- [ ] Calendar year inputs independently reviewed.
- [ ] Calendar generator tests pass.
- [ ] Calendar continuity and date mapping verified.
- [ ] Calendar import reconciled with database.

## Operations and continuity
- [ ] Backup schedule enabled.
- [ ] Restore test completed.
- [ ] Logs and monitoring accessible to authorized staff.
- [ ] Incident response procedure approved.
- [ ] User and administrator manuals delivered.
- [ ] Rollback plan tested or rehearsed.
- [ ] Business owner and IT/security owner approve production cutover.

## Sign-off

| Role | Name | Date | Approval |
|---|---|---|---|
| MoF business owner |  |  |  |
| Data owner |  |  |  |
| IT system owner |  |  |  |
| Security reviewer |  |  |  |
| Database administrator |  |  |  |
