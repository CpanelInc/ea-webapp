# PoC: Static (build-only) web app via ea-podman

This proof of concept demonstrates building a **static web app** for a cPanel
user with a **one-shot, build-only** `ea-podman` container, then serving the
built files on a subdomain over HTTPS **directly from disk via Apache**.

It is the static sibling to the
[non-static PoC](./non-static-podman.md) (CPANEL-53968). The procedure shares
the same `ea-podman` foundation, but the model is fundamentally simpler: instead
of launching a persistent HTTP server and reverse-proxying a published host port
to it, the container's entry point runs a build, writes static assets into the
subdomain's document root, and **exits**. There is **no long-running process, no
published port, and no reverse proxy** — Apache serves the files natively.

> **"Static" describes the *hosting* model — files on disk, no server process —
> not the page itself.** The build can run a full toolchain (this PoC compiles a
> **TypeScript** app), and the served site can be fully **dynamic in the
> browser** (client-side JavaScript). What makes it "static" is that nothing runs
> server-side to answer each request.

> The universal `ea-podman` material (full prerequisites, what `ea-podman` does
> and does not do, install mechanics, and the direct-SSH requirement) lives in
> the shared [ea-podman overview](./ea-podman.md). This doc covers only what is
> specific to the static, build-only case and assumes that background.

## Scope and decisions

- **Serving model:** **Apache serves the built files directly from disk.** The
  build container writes its output into the subdomain's document root; no vhost
  edits, reverse proxy, or `rebuildhttpdconf` are needed. This is the defining
  contrast with the non-static PoC.
- **No published port.** A build-only container exposes nothing, so
  `--cpuser-port` is **not used**. (In the non-static PoC, `--cpuser-port=<N>`
  names the *container* port; the firewalled *host* port is assigned by the
  cPanel port authority. Neither applies here.)
- **Single subdomain.** `--pod` / custom-network topologies (ZC-9688) are **out
  of scope**.
- **Authoritative source:** validated against the `ea-podman` source
  (`SOURCES/ea-podman.pl`, `SOURCES/util.pm`) in
  `github.com/CpanelInc/ea-podman`, and **executed end to end on a live cPanel
  server** (the commands below produced the running site described).

## Prerequisites

See the [ea-podman overview](./ea-podman.md) for the full list. The essentials
for this PoC:

- **EA4 `ea-podman` package installed** on the server.
- **`subuid` / `subgid`** ranges for the cPanel user (rootless podman
  user-namespace mapping). `ea-podman install` allocates these automatically on
  first use for the user, so no manual step is normally needed; you can confirm
  with `ea-podman subids`.
- A **real bash login shell** for the cPanel user (not `jailshell`/noshell) — see
  the SSH gotcha in the overview.
- A **pullable container image** (this PoC uses `docker.io/library/node:20-alpine`).
- **Outbound network access to the npm registry** — the build runs `npm install`
  to fetch the TypeScript compiler (and any other dependencies).

> Apache module prerequisites are lighter than the non-static case: serving
> static files needs no `mod_proxy`/`mod_proxy_http`.

## Procedure

### Step 0 — Connect via direct SSH as the cPanel user

```bash
ssh cptest1@SERVER_IP
```

Connect with **direct SSH** so you land in a **real bash** session. Do **not**
use `su -` or `jailshell` — rootless podman breaks without the per-user DBus
session, `XDG_RUNTIME_DIR`, and linger that a real login sets up (see the
overview for detail).

### Step 1 — Create the subdomain

```bash
uapi SubDomain addsubdomain domain=app rootdomain=example.com dir=public_html/app
```

This creates `app.example.com` with its document root at `~/public_html/app`.
The built static files will land **here**, so Apache serves them with no further
wiring.

### Step 2 — Create the TypeScript app and its build

Create the project under `~/ts-site/`. The build type-checks and compiles the
TypeScript to plain JavaScript with `tsc`, then copies the HTML and CSS into the
output directory. The compiled `main.js` drives the page's client-side dynamic
behavior (a live clock, a click counter, and a theme toggle).

