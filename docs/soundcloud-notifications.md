# SoundCloud notification integration

Investigated 5 August 2026 against SoundCloud's current public API specification and notification help documentation.

## Finding

SoundCloud does not publish a webhook, notification-subscription, APNs-token, or notification-inbox endpoint for third-party clients. The **Devices** choices on SoundCloud's notification settings page control delivery to SoundCloud's own mobile applications; they cannot be registered to Sounding's bundle or device token.

The current [`/service-worker.js`](https://soundcloud.com/service-worker.js) is not a SoundCloud notification API. Its first-party code caches one JavaScript asset for offline script fallback and serves `offline.html` for failed navigations. It then imports MoEngage's CDN service worker, which adds generic web-push handling (`push`, `notificationclick`, and `notificationclose`) for MoEngage campaigns. That proves SoundCloud has a web-push vendor integration, but it does not expose SoundCloud's campaign credentials, subscription endpoint, payload contract, or a way for Sounding to register its own device. The worker is also implementation detail and may change without notice.

The public API does expose feeds and resources from which some changes can be detected:

- `/me/activities`, `/me/feed`, and their `future_href` cursors can detect new posts and reposts in the signed-in user's feed.
- `/me/followers` can be snapshotted and diffed to detect new followers.
- Track comments, favoriters, and reposters can be diffed for the current user's tracks, but doing this for every track is request-heavy and must use a bounded recent-track window, caching, backoff, and the server's rate-limit response.
- Direct-message support is not part of the public OpenAPI specification. The existing authenticated-session adapter may poll the web inbox where it remains available, with SoundCloud's web inbox as the fallback.
- Recommendations and SoundCloud product/newsletter messages have no documented third-party event source.

## Viable architecture

1. Add a cursor-backed `SoundCloudEventPoller` for feed/activity, follower snapshots, a bounded set of owned-track interactions, and the message inbox.
2. Deduplicate stable event IDs in the encrypted account cache and emit local notifications only for newly observed events after the initial baseline.
3. On macOS, poll while the menu-bar/app process is running, slowing down when idle and respecting 429/reset metadata.
4. On iOS/iPadOS, opportunistic `BGAppRefreshTask` polling is useful but not prompt or guaranteed. Reliable alerts while the app is suspended require a Sounding backend that holds the user's delegated credentials, polls SoundCloud, and sends APNs notifications.
5. Let iPhone notifications forward naturally to Apple Watch, or send APNs to an independent watch app through that same backend. tvOS should surface an in-app activity inbox; it must not be treated as the primary alert destination.

Do not register SoundCloud's private first-party push credentials, copy its device token, scrape notification email, or run aggressive per-track polling. Those approaches are brittle, invasive, or both.

## Official references

- [SoundCloud public API specification](https://developers.soundcloud.com/docs/api/explorer/)
- [SoundCloud API guide](https://developers.soundcloud.com/docs/api/)
- [SoundCloud notification settings documentation](https://help.soundcloud.com/hc/en-us/articles/115003449007-Manage-Email-Push-Notifications)
- [Apple background task guidance](https://developer.apple.com/documentation/BackgroundTasks/refreshing-and-maintaining-your-app-using-background-tasks)
- [Apple Watch notification forwarding](https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding)
