# T028 staging deployment record

Copy this file to a dated record only after an actual deployment. Keep values
limited to non-secret identifiers. Never record an account ID, full ARN, DB host,
credential, OAuth secret, or personal test account.

## Immutable inputs

- repo revision: `pending`
- GitHub workflow run ID / attempt: `pending`
- workflow head SHA matches repo revision: `pending`
- clean ARM64 `buildx --push`: `pending`
- infrastructure revision: `pending`
- infrastructure template SHA-256: `pending`
- image digest (`sha256:...`, repository URI omitted): `pending`
- previous healthy release: `none | pending`
- previous healthy digest (`sha256:...`): `none | pending`
- previous digest differs from candidate: `pending`
- deployment bundle key: `pending`
- deployment bundle VersionId: `pending`
- deployment bundle SHA-256: `pending`
- workflow `previous_digest` output: `none | pending`
- injected `SHINDANG_ENV`: `staging`
- public staging origin: `pending`

## Infrastructure

- CloudFormation validation time (UTC): `pending`
- change-set review result: `pending`
- apply time (UTC): `pending`
- stack result: `pending`
- instance SSM online: `pending`
- public ingress verified as only 80/443: `pending`
- static AWS credential absent: `pending`

## HTTPS and OAuth smoke

- TLS certificate/redirect verified at (UTC): `pending`
- `GET /healthz`: `pending`
- `GET /readyz`: `pending`
- `GET /api/auth/providers`: `pending`
- remote forward smoke (`healthz`, `readyz`, `api/auth/providers`): `pending`
- Google callback result (test identity omitted): `not-configured | pending | pass`
- Kakao callback result (test identity omitted): `not-configured | pending | pass`
- OAuth state cookie removed after callback: `pending`
- session cookie (`Secure`, `HttpOnly`, `SameSite=Lax`): `pending`
- auth code/token/provider subject absent from record and logs: `pending`

## Rollback drill

- previous release is not `none`: `pending`
- previous digest differs from candidate: `pending`
- candidate digest: `pending`
- restored digest: `pending`
- rollback SSM command ID: `pending`
- rollback start/end (UTC): `pending`
- post-rollback health/readiness/API smoke: `pending`
- post-rollback OAuth smoke: `pending`
- automatic rollback status recorded by workflow: `not-required | healthy | failed`

## Scope assertion

- migration 003-005 executed: `no`
- DB role/schema/data write executed: `no`
- secrets/account identifiers present in this record: `no`
