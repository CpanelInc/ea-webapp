# PoC: Static web app via ea-podman (built and served in a container)

This proof of concept builds a **static web app** for a cPanel user **inside** an
`ea-podman` container, then **serves it from a persistent static file server in
that same container**, with Apache reverse-proxying the subdomain to the
container's published host port over HTTPS.

It is the static sibling to the
[non-static PoC](./non-static-podman.md) (CPANEL-53968) and uses the **same
subdomain → container wiring** (a published host port + an Apache reverse proxy).
The only real difference is the container's job: here it serves pre-built static
files (the build output) rather than running an application server.

> **Why serve from the container instead of writing files to the docroot and
> letting Apache serve them natively?** Keeping the app in the container is the
> intended model because:
> - it can become **non-static** later without changing the hosting shape;
> - real projects usually keep the built site in a **subdirectory** of the repo
>   (e.g. `dist/`), and that subdir — not the repo root — is what we serve;
> - **dependencies stay isolated in the container**, so system/user-level runtime
>   versions and conflicts never come into play.

> **"Static" here means a static *backend*** — no server-side code runs per
> request (no PHP, Perl, Node application logic, etc.); the backend only hands out
> pre-built files. It does **not** mean the page is inert: it can be fully dynamic
> in the **browser** (this PoC compiles a small **TypeScript** app for that). A
> static file-server *process* still runs to serve the files — "static" is about
> how requests are answered, not the absence of a process.

> The universal `ea-podman` material (prerequisites, install mechanics, the
> direct-SSH requirement, ports, lifecycle, security) lives in the shared
> [ea-podman overview](./ea-podman.md). This doc covers only what is specific to
> the static case and assumes that background.

## Scope and decisions

- **Serving model:** a **persistent static file server runs in the container** on
  a published host port; Apache reverse-proxies the subdomain to it via a
  **root-owned userdata include** + `rebuildhttpdconf` (Option A) — identical to
  the non-static PoC. The subdomain's document root is **not** used for serving.
- **Build to a subdirectory.** The build emits into `dist/`; the static server
  serves that subdir.
- **Single subdomain.** `--pod` / custom-network topologies (ZC-9688) are **out
  of scope**.
- **Authoritative source:** validated against the `ea-podman` source
  (`SOURCES/ea-podman.pl`, `SOURCES/util.pm`) in `github.com/webpros-cpanel/ea-podman`,
  and **executed end to end on a live cPanel server** — build, persistent serve on
  the published port, Apache reverse proxy, and HTTPS through the proxy were all
  exercised.

## Prerequisites

See the [ea-podman overview](./ea-podman.md) for the full common list (EA4
`ea-podman`, user namespaces, subuid/subgid, a real bash login shell, `systemd`,
the Apache reverse-proxy modules, linger, and a pullable image). Specific to this
PoC:

- **Outbound npm-registry access** — the build runs `npm install` to fetch the
  TypeScript compiler.
- **Enabling linger is a manual step _here_ because this PoC uses direct SSH.**
  This is a long-running container, so it needs linger to survive logout: enable it
  (Step 0) **or** keep an SSH session open for as long as the site must stay up, or
  the container — and the site — stops once your **last SSH session closes** and
  the proxy returns **503**. `ea-podman` enables linger itself when driven without a
  login session (as the product does); direct SSH is the exception — see the
  overview.

## Procedure

### Step 0 — Connect via direct SSH as the cPanel user

```bash
ssh cptest1@SERVER_IP
```

Connect with **direct SSH** so you land in a **real bash** session — not `su -`
or `jailshell` (see the overview). Then ensure linger is on so the container keeps
running after you disconnect (run as root):

```bash
loginctl enable-linger cptest1
```

> **Why this step is manual here:** on direct SSH, `ea-podman` does not enable
> linger for you — it only does so when invoked **without** a login session (the
> `su -` / hook / adminbin paths the product uses; see the overview). Without
> linger, the container stops once your **last SSH session ends** (the user's
> `systemd` manager shuts down with the session) and the site returns **503**; if
> you skip it, you must keep an SSH session open the whole time the site needs to
> be reachable.

