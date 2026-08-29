# trustctl

`trustctl` is the optional single-host installer and maintenance CLI for
Coeval and Ironside. It is deployment tooling, not part of either product's
runtime or authorization model.

Status: **supported initial release** for new single-host installations.
Coeval v0.2.0 and Ironside v0.2.0 publish versioned self-host bundles, all five
application images allow anonymous pulls, and the exact public installer
command has passed the clean-runner smoke workflow.

## Support boundary

- **TARGET:** Linux, Docker Engine, Docker Compose v2, one host, and exact
  semantic application versions.
- **CURRENT:** `install`, `status`, `doctor`, update checking, explicit
  one-product-at-a-time updates, and logs are implemented.
- **CURRENT:** updates require an explicit confirmation that current off-host
  backups exist. `trustctl` does not yet create, restore, or prove backups.
- **CURRENT:** automatic rollback is intentionally absent. A new application
  may already have applied a forward database migration by the time a health
  check fails.
- **ASSUMPTION:** the default services bind to loopback and an operator places
  a TLS reverse proxy in front before exposing them publicly.

Coolify, Kubernetes, Helm, GitOps, Portainer, and other control planes remain
separate deployment methods. They can reuse the same images and release
contracts, but `trustctl` does not take credentials for them.

## One-line bootstrap

The public entry point is:

```sh
curl -fsSL https://raw.githubusercontent.com/luka-zivkovic/trustctl/main/install.sh \
  | sh -s -- install stack
```

Install one product instead:

```sh
curl -fsSL https://raw.githubusercontent.com/luka-zivkovic/trustctl/main/install.sh \
  | sh -s -- install coeval
```

The bootstrap downloads `bin/trustctl`, verifies its SHA-256 checksum, and
runs it. A checksum fetched from the same repository detects corruption but is
not a substitute for a separately rooted signature. Users who do not want to
pipe code into a shell can download and inspect both files before running the
CLI.

`.github/workflows/end-to-end.yml` runs that exact public command on a fresh
GitHub-hosted Ubuntu runner, checks both public health routes, runs
`trustctl doctor` and update discovery, and exercises Ironside owner setup. It
is manually dispatched after product publication so an incomplete release
cannot make the ordinary pull-request suite flaky.

The default installation directory is `./ai-trust-stack`. Use `--root` to
choose another location. The installer creates independent Compose projects
for Coeval and Ironside so their data, networks, and lifecycle remain
separate.

## Install options

```sh
trustctl install stack \
  --coeval-version 0.2.0 \
  --ironside-version 0.2.0 \
  --root /srv/ai-trust-stack
```

Without explicit versions, the CLI selects GitHub's latest published,
non-prerelease exact `vX.Y.Z` release. Draft releases are invisible to default
installs, which prevents a tag from being selected while its images are still
publishing. The CLI never selects a branch, container `latest`, or another
floating reference.

By default, Ironside listens on `127.0.0.1:8080` and Coeval on
`127.0.0.1:8081`. For an existing reverse proxy:

```sh
trustctl install stack \
  --bind-address 127.0.0.1 \
  --ironside-url https://ironside.example.com \
  --coeval-url https://coeval.example.com
```

Use `--no-start` to generate and validate the installation without pulling or
starting containers.

## Operations

```sh
/srv/ai-trust-stack/trustctl status
/srv/ai-trust-stack/trustctl doctor
/srv/ai-trust-stack/trustctl update --check
/srv/ai-trust-stack/trustctl logs ironside --follow
```

Apply one exact product update at a time:

```sh
/srv/ai-trust-stack/trustctl update ironside \
  --version 0.2.1 \
  --backup-confirmed
```

Preflight a release without changing the installed version or containers:

```sh
/srv/ai-trust-stack/trustctl update ironside \
  --version 0.2.1 \
  --preflight-only
```

The update flow:

1. validates the installed managed Compose file and operator environment;
2. downloads and checksum-verifies the target release bundle;
3. renders the target configuration with existing secrets and overrides;
4. pulls every target image before changing installed state;
5. records the old Compose definition and version in `.trustctl/history/`;
6. changes the exact version and recreates the affected stack; and
7. waits for the public health endpoint.

If deployment or health fails after the new version is selected, `trustctl`
records the failure and stops. It does not start older images automatically.
Follow the product release notes: use a documented forward fix, or restore all
affected data stores before starting the old version.

Only one update may run in an installation at a time. `--preflight-only`
performs the verification, render, and pull steps and records the attempt, but
leaves active Compose, environment, and containers untouched. Explicit version
downgrades are rejected because safe recovery depends on the release's
migration contract.

## Configuration ownership

Each installed product directory contains:

```text
compose.yaml             release-owned; do not edit
compose.override.yaml    operator-owned and preserved across updates
.env                     operator configuration, secrets, and exact version
```

`trustctl` records the managed Compose checksum and refuses to update after a
local edit. Move intentional changes into `compose.override.yaml`. Back up the
`.env` files separately from database backups: Coeval's auth secret and
Ironside's encryption secret are required to recover encrypted credentials.

## Deliberate omissions in v0.1

- no automatic or scheduled updates;
- no automatic backup or restore;
- no image rollback after a failed health check;
- no uninstall or volume-deletion command;
- no multi-host, rolling, or high-availability orchestration;
- no adoption of arbitrary pre-existing Compose installations; and
- no hosting-platform credentials or Docker socket exposed to either app.

See [the maintenance contract](docs/maintenance-contract.md) for the state and
failure model.