`~/ts-site/package.json`:

```json
{
  "name": "ts-site",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "build": "tsc && cp index.html style.css /out/"
  },
  "devDependencies": {
    "typescript": "^5.4.0"
  }
}
```

`~/ts-site/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ES2020",
    "moduleResolution": "bundler",
    "rootDir": "src",
    "outDir": "/out",
    "strict": true,
    "noUnusedLocals": true,
    "lib": ["ES2020", "DOM"]
  },
  "include": ["src/**/*"]
}
```

> `outDir` is set to `/out` — the in-container path where the subdomain document
> root is bind-mounted (Step 3) — so `tsc` emits `main.js` straight into the
> served directory. The `build` script then copies the HTML/CSS alongside it.

`~/ts-site/src/main.ts`:

```typescript
// Strongly-typed, browser-side dynamic behavior, compiled from TypeScript at
// build time. The emitted main.js is served as a static file by Apache.

type Theme = "light" | "dark";

function byId<T extends HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`missing element #${id}`);
  return el as T;
}

function startClock(target: HTMLElement): void {
  const tick = (): void => {
    target.textContent = new Date().toLocaleTimeString();
  };
  tick();
  window.setInterval(tick, 1000);
}

function wireCounter(label: HTMLElement, button: HTMLButtonElement): void {
  let clicks = 0;
  button.addEventListener("click", () => {
    clicks += 1;
    label.textContent = String(clicks);
  });
}

function wireTheme(button: HTMLButtonElement): void {
  let theme: Theme = "light";
  button.addEventListener("click", () => {
    theme = theme === "light" ? "dark" : "light";
    document.body.dataset.theme = theme;
    button.textContent = `Theme: ${theme}`;
  });
}

function renderList(list: HTMLUListElement, items: readonly string[]): void {
  for (const item of items) {
    const li = document.createElement("li");
    li.textContent = item;
    list.appendChild(li);
  }
}

function main(): void {
  startClock(byId("time"));
  wireCounter(byId("count"), byId<HTMLButtonElement>("inc"));
  wireTheme(byId<HTMLButtonElement>("theme"));
  renderList(byId<HTMLUListElement>("features"), [
    "Authored in TypeScript, type-checked at build time",
    "Compiled to JS inside a one-shot ea-podman container",
    "Served as static files by Apache — no server process",
  ]);
}

main();
```

`~/ts-site/index.html`:

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>TypeScript Static PoC</title>
    <link rel="stylesheet" href="style.css" />
  </head>
  <body data-theme="light">
    <main>
      <h1>Dynamic static site, built from TypeScript</h1>
      <p>This clock ticks in your browser:</p>
      <p class="clock"><span id="time">--:--:--</span></p>

      <p>
        <button id="inc" type="button">Click me</button>
        — clicks: <strong id="count">0</strong>
      </p>

      <p><button id="theme" type="button">Theme: light</button></p>

      <h2>How this page works</h2>
      <ul id="features"></ul>
    </main>
    <script type="module" src="./main.js"></script>
  </body>
</html>
```

`~/ts-site/style.css`:

```css
:root { color-scheme: light dark; }
body {
  font-family: system-ui, sans-serif;
  margin: 3rem auto;
  max-width: 42rem;
  padding: 0 1rem;
  transition: background 0.2s, color 0.2s;
}
body[data-theme="dark"] { background: #14161a; color: #e8e8e8; }
.clock { font-size: 2rem; font-variant-numeric: tabular-nums; }
button { font: inherit; padding: 0.4rem 0.9rem; cursor: pointer; }
ul { line-height: 1.7; }
```

> Other static toolchains work the same way — swap the `build` script and
> `outDir` (e.g. `vite build`, `next build && next export` emitting to a
> `dist/`-style directory, then copied or pointed into the document root).

### Step 3 — Run the one-shot build via ea-podman

