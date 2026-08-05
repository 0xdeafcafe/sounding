# SoundCloud integration boundary

SoundingCloud is a personal, independent, unofficial SoundCloud client. It is not
registered as a SoundCloud developer application and does not require an Artist Pro
account.

## Authentication

- Sign-in starts on `m.soundcloud.com/signin` and follows SoundCloud's normal redirect
  to `secure.soundcloud.com`.
- The embedded page is not restyled, scripted, given a disguised user agent, or used to
  replay SoundCloud analytics.
- SoundCloud owns the complete email, password, OTP, TOTP, backup-code, CAPTCHA, and
  identity-provider flow.
- Only after SoundCloud returns to `/signin/callback` may the app inspect the completed
  WebKit cookie session and, when the session exposes sufficient material, store it in
  the user's local/shared credential stores.
- This is a best-effort personal integration. SoundCloud can change or withdraw the web
  session behaviour at any time; the app must fail closed instead of modifying the page
  or bypassing the provider.

## Client identity

- Do not request or require an official SoundCloud application registration for this
  project.
- Do not embed a SoundCloud client secret.
- Do not borrow or impersonate Sonos, SoundCloud's CLI, or another third-party client.
- Any web-derived public client identifier used for public or completed-session requests
  is compatibility material, not a claim that SoundingCloud is an official OAuth client.

## Device auth handoff

Auth handoff is a local, user-approved transfer to one of the user's dependent devices;
it is not SoundCloud OAuth device activation and does not create a SoundingCloud client.
The phone or Mac performs a fresh SoundCloud sign-in for the requesting peer, then sends
that new token pair over the authenticated local Companion channel. The companion keeps
its own session, and the peer stores and refreshes its separate session. The protocol's
legacy `companion_session_request` and `companion_session_offer` wire strings remain only
for compatibility with existing SoundingCloud builds.

## Traffic safety

- A SoundCloud/DataDome challenge, HTTP 403, or HTTP 429 stops polling and API work for
  the persisted block window.
- Honour `Retry-After`; otherwise use a conservative wait.
- Do not rotate identities, disguise traffic, intercept challenges, or retry aggressively.
- Do not generate or replay SoundCloud analytics. SoundCloud's unmodified page may send
  its own telemetry while the user is using it.

## Product expectations

Signed-out public browsing and an authenticated personal session are opportunistic
features, not a supported commercial API contract. The UI and diagnostics should say
when SoundCloud has blocked, changed, or no longer exposes a capability rather than
attempting to work around it.
