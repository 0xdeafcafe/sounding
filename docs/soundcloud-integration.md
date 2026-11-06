# SoundCloud integration boundary

Sounding is a personal, independent, unofficial SoundCloud client. It is not
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
- An API 401 first triggers one coalesced refresh and one replay of the original request.
  An explicit OAuth refresh rejection such as `invalid_grant` stops duplicate refresh
  attempts, then the existing access token is checked against `/me`. The session only
  requires reconnection when that canonical account check also rejects it; HTTP status
  alone is not treated as proof that the user's authorization is gone.
- If the original endpoint still returns 401 after a successful refresh, the fresh token
  is checked against `/me`. A valid `/me` response keeps the account and treats the first
  endpoint as unavailable; an inconclusive probe remains retryable; only a rejected probe
  makes reauthentication necessary.
- Network failures, HTTP 403/429, server failures, and ambiguous token responses preserve
  the credential and cached account data. They enter a retryable state, observe the
  gateway cooldown, and retry on a later foreground account request instead of signing
  out or restarting library ingestion.

## Client identity

- Do not request or require an official SoundCloud application registration for this
  project.
- Do not embed a SoundCloud client secret.
- Do not borrow or impersonate Sonos, SoundCloud's CLI, or another third-party client.
- Any web-derived public client identifier used for public or completed-session requests
  is compatibility material, not a claim that Sounding is an official OAuth client.

## Device auth handoff

Auth handoff is a local, user-approved transfer to one of the user's dependent devices;
it is not SoundCloud OAuth device activation and does not create a Sounding client.
The phone or Mac performs a fresh SoundCloud sign-in for the requesting peer, then sends
that new token pair over the authenticated local Companion channel. The companion keeps
its own session, and the peer stores and refreshes its separate session. The protocol's
legacy `companion_session_request` and `companion_session_offer` wire strings remain only
for compatibility with existing Sounding builds.

## Traffic safety

- `SoundCloudGateway` is the control-plane boundary for API calls, stream resolution,
  token refresh, waveform documents, and HLS media requests. AVPlayer and the background
  download session may own long transfers only after the gateway admits the CDN URL.
- OAuth is attached only to exact HTTPS API hosts. Redirects cannot leave their trusted
  API/CDN host class, and API sessions do not share browser cookies or URL credentials.
- A verified SoundCloud/DataDome challenge or HTTP 429 stops all SoundCloud API work for
  the persisted block window. An ordinary HTTP 403 is endpoint-specific: it cools down
  that request lane without incorrectly disabling playback and unrelated API surfaces.
- Honour `Retry-After`; otherwise use a conservative wait.
- Concurrent identical GETs are coalesced, near-duplicate successful GETs receive a tiny
  bounded replay window, autonomous work is paced, and autonomous API polling is rejected
  unless the application is in the foreground.
- The activity poller never probes the undocumented Conversations endpoint. Its feed and
  follower attempts are timestamped even when they fail, preventing a failed source from
  being retried on every lifecycle tick.
- Likes top-up runs at most hourly while foregrounded. The saved-library catalogue runs
  at most once per day and records its attempt before the first request, so a relaunch
  cannot restart an interrupted archive walk.
- Autonomous playlist-manifest hydration is forbidden. Playlist tracks are hydrated on
  demand when the user opens, pins, downloads, or plays a playlist; this avoids expanding
  a large library into hundreds of background `/tracks?ids=` calls.
- Do not rotate identities, disguise traffic, intercept challenges, or retry aggressively.
- Do not generate or replay SoundCloud analytics. SoundCloud's unmodified page may send
  its own telemetry while the user is using it.

## Same-account peer content

- Pairing TLS-PSK proves device possession, but pairing alone is not account authorization.
- Every content range request and response carries a fresh HMAC proof derived locally from
  the verified SoundCloud credential. The proof binds the account id, request id, byte
  range, response metadata, and response-body digest; the access token is never sent over
  the LAN. Servers reject stale or replayed requests.
- The current implementation intentionally fails closed when SoundCloud issued different
  access tokens for the same account. Supporting independent tokens without revealing them
  requires a trusted service to verify each token and issue a short-lived, signed account
  attestation. Until that exists, peer reuse is available only when session sync has given
  both devices the same credential.

## Product expectations

Signed-out public browsing and an authenticated personal session are opportunistic
features, not a supported commercial API contract. The UI and diagnostics should say
when SoundCloud has blocked, changed, or no longer exposes a capability rather than
attempting to work around it.