```bash
export PATH="/opt/cpanel/ea-podman/bin:/usr/local/cpanel/scripts:$PATH"

ea-podman install pocstatic \
  -v "$HOME/ts-site:/src" \
  -v "$HOME/public_html/app:/out" \
  -w /src \
  --entrypoint='["sh","-c","npm install --no-audit --no-fund && npm run build"]' \
  --i-understand-the-risks-do-it-anyway \
  docker.io/library/node:20-alpine
```

- **No `--cpuser-port`.** The build exposes no service, so no host port is
  published or firewalled.
- `-v "$HOME/ts-site:/src"` mounts the project source. The mount is **read-write**
  so `npm install` can write `node_modules` into it.
- `-v "$HOME/public_html/app:/out"` mounts the subdomain document root as the
  build **output**, **read-write** — the build must write into it (no `:ro`).
- `-w /src` runs the build from the project directory.
- `--entrypoint='["sh","-c","npm install … && npm run build"]'` installs the
  TypeScript compiler and runs the build **once, then exits**. `npm install`
  requires registry access (see Prerequisites). See the note below on why the
  command is passed this way.
- `--i-understand-the-risks-do-it-anyway` is required because `node:20-alpine`
  is an arbitrary (non-vetted) image.

> **The image must be the *last* argument.** `ea-podman install` for an arbitrary
> image requires the final argument to be the image name and rejects anything
> after it (`util.pm` `validate_start_args`: *"Last start arg does not look like
> an image name"*). You therefore **cannot** append a command such as
> `… node:20-alpine npm run build` — the install aborts. Supply the build command
> via podman's `--entrypoint` in **JSON form** (which carries its own arguments)
> *before* the image, as above.

> **`ea-podman` is built for long-running services, not one-off builds.** Its
> generated user systemd unit runs `podman start` on the container, so the build
> **re-runs whenever the service starts** — including on reboot (linger is
> enabled). For an idempotent build that simply rewrites the output this is
> harmless, but be aware of it. (`ea-podman` also emits a *"DEPRECATED command"*
> warning from `podman generate systemd`; this is internal to `ea-podman` and
> does not affect the build.)

> **Run the build as container root (do not pass `--user`).** Rootless podman
> maps container-root to the cPanel user's **real UID** on the host, so the
> output files are owned by the cPanel user and Apache can serve them. A non-root
> in-container UID would write files owned by a mapped `subuid` that Apache
> cannot read. The `node` image defaults to root, so the command above is
> correct as written.

### Step 4 — Confirm the build ran and the output landed

The container runs the build and exits `0`. Because `ea-podman` generates the
user systemd unit with `--restart-policy on-failure`, a clean exit is **not**
restarted — so the container being **stopped** afterward is the expected end
state for a build-only container.

`ea-podman list` only shows *running* containers (it wraps `podman ps` with no
`-a`), so the exited build container is **absent** there — that is expected, not
a failure. Use the registered-container view and the exited-state view instead:

```bash
ea-podman containers                 # registered list — pocstatic.cptest1.01 shows here
ea-podman status pocstatic.cptest1.01
podman ps -a --format '{{.Names}} {{.Status}}'   # shows "Exited (0)"
```

Verify the build output (owned by the cPanel user):

```bash
ls -l ~/public_html/app             # build output index.html, main.js, style.css
                                    # (owned by cptest1, alongside cPanel defaults
                                    #  cgi-bin/, php.ini, .htaccess)
podman logs pocstatic.cptest1.01    # shows npm install + tsc output from the build
```

### Step 5 — There is no wiring step

This is the heart of the contrast with the non-static PoC. Because the build
wrote its output **into the subdomain's document root**, Apache already serves
it. There is **no userdata reverse-proxy include and no `rebuildhttpdconf`**.

### Step 6 — Verify HTTPS end to end

AutoSSL normally provisions the certificate automatically. To force a check, run
it **as root** — `autossl_check` is a server-admin command, not a cPanel-user one
(it is not runnable from the user's SSH session above):

```bash
# as root, not the cPanel user
/usr/local/cpanel/bin/autossl_check --user=cptest1
```

Then fetch the page over HTTPS (from anywhere that resolves the domain):

```bash
curl -sk https://app.example.com/
curl -skI https://app.example.com/main.js   # 200, Content-Type: text/javascript
```

Expected response: the built `index.html` (the "Dynamic static site, built from
TypeScript" page), which references the compiled `main.js`.

The clock, counter, and theme toggle are wired up inside `main.js` and run
**client-side** in the visitor's browser — no server process sits behind the
request.

### Step 7 — Rebuild and teardown

**Rebuild / redeploy** = re-run the build. Either run it again against the same
container name (it allocates the next `.NN` suffix) or uninstall first:

```bash
ea-podman uninstall pocstatic.cptest1.01 --verify
# ...then repeat Step 3 to produce fresh output.
```

**Teardown** = remove the container and clear the served files:

```bash
ea-podman uninstall pocstatic.cptest1.01 --verify
rm -rf ~/public_html/app/*
```

> `uninstall` **requires `--verify`** (it refuses to run without it). It removes
> the systemd unit and unregisters the container, but **preserves the container
> directory** by renaming `~/ea-podman.d/<name>/` to `<name>.bak` rather than
> deleting it — remove the `.bak` separately if you want it gone. (The served
> output under `public_html` is cleared by the `rm` above.)

## Gotchas

- **`su -` / jailshell breaks rootless podman.** Always connect via direct SSH
  into a real bash shell (see the overview).
- **Run the build as container root** so output is owned by the cPanel user's
  real UID and is web-servable. A non-root in-container UID writes
  `subuid`-owned files Apache cannot read.
- **The output mount must be read-write.** The build writes into it; do not
  mount it `:ro`.
- **A build-only container ends up stopped — that's normal.** It exits `0` and
  `on-failure` does not restart it; `ea-podman list`/`status` will show it not
  running.
- **Source placement.** Because `install` runs the build immediately and the
  per-container directory (`~/ea-podman.d/<name>.<user>.NN/`) does not exist
  until then, the source lives in a user directory (`~/ts-site`) rather than
  inside the managed container directory. Productization should manage source
  and output placement explicitly (see below).
- **The build needs outbound network access.** `npm install` fetches the
  TypeScript compiler (and any other dependencies) from the package registry, so
  the container must be able to reach it. Productization constrains this to
  registries only (see below).
- **SELinux.** If a relabeling-enforced host rejects the bind mounts, append
  `:z` (shared) to the `-v` arguments.
- **Containers are excluded from normal cPanel backups.** Use `ea-podman backup`
  for container state; the **served output** under `public_html` is captured by
  normal account backups.

## Security considerations

The general `ea-podman` posture — rootless user-namespace isolation, trusted and
pinned images, the `--i-understand-the-risks-do-it-anyway` gate for arbitrary
images, and least-privilege mounts/capabilities — is covered in the
[ea-podman overview](./ea-podman.md). Specific to the static, build-only case:

- **No exposed service.** A static build publishes no port, so there is no
  network-reachable container surface to firewall or harden — only the static
  files served by Apache from the document root.

## What productization needs

This PoC stitches the steps together by hand. A shipped static-app path would
need:

- **A real build sandbox** (epic CPANEL-53922 §13.6): ephemeral per build, with
  CPU/memory/wall-clock/disk caps, outbound network restricted to package
  registries, isolated from other tenants, immutable artifact promotion, and
  **discard-on-failure** so a failed build leaves the previously served output
  untouched.
- **Managed source/output placement.** Generate and own the build input and the
  document-root output programmatically, rather than relying on hand-placed
  directories.
- **Runtime-as-data handlers.** Describe each static toolchain (Vite, Next
  export, etc.) as data with a build command and output directory, rather than
  bespoke per-app commands.
- **Structured errors.** Return machine-readable failure categories
  (`framework_detection_failed`, `build_failed`, …) so the UI/orchestration can
  react meaningfully.
- **Cleanup hooks.** On subdomain/account removal, tear down the container, its
  systemd unit, and the served output automatically.
