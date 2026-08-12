# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## v0.3.0 (2026-08-12)
### Breaking Changes:

* byte range handling per RFC 7233 (#42) by James Harton



### Improvements:

* replace `mix_audit` with `mix hex.audit` (#44) by James Harton

* add `:service_unavailable` and `:slow_down` error codes (#43) by James Harton

## v0.2.3 (2026-07-08)




### Bug Fixes:

* let dispatch exceptions bubble up to Plug (#36) by James Harton

## v0.2.2 (2026-05-09)




### Bug Fixes:

* conditionally compile `firkin.serve` mix task in dev/test only (#4) by James Harton

## v0.2.1 (2026-04-21)




### Bug Fixes:

* preserve trailing slash in object keys for folder markers (#3) by James Harton

* stop double-encoding the SigV4 canonical URI (#2) by James Harton

## v0.2.0 (2026-04-21)




### Features:

* emit telemetry events for S3 requests (#1) by James Harton

## v0.1.0 (2026-04-21)




### Features:

* add `mix firkin.serve` task and promote `Firkin.Backends.Memory` by James Harton

* extract S3-compatible server as `Firkin` from neonfs s3_server by James Harton
