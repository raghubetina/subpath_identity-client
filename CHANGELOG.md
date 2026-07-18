## [Unreleased]

## [0.3.0] - 2026-07-18

- **`RootProfileClient.fetch` now takes a required `expected_user_id:` keyword** and returns `nil` for a response whose `user_id` doesn't match it — a provider routing/cache/serialization bug can no longer persist and display one account's profile under another account's identity.
- **Revocation protocol is now a typed 410, not a bare 404.** `fetch` returns `GONE` only for HTTP 410 with a JSON body of `{"error": "account_gone"}`; an untyped 404 (wrong path, route missing mid-deploy, stale origin image, intermediary error page) degrades to `nil` instead of destroying the cached profile and signing the user out cluster-wide. Pair with a provider whose internal endpoint returns the typed 410 (see `subpath_identity-provider`'s README); against an old 404-returning provider the client safely degrades to its cache instead of revoking.
- **`root_cache_key` now records the cookie's `cache_key` claim, not the provider's.** The provider can legitimately be ahead of the browser cookie (an edit from another device); storing the provider's newer key made every subsequent request mismatch the cookie and refetch on every page load until the cookie was reissued. Storing the cookie's claim converges on the next request while keeping the freshest fetched data.
- CI now tests the declared floor (Ruby 3.2 / Rails 7.0) alongside the current toolchain, via `gemfiles/rails_7.gemfile`; the dev/test sqlite3 pin is loosened to `>= 1.4` (Active Record 7.0's adapter needs 1.4.x).

## [0.2.1] - 2026-07-18

- `RootProfileClient.fetch` now returns `nil` for a 2xx response whose body parses as valid JSON but isn't a usable profile — a bare `true`/number/string/array, or an object missing `user_id`/`cache_key`. Previously such a body was returned as a truthy non-`Hash`, and `SyncLocalProfile` would then call `remote[:cache_key]` on it and raise (a 500 on a page that's supposed to degrade to the cache). Only syntactically invalid JSON was caught before.
- Install docs now use a GitHub source (the gems aren't on RubyGems yet, so `bundle add` can't resolve them).

## [0.2.0] - 2026-07-18

- `RootProfileClient.fetch` now returns `RootProfileClient::GONE` (instead of `nil`) for an HTTP 404, distinguishing a definitive "no valid account" from a transient failure. `SyncLocalProfile` treats `GONE` as revocation: it destroys the local profile row (with `destroy!`, so an aborted callback surfaces rather than silently retaining PII) and calls `clear_shared_identity` (from `subpath_identity`'s `ControllerHelpers`), signing the account out cluster-wide. This only triggers on a `cache_key` mismatch that forces a fetch — see the README's "Revocation is bounded by the cookie TTL," which also documents that cached PII is *retained* in the local table until then, separate from display revocation.
- Requires `subpath_identity >= 0.2` — it calls the new `clear_shared_identity` helper and speaks the v2 cookie format.

## [0.1.0] - 2026-07-16

- Initial release
