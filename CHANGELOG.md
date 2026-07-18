## [Unreleased]

## [0.2.0] - 2026-07-18

- `RootProfileClient.fetch` now returns `RootProfileClient::GONE` (instead of `nil`) for an HTTP 404, distinguishing a definitive "no valid account" from a transient failure. `SyncLocalProfile` treats `GONE` as revocation: it destroys the local profile row (with `destroy!`, so an aborted callback surfaces rather than silently retaining PII) and calls `clear_shared_identity` (from `subpath_identity`'s `ControllerHelpers`), signing the account out cluster-wide. This only triggers on a `cache_key` mismatch that forces a fetch — see the README's "Revocation is bounded by the cookie TTL," which also documents that cached PII is *retained* in the local table until then, separate from display revocation.
- Requires `subpath_identity >= 0.2` — it calls the new `clear_shared_identity` helper and speaks the v2 cookie format.

## [0.1.0] - 2026-07-16

- Initial release
