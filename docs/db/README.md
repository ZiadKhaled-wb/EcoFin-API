# Database

## Fresh install

1. Create a Supabase project.
2. Open the SQL Editor.
3. Run `initialization-v2.1.sql` in full. This creates the entire schema,
   RLS policies, helper functions, the `activate_workspace` RPC, and role
   grants.
4. Run `seed-first-super-admin.sql` after you've created the first super
   admin auth user in the dashboard.

## Existing install

Run any files in `../../migrations/` that haven't yet been applied to
that database. Each migration's header records where it has run.

## Testing RLS

The SQL Editor runs as `postgres`, which bypasses RLS. To actually test
RLS policies, use the PostgREST endpoint with a real JWT:

    $url = "https://<project>.supabase.co/rest/v1/employees?select=*"
    Invoke-RestMethod -Uri $url -Headers @{
        apikey        = $anonKey
        Authorization = "Bearer $userJwt"
    }

Zero rows for a tenant that owns no employees. Only that tenant's rows
otherwise. See ADR-0004 for the verification procedure.

## What's not included

- Payroll tables (v2)
- ETA e-invoice tables (design when the integration lands)
- Feature flag state
- Offline sync tables