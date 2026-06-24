# ea-podman overview (shared reference for the web-app PoCs)

`ea-podman` is cPanel's wrapper around **rootless podman**: it lets a cPanel user
run a container under their own unprivileged account, supervised by a per-user
`systemd` unit. This document collects the universal `ea-podman` material that
both proofs of concept rely on:

- the [static (build-only) PoC](./static-podman.md) (CPANEL-53969), and
- the [non-static (long-running) PoC](./non-static-podman.md) (CPANEL-53968).

Each PoC links here for prerequisites, install mechanics, the direct-SSH
requirement, and the security posture, and documents only what is specific to its
serving model.

> **Provenance.** Everything here is validated against the `ea-podman` source
> (`SOURCES/ea-podman.pl`, `SOURCES/util.pm` in `github.com/CpanelInc/ea-podman`;
> paths below refer to the installed `…/lib/ea_podman/util.pm`). Facts marked **✓**
> were additionally **exercised on a live cPanel server** while running the static
> PoC; unmarked facts are source-validated only.

## What `ea-podman` does

`ea-podman` lets a cPanel user run a container under their own unprivileged
account, managed much like an EA4 package. Given an image, `install`:

- registers and names the container and creates its per-user directory,
- allocates any requested container port to a host port via the cPanel port
  authority,
- persists the container's configuration, and
- supervises the container with a per-user `systemd` unit, exposing lifecycle
  commands (`start`/`stop`/`restart`/`status`/`backup`/…).

