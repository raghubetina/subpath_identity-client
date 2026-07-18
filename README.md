# SubpathIdentity::Client

Relying-party glue for apps that read identity from another app in a [`subpath_identity`](https://github.com/raghubetina/subpath_identity) cluster — a set of independently deployed Rails apps living under one domain by path (`mydomain.com/`, `mydomain.com/app1`), where only one app owns Rodauth and every other app is a relying party (see [`subpath_identity-provider`](https://github.com/raghubetina/subpath_identity-provider) for that app).

A relying party never authenticates anyone itself. It trusts the shared identity cookie for *who to display*, and — when it needs more than the cookie's claims carry — calls back to the identity-owning app's internal profile API and caches the response locally. This gem is that caching layer.

## Installation

Not yet released to RubyGems, so install from GitHub. This gem's own
dependency on `subpath_identity` (core) also can't resolve from RubyGems
yet, so declare **both** git sources — pin tags for a reproducible build:

```ruby
# Gemfile
gem "subpath_identity", github: "raghubetina/subpath_identity", tag: "v0.3.0"
gem "subpath_identity-client", github: "raghubetina/subpath_identity-client", tag: "v0.3.0"
```

(Once these are published, `bundle add subpath_identity-client` will pull
core in automatically; until then `bundle add` can't resolve either.)

Then run the installer, which generates a migration and a starting model for the local profile cache:

```bash
rails generate subpath_identity_client:install
```

The generated migration has only the two columns this gem manages itself — `global_user_id` and `root_cache_key`. **Before you migrate**, add the profile columns your app actually wants to cache (whatever your `sync_remote_profile` block below will write — `email`, `name`, and so on) to both the migration and the generated model. *Then*:

```bash
rails db:migrate
```

(Migrating first and adding columns later works too, but if your sync block writes `profile.email` against a table with no `email` column, the first profile fetch fails — so add the columns first.)

## Usage

Configure which local model the gem reads and writes, and how a fetched remote profile maps onto it. This has to run inside `to_prepare`, not at the top level of the initializer: `config/initializers/*` load before Zeitwerk's autoloader is set up, so naming `LocalProfile` at the top level raises `NameError`. `to_prepare` runs after boot (and again before each request in development), and re-running it is harmless — `configure` just reassigns the same config object:

```ruby
# config/initializers/subpath_identity.rb
Rails.application.config.to_prepare do
  SubpathIdentity.configure do |config|
    config.local_profile_model = LocalProfile
    config.sync_remote_profile do |profile, remote|
      profile.email = remote[:email]
    end
  end
end
```

(Claims that don't reference an autoloaded constant — `allowed_claims`, `claim_defaults` — can stay at the top level; only the `local_profile_model` reference needs `to_prepare`.)

Then include the concern in `ApplicationController`, after `SubpathIdentity::ControllerHelpers` (from the core gem):

```ruby
class ApplicationController < ActionController::Base
  include SubpathIdentity::ControllerHelpers
  include SubpathIdentity::Client::SyncLocalProfile
end
```

`current_local_profile` is now available in controllers and views. It's `nil` when signed out, and it's *also* `nil` when signed in but the row hasn't been created yet and the provider was unreachable on the fetch that would have created it — a degraded page, not an error.

## How it decides when to refetch

The generated `local_profiles` table has a `root_cache_key` column alongside whatever fields `sync_remote_profile` populates. On each request, if there's no local row yet, or its `root_cache_key` doesn't match the `cache_key` claim on the current shared identity cookie, the gem calls the provider's internal profile endpoint and updates the local row. Otherwise it reads the local row and skips the network call entirely — the common case on every request after the first.

This means the provider app is responsible for bumping `cache_key` (see its own README) whenever the underlying account changes in a way relying parties should notice.

One subtlety that matters for convergence: `root_cache_key` records the **cookie's** `cache_key` claim the row was last synced under, not the `cache_key` the provider returned. The provider can legitimately be *ahead* of the cookie (the account was edited from another device after this browser's cookie was issued) — if the row stored the provider's newer key, it would mismatch the cookie on every request and refetch forever. Storing the cookie's claim converges on the very next request while still keeping the freshest data the fetch returned; when the cookie itself catches up, exactly one more refetch re-marks the row.

The fetch also refuses to apply a response whose `user_id` isn't the one the cookie asserted — a provider routing or cache bug that returns some *other* user's profile degrades like any malformed response instead of being persisted and displayed under the wrong identity.

## Concurrency

The first sync for a given user uses `create_or_find_by`, which is safe against two concurrent first-requests from the same user racing to insert the same row — one wins the insert, the other's `RecordNotUnique` is rescued and re-queried. This *requires* the generated model to have no uniqueness validation on `global_user_id` alongside its unique index; see the comment in the generated model for why.

## Failure handling

`RootProfileClient.fetch` returns `nil` — never raises — on timeout, connection failure, TLS failure, a 401/5xx response, or a malformed body. A network hiccup degrades to "keep showing the last cached profile," not a 500.

It distinguishes one case: an HTTP **410 Gone whose JSON body is `{"error": "account_gone"}`** means "this identity resolves to no valid account" (a closed or deleted account, or an unknown `user_id`) — authoritative rather than transient. `fetch` returns `RootProfileClient::GONE` for that typed response, and `SyncLocalProfile` responds by deleting the local profile row and calling `clear_shared_identity` — which, because the shared cookie is `Path=/`, signs the account out across every app in the cluster on its next request. Everything else stays `nil` and degrades to the cache.

A plain **404 is deliberately not revocation.** 404 says a resource wasn't found without saying which one — a mistyped `internal_profile_path`, a route missing mid-deploy, a stale origin image, or an intermediary's own 404 page all produce it, and treating any of those as "account gone" would destroy cached profiles and sign real users out cluster-wide on an infrastructure hiccup. Only the typed 410 carries revocation semantics; an untyped 410 (an HTML error page, a different error value) doesn't qualify either.

For revocation to work, your provider's internal endpoint must return `410` with `{"error": "account_gone"}` for a closed/deleted/unknown account — not 200 with stale data, and not a bare 404 (see `subpath_identity-provider`'s README for the endpoint pattern). With a provider that still returns 404, nothing breaks: the client just degrades to its cache instead of revoking.

### Revocation is bounded by the cookie TTL

This revocation only fires when a fetch actually happens — i.e. on a `cache_key` mismatch. While the shared cookie's `cache_key` still matches the local row, `SyncLocalProfile` doesn't contact the provider at all (that's the point of the cache), so an account closed elsewhere in a way that doesn't re-encode this visitor's cookie isn't noticed until something forces a fetch, or until the shared cookie reaches its own TTL (`SubpathIdentity.config.cookie_ttl`, 24h by default). Closing that window entirely would mean re-validating with the provider on every request, which defeats the cache. If you need tighter revocation, shorten the TTL.

Worth being explicit about a separate limit here: the TTL bounds how long a closed account is *displayed*, not how long its cached data is *retained*. The `local_profiles` row — including whatever columns your `sync_remote_profile` block copied, like email and name — stays in this app's own database until a `GONE` fetch deletes it, which for the common "cache key never changed" closure never happens. If your requirement is that a closed account's PII be *erased* from relying parties within a bounded time (not merely hidden), this gem's cache doesn't do that on its own — you'd add a periodic revalidation (re-fetch when the row is older than N minutes even on a cache-key match, trading a provider call per user per interval) or a provider-driven purge. For a cluster where the relying parties are the same operator's own apps, indefinite cache retention is usually acceptable; decide deliberately rather than assuming the TTL covers it.

## Development

`bin/setup`, then `bundle exec rake test`. `bundle exec standardrb` for style.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/raghubetina/subpath_identity-client.

## License

MIT.
