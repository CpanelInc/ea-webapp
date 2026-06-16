# PoC: Non-static (long-running Node.js) web app via ea-podman

This proof of concept demonstrates running a **non-static, long-running
Node.js server** for a cPanel user inside a rootless `ea-podman` container,
then wiring a subdomain to it over HTTPS via an Apache reverse proxy.

It is the long-running sibling to the
[static PoC](./static-podman.md) (CPANEL-53967). The procedure is almost
identical; the meaningful difference is the container entry point: instead of
running a one-shot build and exiting, the entry point launches a persistent
HTTP server that listens on a published port for the life of the container.

## What ea-podman does — and what it does not

`ea-podman`'s responsibility **ends** at:

> a container is running, its container port is published to a host port,
> and that host port is firewalled via the cPanel port authority.

`ea-podman` does **not**:

- create subdomains,
- write or modify Apache vhosts,
- set up a reverse proxy, or
- provision SSL.

The subdomain → container wiring is the **heart of this PoC** and is a
**separate, manual step** (Step 5). `ea-podman` hands you a host port, not a
subdomain.

## Prerequisites

- **EA4 `ea-podman` package installed** on the server.
- Apache modules enabled: **`mod_proxy`, `mod_proxy_http`, `mod_rewrite`,
  `mod_headers`.**
- **`systemd`** present (user-level units are used to supervise the container).
- **`subuid` / `subgid`** ranges allocated for the cPanel user (required for
  rootless podman user-namespace mapping).
- A **real bash login shell** for the cPanel user (not `jailshell`/noshell) —
  see the SSH gotcha below.
- **Lingering** enabled for the user so user services survive logout/reboot
  (`ea-podman` enables this during install).
- A **pullable container image** (this PoC uses `docker.io/library/node:20-alpine`).

## How ea-podman install works (for reference)

When you run `ea-podman install`, it:

1. Registers a podman container for the cPanel user.
2. Allocates one or more host ports via `--cpuser-port=<containerport|0>`
   (the cPanel port authority picks the host port and firewalls it).
3. Persists `~/ea-podman.d/<container>/ea-podman.json`.
4. Registers the container in
   `/opt/cpanel/ea-podman/registered-containers.json`.
5. Generates a **user systemd unit**
   (`podman generate systemd --restart-policy on-failure`) and runs
   `systemctl --user enable --now` on it.
6. Enables **linger** for the user so the unit survives logout and reboot.

### Disallowed passthrough arguments

`ea-podman` manages these itself; passing them through to the image is
rejected: `-p`/`--publish`, `-d`/`--detach`, `-h`/`--hostname`, `--name`,
`--rm`, `--rmi`, `--replace`, `-i`, `-t`.

### Arbitrary images

Running an arbitrary (non-vetted) image requires the explicit
`--i-understand-the-risks-do-it-anyway` flag.

## Procedure

### Step 0 — Connect via direct SSH as the cPanel user

```bash
ssh cptest1@SERVER_IP
```

Connect with **direct SSH** so you land in a **real bash** session.

> **Do not** use `su -` or `jailshell` to reach the user. Rootless podman
> depends on a per-user DBus session, a correct `XDG_RUNTIME_DIR`, and
> linger; `su`/jailshell environments do not set these up and rootless podman
> breaks (see `util.pm` `ensure_su_login`).

### Step 1 — Create the subdomain

```bash
uapi SubDomain addsubdomain domain=app rootdomain=example.com dir=public_html/app
```

This creates `app.example.com`. `ea-podman` will **not** do this for you.

### Step 2 — Create the non-static Node.js app

A long-running HTTP server is the key difference from the static PoC. The
server binds `0.0.0.0` on `process.env.PORT || 3000` and stays up.

`~/nodeapp/server.js`:

```javascript
const http = require("http");

const port = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end(`Hello from non-static Node PoC! You requested: ${req.url}\n`);
});

server.listen(port, "0.0.0.0", () => {
  console.log(`Listening on 0.0.0.0:${port}`);
});
```