See [How `ea-podman` install works](#how-ea-podman-install-works) and
[Lifecycle and subcommands](#lifecycle-and-subcommands) below for the details.

## Prerequisites

- **EA4 `ea-podman` package installed** on the server.
- **Unprivileged user namespaces enabled** (`user.max_user_namespaces > 0`).
  Rootless podman maps the user's `subuid`/`subgid` ranges through a user
  namespace, so this must be non-zero or `ea-podman`/`podman` commands fail up
  front with `❌ User Namespaces not available`. Stock EL ships a large default
  (confirmed non-zero on the live server ✓); hardened images sometimes zero it
  out. Enable and persist it as root:

  ```bash
  sysctl user.max_user_namespaces             # 0 or empty = disabled
  sysctl -w user.max_user_namespaces=15000    # enable now
  echo 'user.max_user_namespaces = 15000' > /etc/sysctl.d/99-rootless-podman.conf
  sysctl --system                             # persist across reboots
  ```
- **`subuid` / `subgid`** ranges for the cPanel user (rootless user-namespace
  mapping). `ea-podman install` allocates these automatically on first use ✓;
  provision/inspect explicitly with `ea-podman subids --ensure`. Any `ea-podman`
  subcommand triggers allocation; a **raw `podman` command does not**.
- A **real bash login shell** for the cPanel user (not `jailshell`/`noshell`) —
  set it as root with `whmapi1 modifyacct user=<user> shell=/bin/bash` (the API
  behind WHM » Manage Shell Access). See [Connecting](#connecting-use-direct-ssh)
  below. ✓
- **`systemd`** present — user-level units supervise the container.
- **Apache reverse-proxy modules** — `mod_proxy`, `mod_proxy_http`, and
  `mod_headers` — enabled. Both PoCs wire the subdomain to the container's
  published host port with the same Apache reverse-proxy include (`ProxyPass` /
  `ProxyPassReverse` plus a `RequestHeader` for `X-Forwarded-Proto`), so all
  three are required. Confirmed loaded on the live server ✓.
- **Lingering** (`loginctl enable-linger <user>`, as root) so the user's `systemd`
  manager — and its containers — keep running with no active login session.
  **Enable it yourself.** Contrary to what you might expect, `ea-podman` only turns
  linger on in its `su`-fallback path (`util.pm` `ensure_su_login`), which is
  **skipped when you connect via direct SSH**; after a normal SSH-based install
  `Linger` stays `no`. ✓ Without it, the user manager runs only while a login
  session is open, so a long-running container **stops the moment your last SSH
  session closes** (verified: `Linger=no` after an SSH install, and the container
  went down — taking a reverse-proxied site to `503` — once the session ended).
  A purely one-shot/build container would not need linger; the persistent
  services in **both** PoCs do.
- A **pullable container image** (the PoCs use `docker.io/library/node:20-alpine`).

> A few prerequisites are **specific to one PoC** and stay in its doc: the
> **static** PoC needs outbound access to the package registry (its build runs
> `npm install`), and the **non-static** PoC builds a local image, which requires
> the user's `subuid`/`subgid` ranges to exist *before* the first `podman` command
> (run `ea-podman subids --ensure` first).

## Connecting: use direct SSH

Reach the cPanel user with **direct SSH** so you land in a **real bash login
session**:

```bash
ssh cptest1@SERVER_IP
```

> **Do not** use `su -` or `jailshell` to reach the user — rootless podman does
> not get a usable session that way and its commands fail. A **direct SSH login**
> does (it yields a working `XDG_RUNTIME_DIR=/run/user/<uid>`). ✓ Per the
> `ea-podman` maintainers, this `su`/jailshell gap is a known, not-yet-prioritized
> limitation that will be solved for the shipped feature; for the PoC, just connect
> directly. (Linger is a separate concern — see Prerequisites.)

## Running an arbitrary image

The PoCs run stock upstream images (e.g. `node:20-alpine`) rather than vetted EA4
container packages. An **arbitrary image** simply means any image that is *not* an
`ea-podman`/EA4 container **package** — the term is about packaging, not about tags
or versions. Two rules apply:

- **Arbitrary images require `--i-understand-the-risks-do-it-anyway`.** Without
  it, `install` refuses to run a non-package image. ✓
- **The final argument must look like an image name** — and how you pass a command
  depends on whether you also publish a port:
  - `install` checks only that the **last** start arg matches an image-name regex
    (`util.pm` `validate_start_args`: *"Last start arg does not look like an image
    name"*). A command given as a single quoted multi-word arg (e.g.
    `sh -c "npm run build"`, whose last token has spaces) or a trailing flag fails
    this check; a command whose final token is a bare word (e.g. `npm start`,
    `echo hi`) passes and runs. ✓
  - **When you publish a port (`--cpuser-port`), the image must be the true last
    argument with *no* trailing command.** `ea-podman` pops the last arg as the
    image and inserts the `-p` mapping before it (`util.pm`); a trailing command
    makes it mistake the command's last token for the image and mis-place `-p`, so
    the container fails (observed: `sleep: invalid number '-p'`). ✓
  - **Safest for any non-trivial or chained command:** keep the image last and pass
    the command via podman's `--entrypoint` in **JSON form**, e.g.
    `--entrypoint='["sh","-c","npm install && npm run build"]'`. ✓

### Disallowed passthrough arguments

`ea-podman` manages these itself and rejects them in the start args
(`util.pm` `validate_start_args`): `-p`/`--publish`, `-d`/`--detach`,
`-h`/`--hostname`, `--name`, `--rm`/`--rmi`/`--replace`, and `-i`/`-t`. Publishing
and hostnames/names are handled by `ea-podman`; detach, removal, and interactive
TTY flags are inappropriate for systemd-supervised containers (the source notes
these are for long-running services, not one-offs).

## How `ea-podman install` works

`ea-podman install <name> [flags] <image>` does the following:

1. Computes the container name `<name>.<user>.NN` (zero-padded, starting at `01`;
   `util.pm` `get_next_available_container_name`) and creates the per-container
   directory `~/ea-podman.d/<name>.<user>.NN/`. ✓
2. Allocates any requested host ports via the cPanel **port authority** (see
   [Ports](#ports)).
3. Persists `~/ea-podman.d/<container>/ea-podman.json` (the `start_args` and
   `ports`). ✓
4. Registers the container in `/opt/cpanel/ea-podman/registered-containers.json`. ✓
5. Generates a **user systemd unit** (`podman generate systemd
   --restart-policy on-failure`; `util.pm` `generate_container_service`) and
   `systemctl --user enable --now`s it. ✓

It does **not** enable linger on this (direct-SSH) path — see Prerequisites; enable
it yourself if the container must survive logout. A few more consequences:

- **The per-container directory is the container's managed home.** App
  files/bind-mount sources are meant to live inside `~/ea-podman.d/<container>/`
  so they are captured by `ea-podman backup` and carried across upgrades. Because
  that directory does not exist until `install` runs, staging source into it and
  running the workload are necessarily part of the same step.
- **`--restart-policy on-failure` means a clean exit is final.** A container whose
  process exits `0` (e.g. a one-shot build) is **not** restarted; its user service
  simply goes inactive. ✓
- **`podman generate systemd` is deprecated.** `ea-podman` still uses it, so a
  *"DEPRECATED command"* warning appears at install time; it is internal and
  harmless. ✓

## Ports

- `--cpuser-port=<container-port|0>` names the port **inside** the container — it
  is **not** the public port. The cPanel **port authority allocates a different
  host port**, recording the assignment (owner + service). That assignment **stays
  fixed for the life of the container** and is **released only when the container is
  uninstalled**. ✓ (Observed: `--cpuser-port=3000` published as
  `0.0.0.0:10000->3000/tcp` — host port `10000` ↦ container port `3000`.) Exposing
  that host port through the host firewall is
  the authority's responsibility; on a host with no active firewall there is simply
  nothing to open (verified the *allocation/release*, not a firewall rule, on a
  firewall-less sandbox).
- **A published port requires the image to be the final argument** — pass any
  command via `--entrypoint` (see [Running an arbitrary image](#running-an-arbitrary-image)).
- **Omit `--cpuser-port` entirely** for a container that exposes nothing (e.g. a
  build-only container). ✓ Its `ea-podman.json` then records `"ports": []`. ✓
- Discover the assigned host port after install with `ea-podman list` or
  `podman ps --format '{{.Names}} {{.Ports}}'`.
- A TCP port is not the only option: a service can equally expose a **unix
  socket** (e.g. a socket file in a mounted directory) for the consumer to talk
  to instead — anywhere a published port works, a socket works just as well. (Per
  the `ea-podman` maintainers; not exercised in these PoCs.)

## Lifecycle and subcommands

| Command | Purpose |
| --- | --- |
| `install` (`in`) | Register + create + start a container. |
| `uninstall` (`un`) | Remove a container. **Requires `--verify`.** ✓ |
| `list` (`li`, `running`) | List **running** containers and their ports. ✓ |
| `containers` (`registered`) | List **all registered** containers (incl. stopped). ✓ |
| `status` (`stat`) | `systemctl --user status` for the container's unit. ✓ |
| `start` / `stop` / `restart` | Lifecycle via the user systemd unit. ✓ |
| `upgrade` (`up`) | Re-pull/re-create at the latest image. |
| `bash` | Shell/run a command in a **running** container. ✓ |
| `backup` / `restore` | Back up / restore the user's container state. |
| `subids` (`sid`, `si`) `[--ensure]` | Report (or ensure) subuid/subgid setup. ✓ |
| `avail` (`av`) | List available EA4 container-based packages. ✓ |

Notes:

- **`list` shows only running containers** (it wraps `podman ps` without `-a`), so
  a stopped/exited container is absent there — use `ea-podman containers` to see
  it. ✓
- **`uninstall` requires `--verify`** and does not hard-delete: it removes the
  systemd unit and unregisters the container, then **renames**
  `~/ea-podman.d/<container>/` to `<container>.bak`. Remove the `.bak` separately
  if you want it gone. ✓
- **`bash` invokes `/bin/bash` inside the container**, so it only works if the
  image actually ships bash — on `node:20-alpine` (BusyBox `sh` only) it errors
  with *"executable file `/bin/bash` not found"*. ✓
- **`backup` writes a tarball** to `~/ea-podman-backups/backup-<timestamp>.tar.gz`. ✓

## File ownership (rootless mapping)

Under rootless podman, **container-root maps to the cPanel user's real UID** on
the host. ✓ Run container workloads **as container root** (do not pass `--user`;
stock images like `node` default to root) so files the container writes —
build output, logs, uploads — are owned by the cPanel user and are directly
usable by Apache and the account. A **non-root in-container UID** writes files
owned by a mapped **`subuid`**, which the bare cPanel user cannot read or serve.

## Backups

Containers are **excluded from normal cPanel account backups**; use
`ea-podman backup` / `ea-podman restore` for container state. Files the container
writes into the account's home tree (for example a subdomain document root) are
ordinary files and **are** captured by normal account backups.

## Security posture

- **Rootless is the win.** The container runs in the unprivileged user's
  namespace — no root daemon, and the blast radius is confined to that user.
- **`hidepid=2`** on `/proc` limits a user's visibility of other users'
  processes; `ea-podman` warns when it is not set. ✓
- **Trusted, pinned images.** Prefer vetted images pinned by digest/tag; arbitrary
  images are gated behind `--i-understand-the-risks-do-it-anyway` precisely
  because they are unvetted.
- **Least privilege.** Mount only what the workload needs and drop capabilities it
  does not.

## Source references

Confirmed in `…/lib/ea_podman/util.pm`: `validate_start_args` (arbitrary-image and
blocklist checks), `get_next_available_container_name` (the `<name>.<user>.NN`
scheme), `generate_container_service` (systemd unit + `on-failure`), and
`ensure_su_login` (the `su`/SSH session caveat).
