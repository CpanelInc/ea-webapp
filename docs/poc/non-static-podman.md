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

> **Port or socket.** This PoC publishes to a host **port**, but the same wiring
> works if the app listens on a **unix socket** instead — it's a universal
> choice (if a port works, a socket works, and vice versa), so no separate
> socket PoC is needed.

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
- **`subuid` / `subgid`** ranges for the cPanel user (required for rootless
  podman user-namespace mapping). You do **not** allocate these by hand —
  `ea-podman`'s `ensure_user` step writes them to `/etc/subuid` and
  `/etc/subgid` on the user's first `ea-podman` command (verified:
  `cptest1:589825:65536` appeared after the first `install`).
- A **real bash login shell** for the cPanel user (not `jailshell`/noshell) —
  see the SSH gotcha below.
- **Lingering** enabled for the user so user services survive logout/reboot.
  Do not assume `ea-podman` does this for you — see Step 4. (`ea-podman` only
  calls `loginctl enable-linger` when `XDG_RUNTIME_DIR` is unset, which is
  **not** the case on the direct-SSH path this doc recommends, so it is
  effectively skipped — `util.pm` `ensure_su_login`.)
- A **container image whose entry point starts the server** — either a pullable
  image with a suitable `CMD`, or one you build locally (Step 3). This PoC
  builds a small image on top of `docker.io/library/node:20-alpine`.

## How ea-podman install works (for reference)

When you run `ea-podman install`, it:

1. Registers a podman container for the cPanel user.
2. **Calls the cPanel port authority on your behalf** to allocate and firewall
   a host port for each `--cpuser-port=<container-port|0>` you pass — you do
   **not** run `cpuser_port_authority` yourself. The value you give
   `--cpuser-port` is the **port inside the container**; the port authority
   picks the public host port and `ea-podman` publishes the container port to
   it as `-p <host-port>:<container-port>` (`util.pm` `_get_new_ports` /
   `install`).
3. Persists `~/ea-podman.d/<container>/ea-podman.json` (including the
   `--cpuser-port` values under `ports`).
4. Registers the container in
   `/opt/cpanel/ea-podman/registered-containers.json`.
5. Generates a **user systemd unit**
   (`podman generate systemd --restart-policy on-failure`) and runs
   `systemctl --user enable --now` on it.
6. **Does not reliably enable linger.** `ea-podman` only runs
   `loginctl enable-linger` when `XDG_RUNTIME_DIR` is unset; on the direct-SSH
   path this doc recommends it is already set, so linger is **not** enabled and
   you must do it yourself (Step 4).

### Disallowed passthrough arguments

`ea-podman` manages these itself; passing them through to the image is
rejected: `-p`/`--publish`, `-d`/`--detach`, `-h`/`--hostname`, `--name`,
`--rm`, `--rmi`, `--replace`, `-i`, `-t`.

### Arbitrary images

An **arbitrary image** is any image that is not packaged as an "ea-podman based
package" (it has nothing to do with whether the image tag is pinned). Running
one — including an image you build locally — requires the explicit
`--i-understand-the-risks-do-it-anyway` flag.

## Procedure

### Step 0 — Connect via direct SSH as the cPanel user

```bash
ssh cptest1@SERVER_IP
```

Connect with **direct SSH** so you land in a **real bash** session.

> **Do not** use `su -` or `jailshell` to reach the user. Rootless podman needs
> the per-user session that a direct login establishes; reaching the user any
> other way leaves that environment incomplete and podman misbehaves. This is a
> solvable problem that was never prioritized and will be handled for the
> shipped feature — for the PoC, just connect directly.

### Step 1 — Create the subdomain

```bash
uapi SubDomain addsubdomain domain=app rootdomain=example.com dir=public_html/app
```

This creates `app.example.com`. `ea-podman` will **not** do this for you.

### Step 2 — Create the non-static Node.js app and a Containerfile

A long-running HTTP server is the key difference from the static PoC. The
server binds `0.0.0.0` on `process.env.PORT || 3000` and stays up.

> **Why an image instead of a trailing command?** `ea-podman` treats the
> **last argument to `install` as the image** and inserts the `-p` publish
> mapping immediately before it. If you append a run command after the image
> (e.g. `… node:20-alpine npm start`), `ea-podman` mistakes `start` for the
> image, wedges `-p <host>:<container>` into the *container command*, and
> publishes **no** port — the container then crash-loops on
> `Unknown command: "<host>:<container>"`. (Verified on a live server; see
> `util.pm` `install`, which does `pop @real_start_args` to grab the image.)
> The reliable pattern is therefore to **bake the entry point into the image's
> `CMD`** and pass no trailing command.

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

`~/nodeapp/Containerfile` — bakes the entry point into the image's `CMD`:

```dockerfile
FROM docker.io/library/node:20-alpine
WORKDIR /app
COPY server.js package.json /app/
ENV PORT=3000
CMD ["npm", "start"]
```

### Step 3 — Build the image and run it via ea-podman

Build the image **as the cPanel user** (rootless build — this is also why the
app directory must be writable; a read-only layout cannot be built), then
install it. The image is the **last argument** and there is **no trailing
command** — the server starts from the image's `CMD`:

```bash
export PATH="/opt/cpanel/ea-podman/bin:/usr/local/cpanel/scripts:$PATH"

cd ~/nodeapp
podman build -t localhost/pocnode:1 .

ea-podman install pocnode \
  --cpuser-port=3000 \
  --i-understand-the-risks-do-it-anyway \
  localhost/pocnode:1
```

- `--cpuser-port=3000` is the port the server listens on **inside** the
  container. `ea-podman` calls the port authority for you and publishes the
  container port to an allocated, firewalled **host port** (e.g. `10001`) as
  `-p 10001:3000`. That assigned host port — not this value — is what Apache
  proxies to. You never call `cpuser_port_authority` yourself.
- `--i-understand-the-risks-do-it-anyway` is required because a locally built
  image is an arbitrary (non-package) image.
- No `-p`, `-d`, `--name`, etc. — `ea-podman` manages those (see *Disallowed
  passthrough arguments*).

If the app needs **writable persistent storage** at runtime (uploads, a build
cache, logs), bind-mount a subdirectory of the per-container managed directory
`ea-podman` creates during install — `~/ea-podman.d/<container_name>/` (e.g.
`~/ea-podman.d/pocnode.cptest1.01/`) — using `:rw`. That directory is the
container's managed home (what `ea-podman` backs up and carries across
upgrades). Because the `.NN`-suffixed directory name only exists *after*
`install`, the practical sequence is: install once to learn the container name,
then `uninstall` and re-`install` with the `-v <managed-dir>/data:/data:rw`
mount now that you know the path.

### Step 4 — Discover the host port, enable linger, and verify

```bash
ea-podman list
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

**Enable linger** so the container survives logout and reboot. `ea-podman`
does **not** do this on the direct-SSH path, so the user systemd scope (and the
container with it) is torn down when your session ends — the container will
appear to "randomly" stop. Enabling linger requires root:

```bash
# as root:
loginctl enable-linger cptest1
loginctl show-user cptest1 | grep Linger    # expect Linger=yes
```

Then confirm supervision (as the user):

```bash
systemctl --user status 'container-pocnode*'   # user unit is enabled + active
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

- **`su -` / jailshell does not give you a working rootless environment.**
  Always connect via direct SSH as the user into a real bash shell so the
  per-user session (DBus, `XDG_RUNTIME_DIR`) is set up. This is a solvable
  problem that simply was never prioritized and will be handled for the shipped
  feature; for the PoC, direct SSH is the supported path.
- **Linger is not enabled for you.** Because direct SSH already sets
  `XDG_RUNTIME_DIR`, `ea-podman` skips its `loginctl enable-linger` call, so the
  container stops when your session ends. Enable linger explicitly (Step 4).
- **Don't pass a run command after the image.** `ea-podman` expects the image
  to be the last argument; a trailing command corrupts the publish mapping and
  the container command. Bake the entry point into the image `CMD` (Step 2).
- **`ea-podman` gives you a port, not a subdomain.** Subdomain creation, vhost
  wiring, reverse proxy, and SSL are all separate steps.
- **The host port is stable for the life of the container.** Once the port
  authority assigns a host port to a container it stays assigned until you
  `uninstall` that container — `restart`, `stop`/`start`, restore, and upgrade
  all reuse it (`util.pm` `_get_current_ports`). The reverse-proxy include
  hard-codes that port, which only needs updating if you fully uninstall and
  reinstall (which yields a new assignment). Resolving the port programmatically
  is still a productization concern — see below.
- **The app must bind `0.0.0.0`.** Binding the container's `127.0.0.1` makes it
  unreachable from the published host port.
- **`X-Forwarded-Proto`** must be set so the app generates correct
  `https://` redirects/links behind the proxy.
- **Rootless files are owned by subuids.** Files written inside the container
  appear on the host owned by mapped `subuid`/`subgid` values, not the bare
  cPanel UID. Plan inspection/cleanup accordingly.

## Security considerations

- **Rootless is the win.** The container runs as the unprivileged cPanel user
  in a user namespace — no root daemon, blast radius confined to the user.
- **Trusted images.** Prefer ea-podman package images or images you build
  yourself from a trusted base, and pin the base by digest/tag. Any non-package
  image is "arbitrary" and requires `--i-understand-the-risks-do-it-anyway`.
- **Port authority firewalling.** Published host ports are allocated and
  firewalled by the cPanel port authority, so they are not exposed beyond the
  intended path.
- **`hidepid=2`** limits a user's visibility of other users' processes,
  reinforcing isolation on a shared host.
- **Least privilege on capabilities.** **Drop capabilities** the workload does
  not need. (Do not mount the app read-only — a rootless build and most real
  workloads need to write, so `:ro` is a non-starter here.)

## What productization needs

The only genuinely manual, productization-worthy gap this PoC exposes is the
**subdomain → container wiring** (Step 5): generating and managing the
reverse-proxy userdata includes programmatically — including resolving the
container's published host port at config-build time — and tearing them down on
subdomain/account removal, mirroring how
`Cpanel::Config::userdata::PassengerApps` manages per-vhost app config. The rest
of the lifecycle (port allocation/firewalling, systemd-user supervision, linger,
backups) is already handled by `ea-podman` and the port authority.
