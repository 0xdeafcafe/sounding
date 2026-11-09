# SoundCloud sign-in: the official app's PKCE flow (documented, not adopted)

Status: **not adopted** (decision 2026-11-06). Sounding stays on its current sign-in, which loads `https://m.soundcloud.com/signin` in a web view and captures the session the mobile website creates. This file records the alternative so it can be revisited.

## What the official SoundCloud iOS app does
It opens a standard OAuth 2.0 authorisation-code flow with PKCE:

```
https://secure.soundcloud.com/web-auth
  ?app_id=124
  &client_id=oDuGHdoKZgaZtpROWLLAJpikJUoEV2dr
  &code_challenge=<BASE64URL(SHA256(code_verifier))>
  &code_challenge_method=S256
  &device_id=<UUID, stable per install>
  &redirect_uri=soundcloud://auth
  &response_type=code
  &start_view=sign_in
  &state=<random, verified on return>
  &theme=dark
  &ui_evo=true
  &stand_alone=true
  &tracking=local
  &provider_redirect=true
  &ignore_autofocus=true
  &locale=en
  &sc_tracking_anonymous_id=<UUID>
```

Then:

1. The page redirects to `soundcloud://auth?code=<code>&state=<state>`. Check that `state` matches the value sent.
2. POST to `https://secure.soundcloud.com/oauth/token` (`grant_type=authorization_code`, `code`, `code_verifier`, `redirect_uri`, `client_id`). The response holds an `access_token`, a `refresh_token` and `expires_in`.
3. Refresh with `grant_type=refresh_token` at the same endpoint. This is what `SoundCloudTokenRefresh` in `TokenTransferProtocol.swift` already does.

`code_challenge`, `state`, `device_id` and `sc_tracking_anonymous_id` are generated fresh by each client and install. Never reuse values captured from another device's URL.

## Why it was considered
- Proper OAuth tokens and refresh, instead of a scraped website session.
- Likely different, and possibly higher, rate limits than the mobile-web client.
- Fewer of the sign-out and renewal problems traced in `SessionRenewal.swift`.

## Why it was not adopted
- **Impersonation.** It uses SoundCloud's first-party app identity (`app_id=124`, its `client_id`, the `soundcloud://` redirect). To SoundCloud, Sounding would be their own iPhone app.
- **Fragility.** If SoundCloud rotates or restricts that client, sign-in breaks with no warning.
- **Redirect conflict.** With the official app installed, iOS may route `soundcloud://auth` to it. `ASWebAuthenticationSession` with `callbackURLScheme: "soundcloud"` usually captures it in-session, but that isn't guaranteed.
- **App Review and terms.** Posing as another company's app is a likely rejection under guideline 5.2 for a public App Store release, and a terms-of-service risk.

## If it is ever revisited
- Prefer a TestFlight-only build flag (`SOUNDING_PKCE_SIGNIN`), keeping the web sign-in as the App Store path and the fallback.
- Use `ASWebAuthenticationSession` (iOS/macOS) with `prefersEphemeralWebBrowserSession = false`, so SoundCloud's cookies can make re-auth silent.
- Hand tokens to tvOS and watchOS through the existing Link and Companion transfer. Those platforms have no web view.
- Keep the rules in `SessionRenewal.swift`: adopt newer peer or iCloud sessions before refreshing, and push rotated tokens immediately.
