# Turn on Sign in with Apple

These steps change production. Merging this PR does not apply them. Use the
Albus project in the Supabase dashboard, and keep these settings in step with
`supabase/config.toml`. Do them when the new app build is ready.

1. Open **Authentication → Sign In / Providers → Apple**. Switch **Enable Sign
   in with Apple** on. Set **Client IDs** to `com.felipegutierrez.albus` and
   save. The app uses native Apple sign-in, so it needs no OAuth secret here.
   Leave manual identity linking enabled so an old anonymous account can add
   Apple without losing its account or work.
2. Open **Authentication → Sign In / Providers → Email**. Switch **Enable email
   provider** off and save. This closes password sign-up and email codes for
   new and existing accounts. Keep the global **Allow new users to sign up**
   setting on: Apple needs it to create accounts. Turning that global setting
   off would also stop new Apple students.
3. Open **Edge Functions → Secrets**. Add these four secrets for the
   `delete-account` function. Claude Code will provide a command that keeps
   their values out of terminal history. Do not paste their values into GitHub,
   source files, screenshots, or this document.

   | Secret name | What to enter |
   |---|---|
   | `APPLE_TEAM_ID` | Your Apple Developer team's identifier |
   | `APPLE_KEY_ID` | The identifier of your Sign in with Apple key |
   | `APPLE_PRIVATE_KEY` | The complete text of that key's downloaded `.p8` file |
   | `APPLE_CLIENT_ID` | The app bundle ID, `com.felipegutierrez.albus` |

   These are server secrets for revoking Apple's tokens during deletion, separate
   from the Apple provider's native sign-in settings. The deploy script will
   check that they exist without printing them.
4. Later, once every tester uses the new build, return to **Authentication →
   Sign In / Providers** and switch **Allow anonymous sign-ins** off. Old
   anonymous sessions keep refreshing, but old builds can no longer create new
   accounts. The new build links those accounts to Apple in place. Local tests
   deliberately keep anonymous sign-ins on.
5. Leave **Authentication → Attack Protection → CAPTCHA protection** off.
   The app has no CAPTCHA. Native Apple ID-token sign-in is exempt from the
   CAPTCHA check, and no other sign-up path remains after step 4.

The local verification script checks password signup, email OTP for new and
existing users, forged Apple token rejection, and anonymous compatibility. CI
runs it on pull requests that change the database, its tests or
`supabase/config.toml`. To run it yourself, start the local stack
(`supabase start`), then from the repository:

```bash
python3 scripts/security/apple-only-signin.py
```

Sources: [native Apple sign-in](https://supabase.com/docs/guides/auth/social-login/auth-apple),
[CLI 2.98.2 email-provider mapping](https://github.com/supabase/cli/blob/v2.98.2/internal/start/start.go),
and [dashboard provider labels](https://github.com/supabase/supabase/blob/master/apps/studio/components/interfaces/Auth/AuthProvidersFormValidation.tsx).