### Step 1 — Create the subdomain

```bash
uapi SubDomain addsubdomain domain=app rootdomain=example.com dir=public_html/app
```

This creates `app.example.com`. Its document root is created but **not used** —
Step 5 proxies every request to the container, bypassing the docroot.

### Step 2 — Create the static app (build + static server)

Create the project under `~/static-srv/`. The build compiles TypeScript and
copies the HTML/CSS into a `dist/` subdirectory; `serve.js` is a tiny,
dependency-free static server that serves `dist/` on `0.0.0.0:$PORT`.

`~/static-srv/package.json`:

```json
{
  "name": "static-srv",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "build": "tsc && cp index.html style.css dist/"
  },
  "devDependencies": {
    "typescript": "^5.4.0"
  }
}
```

`~/static-srv/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ES2020",
    "rootDir": "src",
    "outDir": "dist",
    "strict": true,
    "lib": ["ES2020", "DOM"]
  },
  "include": ["src/**/*"]
}
```

`~/static-srv/src/main.ts` (browser-side dynamic behavior, compiled to
`dist/main.js`):

```typescript
const time = document.getElementById("time");
if (time) {
  const tick = (): void => { time.textContent = new Date().toLocaleTimeString(); };
  tick();
  window.setInterval(tick, 1000);
}
```

`~/static-srv/index.html`:

```html
<!doctype html>
<html lang="en">
  <head><meta charset="utf-8" /><title>Static (served-from-container) PoC</title>
  <link rel="stylesheet" href="style.css" /></head>
  <body>
    <h1>Static site served from inside the ea-podman container</h1>
    <p>Built to <code>dist/</code>, served by a static server in the container,
       reverse-proxied by Apache. Browser clock: <strong id="time">--</strong></p>
    <script type="module" src="./main.js"></script>
  </body>
</html>
```

`~/static-srv/style.css`:

```css
body { font-family: system-ui, sans-serif; margin: 3rem auto; max-width: 40rem; }
```

`~/static-srv/serve.js` (no dependencies; **binds `0.0.0.0`**, serves `dist/`):

```javascript
const http = require("http");
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "dist");
const port = process.env.PORT || 3000;
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" };

http
  .createServer((req, res) => {
    const urlPath = decodeURIComponent((req.url || "/").split("?")[0]);
    const file = path.join(root, urlPath === "/" ? "index.html" : urlPath);
    if (!file.startsWith(root)) { res.writeHead(403).end(); return; }
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404, { "Content-Type": "text/plain" }).end("Not found\n"); return; }
      res.writeHead(200, { "Content-Type": types[path.extname(file)] || "application/octet-stream" });
      res.end(data);
    });
  })
  .listen(port, "0.0.0.0", () => console.log(`serving ${root} on 0.0.0.0:${port}`));
```