`~/nodeapp/package.json`:

```json
{
  "name": "nodeapp",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "start": "node server.js"
  }
}
```

> The server **must** bind `0.0.0.0` (not `127.0.0.1`). Inside the container,
> `127.0.0.1` is the container's own loopback and would not be reachable from
> the published host port.

### Step 3 — Run the app via ea-podman

```bash
export PATH="/opt/cpanel/ea-podman/bin:/usr/local/cpanel/scripts:$PATH"

ea-podman install pocnode \
  --cpuser-port=3000 \
  -e "PORT=3000" \
  -v "$HOME/ea-podman.d/<container_name>/nodeapp:/app:rw" \
  -w /app \
  --i-understand-the-risks-do-it-anyway \
  docker.io/library/node:20-alpine \
  npm start
```

- `--cpuser-port=<container-port>` is set to the port the server listens on
  **inside** the container (here, the value of `PORT`). The port authority then
  publishes it to an allocated, firewalled host port — that assigned host port,
  not this value, is what Apache proxies to.
- `-e "PORT=3000"` matches the env var the server reads.
- `-v "<container-dir>/nodeapp:/app:rw"` bind-mounts the app **read-write** so
  the container can build, write logs, accept file uploads, and otherwise modify
  files under `/app` (use `:ro` only if the app is fully self-contained and never
  needs to write). The
  source **must live inside the per-container directory `ea-podman` creates** for
  this container — `~/ea-podman.d/<container_name>/` (e.g.
  `~/ea-podman.d/pocnode.cptest1.01/`). That directory is the container's managed
  home: it is what `ea-podman` backs up and carries across upgrades, so app files
  kept anywhere else fall outside the container's lifecycle. Note the ordering —
  `ea-podman` only creates and names that directory (with the `.NN` suffix)
  during `install`, so stage the app files into it as part of standing the
  container up rather than mounting from an arbitrary `$HOME` path.
- `-w /app` sets the working directory inside the container.
- `--i-understand-the-risks-do-it-anyway` is required because
  `node:20-alpine` is an arbitrary image.
- `npm start` is the entry point — here it launches the persistent server.

### Step 4 — Discover the host port and verify the container

```bash
ea-podman list
ea-podman status pocnode.cptest1.01
podman ps --format '{{.Names}} {{.Ports}}'
```

The `podman ps` output shows the published mapping, for example:

```
pocnode.cptest1.01  0.0.0.0:10001->3000/tcp
```

Confirm the server answers on the host port (here `10001`):

```bash
curl http://127.0.0.1:10001/
```

Verify supervision is in place:

```bash
systemctl --user status 'container-pocnode*'   # user unit is enabled + active
loginctl show-user "$(whoami)" | grep Linger    # expect Linger=yes
```

### Step 5 — Wire the subdomain to the container (Option A, as root)

`ea-podman` gave you a host port; now connect `app.example.com` to it. Create a
**root-owned Apache userdata reverse-proxy include** for **both** the SSL
(`2_4`) and non-SSL vhost paths.

SSL path — `/etc/apache2/conf.d/userdata/ssl/2_4/cptest1/app.example.com/podman-poc.conf`:

```apache
ProxyPreserveHost On
ProxyPass        / http://127.0.0.1:10001/
ProxyPassReverse / http://127.0.0.1:10001/
RequestHeader set X-Forwarded-Proto "https"
```

Create the equivalent non-SSL include under the standard (non-`ssl`) userdata
path as well:
`/etc/apache2/conf.d/userdata/std/2_4/cptest1/app.example.com/podman-poc.conf`
(use the same body; you may keep `X-Forwarded-Proto "http"` there, or drop the
header on the non-SSL path).

> Replace `10001` with the actual host port from Step 4.

Apply the includes and rebuild Apache:

```bash
/usr/local/cpanel/scripts/ensure_vhost_includes --user=cptest1
/usr/local/cpanel/scripts/rebuildhttpdconf
/scripts/restartsrv_httpd
```

