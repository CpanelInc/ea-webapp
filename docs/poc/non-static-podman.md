# PoC: Non-static (long-running Node.js) web app via ea-podman

This proof of concept demonstrates running a **non-static, long-running
Node.js server** for a cPanel user inside a rootless `ea-podman` container,
then wiring a subdomain to it over HTTPS via an Apache reverse proxy.

It is the long-running sibling to the
[static PoC](./static-podman.md) (CPANEL-53969). The procedure is almost
identical; the meaningful difference is the container entry point: instead of
running a one-shot build and exiting, the entry point launches a persistent
HTTP server that listens on a published port for the life of the container.

## What ea-podman does — and what it does not

The shared [ea-podman overview](./ea-podman.md) covers what `ea-podman` does
(install mechanics, ports, lifecycle). What matters for this PoC is where its
responsibility **ends**: it leaves you with a running container whose port is
published and firewalled — and nothing in front of it. `ea-podman` does **not**:

- create subdomains,
- write or modify Apache vhosts,
- set up a reverse proxy, or
- provision SSL.

The subdomain → container wiring is the **heart of this PoC** and is a
**separate, manual step** (Step 5). `ea-podman` hands you a host port, not a
subdomain.

## Prerequisites

The shared [ea-podman overview](./ea-podman.md#prerequisites) covers the full
list. The only PoC-specific point is the entry point: this PoC uses the stock
`docker.io/library/node:20-alpine` image **as-is** and supplies the long-running
server command at install time via `--entrypoint` (Step 3) — no custom image and
no local build.

## Procedure

### Step 0 — Server-side prep (as root) and connect as the cPanel user

First, give the account a real (unrestricted) bash login shell — applied as
root via the WHM API (`whmapi1`). `jailshell`/`noshell` will not work for
rootless podman, and you need this before you can SSH in below:

```bash
# Equivalent to WHM » Manage Shell Access.
whmapi1 modifyacct user=<account> shell=/bin/bash
```

> `modifyacct` requires the caller to hold the `allow-shell` ACL, and the server
> must permit shell access at all (WHM's "Shell Fork Bomb Protection" /
> account-can-have-shell setting) or the call dies with
> `This server cannot give shell access.`

Then connect as the cPanel user:

```bash
ssh <account>@SERVER_IP
```

Connect with **direct SSH** so you land in a **real bash** session.

> **Do not** use `su -` or `jailshell` to reach the user — rootless podman needs
> the per-user session a direct login establishes (see
> [Connecting](./ea-podman.md#connecting-use-direct-ssh) in the overview).

### Step 1 — Create the subdomain

`rootdomain` must be a domain the account **already owns** — substitute the
account's own domain for `<account-domain>` below (list it with
`uapi DomainInfo list_domains`). Building on a domain the account does not own
fails with `The domain “<account-domain>” does not belong to “<account>”.`

```bash
uapi SubDomain addsubdomain domain=app rootdomain=<account-domain> dir=public_html/app
```

This creates `app.<account-domain>`. `ea-podman` will **not** do this for you.

### Step 2 — Create the non-static Node.js app

The app just needs to be a **long-running server that listens on a port** — in
any language or framework. The example below is a tiny Node.js HTTP server; the
only things that matter for the PoC are that it **stays running** and **binds
`0.0.0.0`** on the port `ea-podman` will publish (here `process.env.PORT`,
defaulting to `3000`). A real app does the same in whatever stack it uses.

Create the app locally as the cPanel user — for this example a single file is
enough:

```bash
mkdir ~/nodeapp
```

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

> The server **must** bind `0.0.0.0` (not the container's `127.0.0.1`) or the
> published host port can't reach it — see [Ports](./ea-podman.md#ports).

### Step 3 — Run the app via ea-podman

No image build is needed: run the stock `node:20-alpine` image **straight from
Docker Hub**, **mount your app into it** with `-v`, and start the server with
`--entrypoint`. `ea-podman install` sets up the user's `subuid`/`subgid` ranges
itself, so there is no separate provisioning step. Run this as the cPanel user:

```bash
export PATH="/opt/cpanel/ea-podman/bin:/usr/local/cpanel/scripts:$PATH"

ea-podman install pocnode \
  --cpuser-port=3000 \
  -e PORT=3000 \
  -v "$HOME/nodeapp:/app" \
  -w /app \
  --entrypoint='["node","server.js"]' \
  --i-understand-the-risks-do-it-anyway \
  docker.io/library/node:20-alpine
```

- `--cpuser-port=3000` is the **container** port; the port authority allocates a
  separate firewalled **host port** (e.g. `10001`) that Apache proxies to — see
  [Ports](./ea-podman.md#ports) in the overview.
- `-v "$HOME/nodeapp:/app"` mounts your app into the container (read-write by
  default, so it can write logs/uploads), `-w /app` runs in it, and
  `--entrypoint='["node","server.js"]'` starts the server. The **image must be
  the last argument** with the command supplied via `--entrypoint` — see
  [Running an arbitrary image](./ea-podman.md#running-an-arbitrary-image).
- `--i-understand-the-risks-do-it-anyway` is required because the stock image is
  an arbitrary (non-package) image.
- No `-p`, `-d`, `--name`, etc. — `ea-podman` manages those (see the overview's
  [disallowed passthrough arguments](./ea-podman.md#disallowed-passthrough-arguments)).

For data that must persist and be **backed up / carried across upgrades**, mount
from a subdirectory of the per-container managed directory `ea-podman` creates at
install (`~/ea-podman.d/<container_name>/`) rather than from `$HOME` — that
directory is the container's managed home. Because the `.NN`-suffixed name only
exists *after* `install`, the practical sequence is to install once to learn the
name, then re-`install` with the managed-dir mount.

### Step 4 — Discover the host port, enable linger, and verify

```bash
ea-podman list
podman ps --format '{{.Names}} {{.Ports}}'
```

The `podman ps` output shows the published mapping, for example:

```
pocnode.<account>.01  0.0.0.0:10001->3000/tcp
```

> `ea-podman list` may report **more than one** reserved host port for the
> container (e.g. `"ports": ["10001","10002"]`). The one that actually serves
> your app is whichever `podman ps` shows **bound to your container port**
> (`->3000/tcp`) — don't assume it's the first in the list. Always take the host
> port from the `podman ps` mapping.

Confirm the server answers on the host port (use the one bound to `->3000/tcp`,
e.g. `10001`):

```bash
curl http://127.0.0.1:10001/
```

**Enable linger** so the container survives logout and reboot. `ea-podman`
does **not** do this on the direct-SSH path, so the user systemd scope (and the
container with it) is torn down when your session ends — the container will
appear to "randomly" stop. Enabling linger requires root:

```bash
# as root:
loginctl enable-linger <account>
loginctl show-user <account> | grep Linger    # expect Linger=yes
```

Then confirm supervision (as the user):

```bash
systemctl --user status 'container-pocnode*'   # user unit is enabled + active
```

### Step 5 — Wire the subdomain to the container (Option A, as root)

`ea-podman` gave you a host port; now connect `app.<account-domain>` (the
subdomain created in Step 1) to it. Create a **root-owned Apache userdata
reverse-proxy include** for **both** the SSL (`2_4`) and non-SSL vhost paths.
Substitute the account's own domain for `<account-domain>` below.

SSL path — `/etc/apache2/conf.d/userdata/ssl/2_4/<account>/app.<account-domain>/podman-poc.conf`:

```apache
ProxyPreserveHost On
ProxyPass        / http://127.0.0.1:10001/
ProxyPassReverse / http://127.0.0.1:10001/
RequestHeader set X-Forwarded-Proto "https"
```

Create the equivalent non-SSL include under the standard (non-`ssl`) userdata
path as well:
`/etc/apache2/conf.d/userdata/std/2_4/<account>/app.<account-domain>/podman-poc.conf`
(use the same body; you may keep `X-Forwarded-Proto "http"` there, or drop the
header on the non-SSL path).

> Replace `10001` with the actual host port from Step 4, and `<account-domain>`
> with the account's domain from Step 1.

Apply the includes and rebuild Apache:

```bash
/usr/local/cpanel/scripts/ensure_vhost_includes --user=<account>
/usr/local/cpanel/scripts/rebuildhttpdconf
/scripts/restartsrv_httpd
```

### Step 6 — Verify HTTPS end to end

```bash
/usr/local/cpanel/bin/autossl_check --user=<account>
curl -sk https://app.<account-domain>/poc-path
```

Expected response:

```
Hello from non-static Node PoC! You requested: /poc-path
```

### Step 7 — Lifecycle and teardown

Manage the container lifecycle with `ea-podman`:

```bash
ea-podman restart pocnode.<account>.01
ea-podman stop    pocnode.<account>.01
ea-podman uninstall pocnode.<account>.01
```

To **detach** the subdomain, remove the Apache include(s) and rebuild:

```bash
rm /etc/apache2/conf.d/userdata/ssl/2_4/<account>/app.<account-domain>/podman-poc.conf
rm /etc/apache2/conf.d/userdata/std/2_4/<account>/app.<account-domain>/podman-poc.conf
/usr/local/cpanel/scripts/rebuildhttpdconf
/scripts/restartsrv_httpd
```

## Gotchas

- **Linger is not enabled for you.** Because direct SSH already sets
  `XDG_RUNTIME_DIR`, `ea-podman` skips its `loginctl enable-linger` call, so the
  container stops when your session ends. Enable linger explicitly (Step 4).
- **Don't pass a run command after the image.** `ea-podman` expects the image
  to be the last argument; a trailing command corrupts the publish mapping and
  the container command. Pass the start command via `--entrypoint` instead
  (Step 3).
- **`ea-podman` gives you a port, not a subdomain.** Subdomain creation, vhost
  wiring, reverse proxy, and SSL are all separate steps.
- **The host port is stable for the life of the container.** Once the port
  authority assigns a host port to a container it stays assigned until you
  `uninstall` that container — `restart`, `stop`/`start`, restore, and upgrade
  all reuse it (`util.pm` `_get_current_ports`). The reverse-proxy include
  hard-codes that port, which only needs updating if you fully uninstall and
  reinstall (which yields a new assignment). Resolving the port programmatically
  is still a productization concern — see below.

## Security considerations

The general `ea-podman` security posture (rootless isolation, trusted/pinned
images, the `--i-understand-the-risks-do-it-anyway` gate, `hidepid=2`,
least-privilege capabilities, and port-authority firewalling of the published
port) is in the [ea-podman overview](./ea-podman.md#security-posture). Specific
to this PoC: do **not** mount the app read-only — a rootless build and most
long-running workloads need to write, so `:ro` is a non-starter here.

## What productization needs

The only genuinely manual, productization-worthy gap this PoC exposes is the
**subdomain → container wiring** (Step 5): generating and managing the
reverse-proxy userdata includes programmatically — including resolving the
container's published host port at config-build time — and tearing them down on
subdomain/account removal, mirroring how
`Cpanel::Config::userdata::PassengerApps` manages per-vhost app config. The rest
of the lifecycle (port allocation/firewalling, systemd-user supervision, linger,
backups) is already handled by `ea-podman` and the port authority.