> The server **must** bind `0.0.0.0`, not the container's `127.0.0.1`, or the
> published host port cannot reach it (see the
> [overview](./ea-podman.md#ports)). A real deployment would use a hardened
> static server (nginx, Caddy, `serve`) instead of this minimal `serve.js`.

### Step 3 — Build and serve via ea-podman

```bash
export PATH="/opt/cpanel/ea-podman/bin:/usr/local/cpanel/scripts:$PATH"

ea-podman install pocstatic \
  --cpuser-port=3000 \
  -e PORT=3000 \
  -v "$HOME/static-srv:/src" \
  -w /src \
  --entrypoint='["sh","-c","npm install --no-audit --no-fund && npm run build && node serve.js"]' \
  --i-understand-the-risks-do-it-anyway \
  docker.io/library/node:20-alpine
```

- `--cpuser-port=3000` is the **container** port; the cPanel port authority
  assigns and firewalls a **different host port** (see the overview).
- `-e PORT=3000` matches the port `serve.js` listens on.
- `-v "$HOME/static-srv:/src"` mounts the project **read-write** (so `npm install`
  can write `node_modules` and the build can write `dist/`). Do **not** use `:ro`.
- The image must be **last**; the build+serve command is passed via
  `--entrypoint` in JSON form (see
  [the overview](./ea-podman.md#running-an-arbitrary-image) for why).
- `--i-understand-the-risks-do-it-anyway` is required for an arbitrary image.

The entrypoint installs deps, builds to `dist/`, then **stays running** as the
static server.

### Step 4 — Discover the host port and verify the container

```bash
ea-podman list                                   # running container + its port mapping
podman ps --format '{{.Names}} {{.Ports}}'       # e.g. 0.0.0.0:10001->3000/tcp
```

Confirm the static server answers on the assigned host port (here `10001`):

```bash
curl -s http://127.0.0.1:10001/                  # the built index.html
curl -sI http://127.0.0.1:10001/main.js          # Content-Type: text/javascript
```

### Step 5 — Wire the subdomain to the container (Option A, as root)

Identical to the non-static PoC. Create a **root-owned Apache userdata
reverse-proxy include** for **both** the SSL (`2_4`) and standard vhost paths,
pointing at the host port from Step 4.

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

Apply the includes and rebuild Apache (as root):

```bash
/usr/local/cpanel/scripts/ensure_vhost_includes --user=cptest1
/usr/local/cpanel/scripts/rebuildhttpdconf
/scripts/restartsrv_httpd
```

### Step 6 — Verify HTTPS end to end

```bash
# autossl_check is a root command, not runnable as the cPanel user
/usr/local/cpanel/bin/autossl_check --user=cptest1
curl -sk https://app.example.com/
```

Expected response: the built `index.html` ("Static site served from inside the
ea-podman container"), with `main.js` served as `text/javascript`. A **503** here
means Apache reached the proxy but the container was not serving — usually because
it is mid-rebuild or stopped (see Gotchas); confirm Step 4 first.

### Step 7 — Lifecycle and teardown

```bash
ea-podman restart pocstatic.cptest1.01
ea-podman stop    pocstatic.cptest1.01
ea-podman uninstall pocstatic.cptest1.01 --verify   # requires --verify; leaves a .bak dir
```

To detach the subdomain, remove the includes and rebuild (as root):

```bash
rm /etc/apache2/conf.d/userdata/ssl/2_4/cptest1/app.example.com/podman-poc.conf
rm /etc/apache2/conf.d/userdata/std/2_4/cptest1/app.example.com/podman-poc.conf
/usr/local/cpanel/scripts/rebuildhttpdconf
/scripts/restartsrv_httpd
```

## Gotchas

- **Build-and-serve in one entrypoint rebuilds on every (re)start.** The user
  systemd unit re-runs the whole `npm install && build && serve` chain each time
  it starts — **including on each login** (a login restarts the user's enabled
  units), causing a brief (~seconds) rebuild outage during which the proxy returns
  **503**. The `npm install`+`tsc` step is also memory-hungry and was observed to
  OOM-kill the container (`Exited (137)`) under restart churn. A real deployment
  would separate the one-time build from a stable, low-overhead static server
  rather than rebuilding on every start.
- **Common long-running-service requirements live in the
  [overview](./ea-podman.md):** the container needs **linger** (or an SSH session
  kept open) to survive logout, the in-container server must bind `0.0.0.0` (not
  `127.0.0.1`) or the published host port can't reach it, and the proxy include
  must set `X-Forwarded-Proto`.
- **The proxy only works while the container is serving.** Apache reaches the
  rootless-published port on the host loopback (verified), but only when the
  container is up and past its rebuild; otherwise expect `503`.
- **The include hard-codes the host port.** The authority keeps a container's port
  fixed for its life and releases it on uninstall, but recreating the container can
  change it, breaking the include until updated.

## Security considerations

The general `ea-podman` posture (rootless isolation, trusted/pinned images, the
risk-flag gate, least privilege) is in the [ea-podman overview](./ea-podman.md).
Specific to this PoC: the only exposed surface is the single published host port,
which the cPanel port authority allocates and firewalls, reached only via the
Apache reverse proxy.
