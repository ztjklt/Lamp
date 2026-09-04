# Threat and secrets note

- No provider secret is included in the iOS target, plist or repository.
- User JWTs use Keychain-backed storage in the production client.
- Database RLS scopes every user-owned row; privileged writes occur only in authenticated server functions.
- All model-proposed writes are allow-listed, schema-validated, risk-classified and audited.
- High-risk changes require a short-lived confirmation token bound to the preview hash.
- Health/calendar/photo/microphone permissions are optional and requested at point of use.
- Audit logs store action metadata and hashes where possible, not unnecessary raw private content.
- Export and deletion jobs cover database rows, objects, provider identifiers and retained logs according to policy.

