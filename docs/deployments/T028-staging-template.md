# T028 staging deployment record

Copy this file to a dated record only after an actual deployment. Keep values
limited to non-secret identifiers. Never record an account ID, full ARN, DB host,
credential, OAuth secret, or personal test account.

## Immutable inputs

- repo revision: `pending`
- infrastructure revision: `pending`
- image digest (`sha256:...`, repository URI omitted): `pending`
- previous healthy digest (`sha256:...`): `none | pending`
- deployment bundle key: `pending`
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
- Google callback result (test identity omitted): `not-configured | pending | pass`
- Kakao callback result (test identity omitted): `not-configured | pending | pass`

## Rollback drill

- candidate digest: `pending`
- restored digest: `pending`
- rollback start/end (UTC): `pending`
- post-rollback health/readiness/API smoke: `pending`

## Scope assertion

- migration 003-005 executed: `no`
- DB role/schema/data write executed: `no`
- secrets/account identifiers present in this record: `no`
