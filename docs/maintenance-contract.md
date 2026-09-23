# trustctl maintenance contract

## Ownership

`trustctl` owns only installations containing its versioned
`.trustctl/state.env` record. It does not adopt arbitrary Compose files or
infer that similarly named containers belong to it.

Each product owns its release Compose bundle. `trustctl` verifies and installs
that bundle, preserves a separately owned override file and secrets, and uses
the product's public health endpoint as the final runtime signal.

## Installation state

An installation records:

- state format version;
- whether Rubrist, Ironside, or both were installed;
- independent Compose project names;
- exact application versions in product `.env` files;
- checksums of the release-owned Compose files; and
- update attempts under `.trustctl/history/`.

The database and object-storage contents remain authoritative application
state. The trustctl state directory is an operations ledger, not a data backup.

## Update state machine

```text
installed
  -> preflighted
  -> target bundle verified
  -> target Compose rendered
  -> target images pulled
  -> target selected
  -> containers recreated
  -> healthy
```

Failure before `target selected` leaves the installed version unchanged.
Failure afterward leaves the target selected and records `deploy-failed` or
`health-failed`. This is deliberate: application startup may already have
applied a forward migration, so an automatic image downgrade could compound
the failure.

An installation-wide lock serializes update and update-preflight operations.
A preflight verifies the target bundle, renders it with the current instance
configuration, pulls its images, and records the attempt without selecting the
target. Version downgrades are not an update operation and are rejected.

## Backup boundary

`--backup-confirmed` is an operator assertion, not backup evidence. Until
trustctl has store-specific backup creation and restore drills, it cannot
honestly report that an installation is recoverable.

The required data differs by product:

- Rubrist: PostgreSQL plus `RUBRIST_AUTH_SECRET`.
- Ironside: PostgreSQL, ClickHouse, object storage, and
  `IRONSIDE_ENCRYPTION_SECRET`. Redis is recoverable queue/cache state when the
  durable object-storage intent log is intact.

## Compatibility boundary

Rubrist and Ironside have independent versions. A combined installation does
not imply that matching version numbers are required. v0.2 applies updates one
product at a time and points the operator to each release note. A future stack
manifest may name a tested pair, but trustctl must not invent compatibility in
its absence.

## Security boundary

- Product APIs never receive Docker access or host-control credentials.
- Generated secret files use owner-only permissions.
- Managed Compose changes fail closed on checksum mismatch.
- Version inputs accept exact `X.Y.Z` values only.
- Update lookup is optional and contains no installation telemetry.
- No command deletes volumes.
