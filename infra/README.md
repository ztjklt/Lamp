# Lamp production deployment

The deployment order is fixed: apply the additive Supabase migrations, deploy the
Agent Core revision, deploy Edge Functions, run staging smoke tests, and only then
promote the signed build to internal TestFlight.

`cloud-run/service.yaml` is a checked-in template. CI replaces `PROJECT_ID`,
`IMAGE_TAG`, and `SUPABASE_URL_VALUE`; secrets are Secret Manager references and
must never be rendered into the manifest. Staging and production use separate
projects and service accounts. The default region is `asia-southeast1`; choose the
actual Supabase region when it differs.

Rollback uses Cloud Run traffic to the prior revision, redeployment of the prior
Edge Function bundle, and feature flags. Database changes remain forward-compatible
and are not destructively rolled back.
