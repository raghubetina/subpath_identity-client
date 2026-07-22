## [Unreleased]

## [0.7.0] - 2026-07-22

- **Revocation now fails closed when the cached row can't be deleted.** The shared cookie is cleared and `current_local_profile` nulled *before* row cleanup is attempted, and a cleanup failure is reported to the app's error reporter (`Rails.error`, severity `:error`, source `"subpath_identity-client"`) and swallowed instead of raising. Previously a host schema that blocked the `DELETE` — any inbound foreign key without `on_delete: :cascade` — raised `InvalidForeignKey` ahead of `clear_shared_identity`, so a definitively closed account stayed signed in and 500ed on every request, forever, with its cached PII retained.
- **New override point: `remove_local_profile_rows(model, global_user_id)`.** The default stays a plain `delete_all` (no column nulling, erases the cached PII, no callbacks); hosts whose schemas reference the profile model can override it in the including controller for cleanup a cascade can't express (dependent rows, polymorphic references, attachments). The contract is documented in the README ("What revocation assumes about your schema") and flagged in the generated model.
- **README's install block pinned a core tag that doesn't exist** (`v0.6.0`; core's latest is `v0.5.1`) — the documented Gemfile couldn't bundle at all. Fixed, and CI now extracts the README's install block into a clean Gemfile and runs `bundle lock` on it (`bin/check-readme-install`), so a documented tag that doesn't resolve fails the build. Release flow note: push `main` and the new tag together, since the README names the tag being cut.
- Docs: the revocation-timing contract is now stated precisely — *immediate at the provider, monotonic in the app that observed the typed 410, TTL-bounded everywhere else.* The previous claim that a marker landing after the post-upsert recheck "self-heals on the next request" was true only for the discovering app; cluster-wide, the stale response's cookie reissue races the revoking response's deletion at the browser (RFC 6265 leaves concurrent `Set-Cookie` ordering undefined), and a lost race leaves other apps honoring the cookie until its absolute deadline — the same exposure as a browser that never visits the discovering app, since the reissue never renews the deadline. No code change closes that window server-side; the deadline is the invariant.

## [0.6.0] - 2026-07-21

- **Revocation now uses a separate marker table, `subpath_identity_client_revocations`, and deletes the cached profile row** instead of tombstoning it in place. The in-row tombstone (0.5.0) was fragile: nulling a cached column to blank PII raised on a `NOT NULL`/validated/optimistically-locked schema (a definitive revocation became a 500), and a bare marker couldn't be inserted for a first-visit gone account at all. Deleting the row erases the PII with no such hazard, and the separate durable marker survives a stale in-flight success (which can recreate the row) so revocation is monotonic against result order — verified across both `partial_updates` settings. **Requires a new table** — `subpath_identity_client:install` creates it; an existing install needs a migration creating `subpath_identity_client_revocations` (`global_user_id`, unique index) and, if it added the 0.5.0 `revoked_at` column, may drop it.

## [0.5.0] - 2026-07-21

- **Revocation now tombstones the local row instead of deleting it.** The provider fetch has no per-user lock, so an older in-flight success could resume after a newer revocation and `create_or_find_by` a fresh row — resurrecting a closed account. A revoked row is now kept with `revoked_at` set (and its cached columns blanked, erasing the PII), and a later fetch refuses to overwrite it, making revocation monotonic against result order. **Requires a new `revoked_at` column** — `subpath_identity_client:install` adds it; an existing install needs a migration adding `t.datetime :revoked_at` to `local_profiles`.
- Core dependency floor raised to `>= 0.5`: this gem reissues the shared cookie in a `before_action` and the app's action may write it again, which only composes correctly on core 0.5.0's memo-updating `write_shared_identity` (an older core would discard the first write).

## [0.4.0] - 2026-07-21

- **Multi-browser convergence: the row stores the provider's authoritative `cache_key`, and the requesting browser's shared cookie is reissued with it after a fetch.** 0.3.0's fix (recording the requesting cookie's claim) converged for one browser but oscillated with two: a single shared row can't represent two browsers' different still-valid claims, so alternating requests forced a provider call and a row write every time. Now each stale browser pays for exactly one fetch. The reissue never extends the identity's lifetime — it relies on core >= 0.4's deadline-preserving `write_shared_identity`, which is why the core dependency floor rises to `>= 0.4` (wire format v3; all apps in the cluster upgrade together).
- `required_ruby_version` raised to `>= 3.3` and CI runs the declared floor against the committed lockfile (the lock pins `parallel 2.1.0`, whose own floor is Ruby 3.3 — the previously declared 3.2 couldn't `bundle install` from a fresh clone).

## [0.3.1] - 2026-07-18

- Declared Rails floors raised to `>= 8.1` (activesupport/activerecord/railties) — the toolchain CI actually tests. Rails 7 was never deliberately supported, only inherited from scaffolding defaults; the 0.3.0 floor-CI rig (`gemfiles/rails_7.gemfile`, the Ruby 3.2 job, the sqlite3 `>= 1.4` loosening) is removed.

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
