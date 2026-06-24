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

For what `ea-podman` does in general (install mechanics, ports, lifecycle), see
the shared [ea-podman overview](./ea-podman.md). What matters for this PoC is
where its responsibility **ends**:

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

See the [ea-podman overview](./ea-podman.md#prerequisites) for the universal
prerequisites (EA4 `ea-podman`, subuid/subgid, a real bash login shell,
`systemd`, lingering, and a pullable image). Specific to this PoC:

- Apache modules enabled: **`mod_proxy`, `mod_proxy_http`, `mod_rewrite`,
  `mod_headers`** (for the reverse proxy).
- A **container image whose entry point starts the server** — either a pullable
  image with a suitable `CMD`, or one you build locally (Step 3). This PoC
  builds a small image on top of `docker.io/library/node:20-alpine`.
- **Unprivileged user namespaces enabled** (`user.max_user_namespaces > 0`).
  Rootless podman maps the subuid/subgid ranges through a user namespace, so
  this must be non-zero or every `ea-podman` command fails up front with
  `❌ User Namespaces not available`. Stock EL9 ships with a large default, but
  hardened images sometimes zero it out. Enable and persist it as root:

  ```bash
  sysctl user.max_user_namespaces            # 0 or empty = disabled
  sysctl -w user.max_user_namespaces=15000   # enable now
  echo 'user.max_user_namespaces = 15000' > /etc/sysctl.d/99-rootless-podman.conf
  sysctl --system                            # persist across reboots
  ```

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

### Step 2 — Create the non-static Node.js app and a Containerfile

A long-running HTTP server is the key difference from the static PoC. The
server binds `0.0.0.0` on `process.env.PORT || 3000` and stays up.

> **Why bake the entry point into the image instead of passing a trailing
> command?** When you publish a port, `ea-podman` requires the image to be the
> final `install` argument with no trailing command, or it mis-places the `-p`
> mapping and the container crash-loops — see
> [Running an arbitrary image](./ea-podman.md#running-an-arbitrary-image) in the
> overview. So bake the server into the image's `CMD` and pass no trailing
> command.

Create the app directory first (as the cPanel user), then add the three files
below:

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

Do everything here **as the cPanel user** (rootless build — this is also why the
app directory must be writable; a read-only layout cannot be built). **Order
matters:** the rootless build needs the user's `subuid`/`subgid` ranges to exist
*before* the first `podman` command, or it fails unpacking the base image
(`lchown … invalid argument`). `ea-podman` provisions those ranges but does
**not** do so as a side effect of `podman` — so provision them first:

```bash
export PATH="/opt/cpanel/ea-podman/bin:/usr/local/cpanel/scripts:$PATH"

# 1. Provision (and display) the user's subuid/subgid ranges before any podman
#    command. This is what makes the rootless build work.
ea-podman subids --ensure
grep "^$(whoami):" /etc/subuid /etc/subgid    # expect e.g. <account>:589825:65536

# 2. Build the image. It must be the LAST argument to install, with NO trailing
#    command — the server starts from the image's CMD.
cd ~/nodeapp
podman build -t localhost/pocnode:1 .

# 3. Confirm the image is in THIS user's local store (so install does not try to
#    "pull" localhost/… from a registry).
podman images localhost/pocnode

# 4. Install.
ea-podman install pocnode \
  --cpuser-port=3000 \
  --i-understand-the-risks-do-it-anyway \
  localhost/pocnode:1
```

> **Recovery — `lchown … invalid argument` on build.** If you ran `podman`
> *before* the subuid ranges existed, podman initialized your storage in
> single-mapping mode and won't pick up the ranges added afterward. Run
> `podman system migrate` to re-read `/etc/subuid` / `/etc/subgid`, then rebuild.
> If stale storage persists, `podman system reset` (destructive — wipes this
> user's images/containers) then rebuild. In a clean run (ranges provisioned
> first), neither is needed — `ea-podman` itself never calls `migrate`.

> **`install` tries to "pull" `localhost/…` and fails on TLS.** That means the
> image isn't in the user's local store — `ea-podman install` runs
> `podman create`, which pulls only when the image is *missing*, and parses
> `localhost/…` as a registry. Re-check step 2/3: the build must have completed
> **as this same user**, and `podman images` must list it.

- `--cpuser-port=3000` is the **container** port; the port authority allocates a
  separate firewalled **host port** (e.g. `10001`) that Apache proxies to — see
  [Ports](./ea-podman.md#ports) in the overview.
- `--i-understand-the-risks-do-it-anyway` is required because a locally built
  image is an arbitrary (non-package) image.
- No `-p`, `-d`, `--name`, etc. — `ea-podman` manages those (see the overview's
  [disallowed passthrough arguments](./ea-podman.md#disallowed-passthrough-arguments)).

If the app needs **writable persistent storage** at runtime (uploads, a build
cache, logs), bind-mount a subdirectory of the per-container managed directory
`ea-podman` creates during install — `~/ea-podman.d/<container_name>/` (e.g.
`~/ea-podman.d/pocnode.<account>.01/`) — using `:rw`. That directory is the
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
pocnode.<account>.01  0.0.0.0:10001->3000/tcp
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
