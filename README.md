# SubpathIdentity::Client

Relying-party glue for apps that read identity from another app in a [`subpath_identity`](https://github.com/raghubetina/subpath_identity) cluster — a set of independently deployed Rails apps living under one domain by path (`mydomain.com/`, `mydomain.com/app1`), where only one app owns Rodauth and every other app is a relying party (see [`subpath_identity-provider`](https://github.com/raghubetina/subpath_identity-provider) for that app).

A relying party never authenticates anyone itself. It trusts the shared identity cookie for *who to display*, and — when it needs more than the cookie's claims carry — calls back to the identity-owning app's internal profile API and caches the response locally. This gem is that caching layer.

## Installation

```bash
bundle add subpath_identity-client
```

Then run the installer, which generates a migration and a starting model for the local profile cache:

```bash
rails generate subpath_identity_client:install
rails db:migrate
```

## Usage

Configure which local model the gem should read and write, and how a fetched remote profile maps onto it:

```ruby
# config/initializers/subpath_identity.rb
SubpathIdentity.configure do |config|
  config.local_profile_model = LocalProfile
  config.sync_remote_profile do |profile, remote|
    profile.email = remote[:email]
  end
end
```

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

## Concurrency

The first sync for a given user uses `create_or_find_by`, which is safe against two concurrent first-requests from the same user racing to insert the same row — one wins the insert, the other's `RecordNotUnique` is rescued and re-queried. This *requires* the generated model to have no uniqueness validation on `global_user_id` alongside its unique index; see the comment in the generated model for why.

## Failure handling

`RootProfileClient.fetch` returns `nil` — never raises — on timeout, connection failure, TLS failure, a non-2xx response, or a malformed body. A network hiccup degrades to "keep showing the last cached profile," not a 500.

## Development

`bin/setup`, then `bundle exec rake test`. `bundle exec standardrb` for style.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/raghubetina/subpath_identity-client.

## License

MIT.