### Step 6 — Verify HTTPS end to end

```bash
/usr/local/cpanel/bin/autossl_check --user=cptest1
curl -sk https://app.example.com/poc-path
```

Expected response:

```
Hello from non-static Node PoC! You requested: /poc-path
```

### Step 7 — Lifecycle and teardown

Manage the container lifecycle with `ea-podman`:

```bash
ea-podman restart pocnode.cptest1.01
ea-podman stop    pocnode.cptest1.01
ea-podman uninstall pocnode.cptest1.01
```

To **detach** the subdomain, remove the Apache include(s) and rebuild:

```bash
rm /etc/apache2/conf.d/userdata/ssl/2_4/cptest1/app.example.com/podman-poc.conf
rm /etc/apache2/conf.d/userdata/std/2_4/cptest1/app.example.com/podman-poc.conf
/usr/local/cpanel/scripts/rebuildhttpdconf
/scripts/restartsrv_httpd
```

## Gotchas

- **`su -` / jailshell breaks rootless podman.** Always connect via direct SSH
  as the user into a real bash shell. `su`/jailshell does not set up the user
  DBus session, `XDG_RUNTIME_DIR`, or linger that rootless podman requires
  (`util.pm` `ensure_su_login`).
- **`ea-podman` gives you a port, not a subdomain.** Subdomain creation, vhost
  wiring, reverse proxy, and SSL are all separate steps.
- **The host port is dynamic.** The reverse-proxy include **hard-codes** the
  allocated host port. Re-creating the container, restoring from backup, or
  port-authority reallocation can change that port, breaking the proxy. The
  include must then be updated. (This port indirection is a key productization
  concern — see below.)
- **The app must bind `0.0.0.0`.** Binding the container's `127.0.0.1` makes it
  unreachable from the published host port.
- **`X-Forwarded-Proto`** must be set so the app generates correct
  `https://` redirects/links behind the proxy.
- **Rootless files are owned by subuids.** Files written inside the container
  appear on the host owned by mapped `subuid`/`subgid` values, not the bare
  cPanel UID. Plan inspection/cleanup accordingly.
- **Containers are excluded from normal cPanel backups.** Use
  `ea-podman backup` for container state; do not assume account backups capture
  it.

## Security considerations

- **Rootless is the win.** The container runs as the unprivileged cPanel user
  in a user namespace — no root daemon, blast radius confined to the user.
- **Trusted, pinned images.** Prefer vetted images and pin by digest/tag.
  Arbitrary images require `--i-understand-the-risks-do-it-anyway` precisely
  because they are unvetted.
- **Port authority firewalling.** Published host ports are allocated and
  firewalled by the cPanel port authority, so they are not exposed beyond the
  intended path.
- **`hidepid=2`** limits a user's visibility of other users' processes,
  reinforcing isolation on a shared host.
- **Least privilege on the mount and capabilities.** Mount the app
  **read-only** (`:ro`) and **drop capabilities** the workload does not need.

## What productization needs

This PoC stitches steps together by hand. A shipped feature would need:

- **Port indirection.** Stop hard-coding the host port in the Apache include.
  Resolve the container's current published port at config-build time (or proxy
  by a stable name) so restore/recreate/reallocation does not break the route.
- **Subdomain wiring as code.** Generate and manage the reverse-proxy userdata
  includes programmatically, mirroring how
  `Cpanel::Config::userdata::PassengerApps` manages per-vhost app config.
- **Runtime-as-data handlers.** Describe each supported runtime (Node, Python,
  etc.) as data with a corresponding handler, rather than bespoke per-app
  commands.
- **Process-manager abstraction.** Abstract over the systemd-user supervision
  so lifecycle (start/stop/restart/status) is uniform and not tied to raw
  `ea-podman` invocations.
- **Structured errors.** Return machine-readable errors from each step so the
  UI/orchestration can react meaningfully.
- **Cleanup hooks.** On subdomain/account removal, automatically tear down the
  container, its systemd unit, linger (if no longer needed), and the Apache
  includes.
