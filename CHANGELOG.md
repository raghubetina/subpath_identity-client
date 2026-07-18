## [Unreleased]

- `RootProfileClient.fetch` now returns `RootProfileClient::GONE` (instead of `nil`) for an HTTP 404, distinguishing a definitive "no valid account" from a transient failure. `SyncLocalProfile` treats `GONE` as revocation: it destroys the local profile row and calls `clear_shared_identity` (from `subpath_identity`'s `ControllerHelpers`), signing the account out cluster-wide. This only triggers on a `cache_key` mismatch that forces a fetch — see the README's "Revocation is bounded by the cookie TTL."

## [0.1.0] - 2026-07-16

- Initial release
