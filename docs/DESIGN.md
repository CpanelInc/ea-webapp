# Web Apps

## This Document

This document is not a design doc in the traditional sense. It’s more like the base principles and requirements to base implementation on. In other words, if all of these things are met we have succeeded.

As such, it is intentionally light on implementation detail.

## The Feature

This feature is intended to improve the experience of deploying web apps from any source but especially AI-generated apps and AI-based deployment.

## Background

This document is distilled from https://webpros.atlassian.net/wiki/spaces/ZC/pages/6692208704/AI+friendly+Web+Apps+Technical

… which is distilled from the TI’s epic’s descriptions and various discussions

… which is distilled from https://webpros.atlassian.net/wiki/spaces/PROD/pages/6644629597 and https://webpros.atlassian.net/browse/TI-205

There is also this phase 1 prioritization document: https://webpros.atlassian.net/wiki/spaces/PROD/pages/6688145414/Phase+1+Feature+Prioritization+Launch+Blockers+vs+Fast+Follow

## App Types

Most AI apps are Node.js-based, so we are starting with NodeJS support.

We should be able to support any language/framework. All languages/frameworks are supported via [Adapters](#adapters) and should require no changes to the [API](#api). e.g. If an [API](#api) change is required to add support for a new thing we have failed.

## API

This should cover all necessary tasks in web app lifecycle and management.

The API MUST have no [App Type](#app-types) specific knowledge and MUST do no [App Type](#app-types) specific logic.

Instead it will consume [App Type adapters](#adapters) and then, based on the adapter/limits/input/etc, call [`ea-podman`](#ea-podman) appropriately.

For example, a “get available” call would return a subset of [Adapter](#adapters) data filtered through the applicable [limits](#limits): first the server settings for which [App Types](#app-types) are enabled at all (e.g. Node.js yes, Python no, PSGI yes), then the user’s usage on top of that (e.g. Node.js 0, PSGI 2). It would also include the user’s current calculated limits and usage — e.g. for Node.js: the user has 1, is limited to 2, and the current Node.js resource limits are ….

## MCP

The [API](#api) is the contract; any MCP or [UI](#ui) is a client of it. WebPros Dashboard MCP (any MCP really) will consume the [API](#api)’s openapi spec files to be able to operate on a user’s web apps.

**The MCP server itself, and the auth/token system that lets it talk to the cPanel API, are out of scope here.** That auth layer is being built separately by 3 dedicated TIs and is a hard prerequisite for any MCP↔cPanel interaction. Our responsibility ends at the [API](#api) contract.

## UI

UIs, just like MCPs, will consume the [API](#api). First implementing in `meridian` then later `jupiter`.

## Mixpanel

* Our [UIs](#ui) will do mixpanel
* Our [MCP](#mcp) will do mixpanel
* Our [API](#api) will not do mixpanel
  * doing so would result in duplicates
  * results would be inaccurate when caller fails to pass correct info
* We don’t/can’t track 3rdparty usage in mixpanel

## Limits

Requirements in this section are written in [EARS](https://alistairmavin.com/ears/) (Easy Approach to Requirements Syntax). Each has a stable ID (e.g. `LIM-RES-4`) so code, tests, and Jira cases can cite it. In them, **the system** means Web Apps: the [API](#api) and the [UI](#ui)/[MCP](#mcp) clients acting through it. The templates used are:

* Ubiquitous: _The system shall …_
* Event-driven: _When \<trigger\>, the system shall …_
* State-driven: _While \<state\>, the system shall …_
* Optional feature: _Where \<feature is present\>, the system shall …_
* Unwanted behavior: _If \<condition\>, then the system shall …_

Prose that is not a requirement (rationale, background, the podman flag table) is kept as written and does not carry an ID. Open questions have no requirement until they are decided; they are collected under [Open questions](#open-questions).

* **LIM-1** The system shall not allow a user to change their resource totals, their app count maximum, or anything that sets them.
* **LIM-2** The system shall let a user choose, within their total, how much each of their apps gets.
* **LIM-3** The system shall not apply limits per [App Type](#app-types); the system shall base limits only on the resources and ports an app uses.

> **Note — these limits govern what our system does on a user’s behalf.** They’re the values the [API](#api)/[UI](#ui)/[MCP](#mcp) apply when deploying and managing an app through Web Apps. A user with normal shell access still has ordinary container operability outside of that — they can run an arbitrary image or container directly, just as they can today, and those aren’t bound by Web Apps’ limits. That’s expected container behavior, not a gap in this design; we’re noting it so the scope of the limits is clear. (And it may not even arise for WebPros Dashboard users if they can’t log into their cPanel account as a normal user.)

### Resource limits

The resources are **CPU** and **Memory**.

* **LIM-RES-1** The system shall support limits on two resources: CPU and Memory.
* **LIM-RES-2** Where a resource has both a hard and a soft limit, the system shall support both and track each on its own.
* **LIM-RES-3** The system shall count hard allocations against the hard total and soft allocations against the soft total.

**Total per user.** Each level defaults to the one above it. A more specific level overrides a broader one and may set any value, higher or lower.

1. **Default** — the built-in total per user, shipped with Web Apps.
1. **Global** — this server’s total per user.
1. **User** — this user’s total, set on their WHM account package.

* **LIM-RES-4** The system shall resolve a user’s effective total for each resource limit in the precedence User, then Global, then Default, using the first level that has a value.
* **LIM-RES-5** Where a more specific level sets a total, the system shall use it whether it is higher or lower than the broader level’s.

**Allocation per app.** Every app _instance_ has its own CPU and Memory setting, which the user chooses from their remaining total.

* **LIM-RES-6** The system shall give every app instance its own CPU and Memory setting.
* **LIM-RES-7** The system shall not create an app instance without a CPU and Memory setting.
* **LIM-RES-8** The system shall not provide a fallback for an app instance that has no setting; such an app is a defect, not a state to handle.
* **LIM-RES-9** The system shall calculate usage as the sum of the configured per-app settings, and shall not use measured consumption.
* **LIM-RES-10** When a deploy is requested, if the app’s setting does not fit within the remaining total (total minus usage), then the system shall refuse the deploy.
* **LIM-RES-11** When a change to an app’s setting is requested, if the new value does not fit within the remaining total, counting that app’s current allocation as available, then the system shall refuse the change.
* **LIM-RES-12** When a deploy is requested, the system shall count the app’s allocation toward usage immediately, so that queued or concurrent deploys cannot together exceed the total.
* **LIM-RES-13** When an app is deleted, the system shall release its allocation.
* **LIM-RES-14** When a deploy fails or is cancelled, the system shall release the allocation reserved for it when it was requested.
* **LIM-RES-15** When a total is lowered below current usage, the system shall not stop running apps, and shall flag the overage.
* **LIM-RES-16** While usage exceeds a total, the system shall refuse new deploys.
* **LIM-RES-17** If a limit value is not positive, then the system shall reject it.
* **LIM-RES-18** If a soft limit exceeds its hard limit, then the system shall reject it.

#### Podman flags

| Limit | Podman flag | cgroup v2 | cgroup v1 |
|---|---|---|---|
| Hard memory | `--memory` | `memory.max` — ceiling; OOM-kill above it | `memory.limit_in_bytes` — ceiling; OOM-kill above it |
| Hard memory (swap) | `--memory-swap`, set equal to `--memory` | `memory.swap.max` | `memory.memsw.limit_in_bytes` — needs kernel swap accounting |
| Soft memory | `--memory-reservation` | `memory.low` — floor protected from reclaim | `memory.soft_limit_in_bytes` — reclaim target under memory pressure |
| Hard CPU | `--cpus` (shorthand for `--cpu-period` + `--cpu-quota`) | `cpu.max` — ceiling on CPU time | `cpu.cfs_quota_us` / `cpu.cfs_period_us` — ceiling on CPU time |
| Soft CPU | `--cpu-shares` | `cpu.weight` — relative priority, converted from shares | `cpu.shares` — relative priority, default 1024 |

* **LIM-ENF-1** When the system starts an app container, it shall apply the app’s limits using the podman flags in the table above.
* **LIM-ENF-2** When the system applies a hard memory limit, it shall set `--memory-swap` equal to `--memory`.
* **LIM-ENF-3** Where the host uses cgroup v2, the system shall set `MemoryLow` on the account’s user slice, matching the user’s soft memory total.
* **LIM-ENF-4** While the host uses cgroup v1, the system shall not report limits on a rootless Web Apps container as applied.
* **LIM-ENF-5** If a config the account controls contains any of the flags below, then ea-podman shall reject it, because they bypass the caps or set limits the admin didn’t:
  * `--memory`, `--memory-swap`, `--memory-reservation`
  * `--cpus`, `--cpu-period`, `--cpu-quota`, `--cpu-shares` / `-c`
  * `--cgroup-parent`, `--cgroups=disabled`

**Swap.** `--memory-swap` is set equal to `--memory` so a container cannot use swap beyond its memory cap; otherwise podman allows up to twice the cap in total. On cgroup v1 this requires kernel swap accounting; where it is unavailable, swap cannot be limited.

**Hard limits** are absolute amounts, so summing them against a user’s total means exactly what it says, on either cgroup version.

**Soft memory** protection is hierarchical on cgroup v2: a container’s `memory.low` is effective only up to the protection set on its parent cgroups. Enforcement therefore sets a root-side floor (`MemoryLow`) on the account’s user slice, matching the user’s soft total. On cgroup v1, the soft limit protects nothing; the kernel only uses it under system-wide memory pressure, reclaiming first from cgroups furthest over their soft limit.

**Soft CPU** is a ratio, not an amount, on either cgroup version. Shares only divide contested CPU among siblings in the same parent cgroup, so a rootless container’s shares rank a user’s apps against each other, not against other accounts. Summing shares against a total does not correspond to a quantity of CPU.

**cgroup v1 hosts.** Rootless podman cannot apply resource limits on cgroup v1; it ignores them with a warning. Web Apps containers are rootless, so on v1 hosts none of these limits are enforced, and the API must not report them as applied. The v1 column applies only to rootful containers.

#### Open questions

No requirement is written for these until they are decided.

* **Soft CPU.** Drop soft CPU; keep it as a per-app priority not counted against a total; or express it in CPU units, convert it to shares internally, and accept that it only ranks a user’s own apps.
* **cgroup v1 hosts.** Require cgroup v2 as a minimum; warn in WHM that limits aren’t enforced; or rely on CloudLinux LVE for account-wide limits.

### App count

App count doesn’t govern resources — the totals above do. It is limited only because each app uses a port from a pool shared by every account on the server, so one account must not be able to exhaust it. Resolves in this precedence: **User → Global → Default**.

1. **Default** — the built-in maximum apps per user, shipped with Web Apps.
1. **Global** — this server’s maximum apps per user.
1. **User** — this user’s maximum, set on their WHM account package.

* **LIM-CNT-1** The system shall resolve a user’s maximum app count in the precedence User, then Global, then Default, using the first level that has a value.
* **LIM-CNT-2** When a deploy is requested, the system shall count a slot as used immediately.
* **LIM-CNT-3** When an app is deleted, the system shall release its slot.
* **LIM-CNT-4** When a deploy fails or is cancelled, the system shall release the slot reserved for it.
* **LIM-CNT-5** When a maximum is lowered below the current count, the system shall not stop running apps.
* **LIM-CNT-6** While a user’s count is not under their maximum, the system shall refuse new deploys.
* **LIM-CNT-7** If the server’s port pool is exhausted, then the system shall fail the deploy with a clear error, even when the user is under their count.

### Adapter recommendations

* **LIM-REC-1** Each [Adapter](#adapters) shall specify a recommended minimum CPU and Memory for its [App Type](#app-types).
* **LIM-REC-2** If an app’s setting is below the recommended minimum, or the remaining total cannot cover it, then the system shall warn the user.
* **LIM-REC-3** The system shall not block, on account of a recommendation, a deploy that otherwise fits.

### Standalone limits

Set at a single level, no cascade.

1. **Global** — Web Apps feature available on this server.
   * A `/var/cpanel/feature-flags/NAME` file that the API package installs.
1. **User** — Web Apps feature on or off for this user.
   * Driven by WHM account packages + feature lists.

* **LIM-STD-1** The system shall resolve each standalone limit at a single level, with no cascade.
* **LIM-STD-2** The API package shall install the `/var/cpanel/feature-flags/NAME` file, and the system shall treat Web Apps as available on a server only when that file is present.
* **LIM-STD-3** The system shall treat Web Apps as available to a user only when the feature is on for that user, as set by WHM account packages and feature lists.

## Domains

An app can be deployed to any of three locations:

* `<SLUG>.<DOMAIN>` — a subdomain whose label is the app’s [slug](#general-flow). **Preferred/default.**
* `<DOMAIN>/<URI>` — a subdirectory of an existing domain. (Will be later CPANEL-54663)
* `<DOMAIN>` — the root of an existing domain. (Will be later CPANEL-54662)

In every case the target must be free to be used by the app:

* **If the location is not already a Web Apps app** it may have existing content (e.g. the document root or subdirectory already serves something), so we **warn** that deploying the app will take over that location and any content there.
* **If the location is already a Web Apps app**, it is **unavailable** — another app can’t be deployed over it.

For anything other than a fresh `<SLUG>.<DOMAIN>`, that warning is paired with an **“I understand” checkbox**, surfaced as an explicit API parameter the caller must set to confirm it’s OK to use the existing location. The [API](#api) refuses the deploy unless that parameter is present.

There’s also existing custom config to consider: on a domain already in use, other config (rewrites, handlers, etc.) may take precedence and result in the app not being served. That’s another reason a fresh, unused `<SLUG>.<DOMAIN>` is the ideal target.

A new subdomain gets SSL the usual way and time frame. The open question is **SSL timing**: a user shouldn’t create an app, open its URL, and get a certificate error while AutoSSL catches up — a cert needs to be in place before the app is presented as ready. A **temporary domain** is also an option (works out of the box) and an acceptable fallback if prompt SSL proves too difficult for the initial release.

## Images

Apps run from container images, and the [Adapters](#adapters) declare which images/tags each [App Type](#app-types) supports.

**The plan for the initial release is to pull those images directly from Docker Hub** — the standard registry, no extra infrastructure. Recording it here so it’s an explicit decision.

A mirror is a possible future enhancement, not a requirement. These are things we could do now, later, or never:

* **Helping users help themselves** is an easy win that would buy us time — and it’s basically documentation (maybe a script or two, but probably not). That covers setting up Docker Hub credentials (e.g. for higher pull rate limits), other setting optimizations, and configuring their own mirror.
* **A WebPros-hosted mirror** doesn’t require new infrastructure. It should be a matter of grabbing the images we need, building the metadata, and publishing on httpupdate — just a scheduled pipeline script.

## Databases

Databases are **out of scope for the July 2026 release** (the DB wizard is a fast follow, so there’s time to settle the details). When we do build it, the principles are:

* The app’s [slug](#general-flow) is king — if we create a database, we name it from the slug.
* Most likely we use the existing cPanel database API and follow the database limits it already imposes.
* The app and its database must be tied together so neither gets orphaned.

## Errors

The [API](#api) must return **machine-readable errors** — structured output with stable error identifiers plus human-readable detail, not just free-form text — so a consumer such as an [MCP](#mcp) can reliably detect what went wrong and self-correct (e.g. a limit was hit, or a build failed for a specific reason) without scraping prose.

## Misc

### General Flow

1. Install (`ea-podman install …`)
   1. get a zip file or git repo
   2. detect which [App Type](#app-types) it is, using [Adapters](#adapters)
   3. configure it based on [Adapters](#adapters) and input
   4. deploy it to a subdomain
2. Lifecycle management
   1. Config updating
   2. Service state/control
   3. Update [app code](#updating-an-app) (git: `git pull`) and/or container (`ea-podman upgrade …`)
3. Uninstall (`ea-podman uninstall …`)
   * Should cleanup subdomain and web server config and anything else outside of ea-podman.

Each app should have a slug, either given or derived from the zip or git name. That slug is used in the podman name (pod name and directory), the subdomain, and anywhere else we need to refer to it. Because the slug must be a valid subdomain label, its format is constrained to lowercase alphanumerics and hyphens — which also makes it path-safe for use in directory names.

Each app will log to `~/logs/webapps/SLUG.log`. `podman` can do this (and rotate them in real time) using the example flags in [the podman wiki article](https://webpros.atlassian.net/wiki/spaces/ZC/pages/6692208704/AI+friendly+Web+Apps+Technical#podman).

### Updating an App

Two things can be updated independently: the **container/image** and the **app code**.

- **Container/image** updates apply to any app regardless of source, via `ea-podman upgrade …`.
- **App code** updates depend on how the app was deployed.

**Git-deployed apps** have a first-class re-deploy path: `git pull` then deploy, with `.gitignore` expressing which paths (uploads, generated files, runtime config, etc.) are preserved across re-deploys. This is the recommended path for any app under ongoing development.

**Zip-deployed apps** have no such path, and we deliberately do not invent one. A zip is a one-shot snapshot: it carries no pull source and no manifest of what is precious. A running app may also have accreted runtime state the original zip never knew about — a [database](#databases), uploaded media, generated config — and an app that started static may no longer be. So we never merge a new zip into a running app (neither "unzip on top" nor "wipe and unzip with smart logic"), because guessing what to preserve is re-inventing a fragile, partial git.

Instead, a zip-deployed app has two explicit, opt-in update options:

1. **Convert to git.** The user attaches the app to a git remote, after which it becomes a git-deployed app and inherits the full re-deploy lifecycle above (including `.gitignore`). This is the recommended path once an app needs ongoing updates. Conversion is a one-time migration, not new lifecycle machinery — it moves the app onto the path we already support rather than building a second one.
2. **Replace from a new zip (full redo).** The app's code/app directory and container are wiped and rebuilt from the new zip. Because this discards anything not in the new zip, it is gated behind an explicit acknowledgement — not free-form text but a deterministic flag/field, so an [MCP](#mcp)/[API](#api) consumer opts in unambiguously and can never trigger a wipe by accident. A tied [database](#databases) is preserved by default; removing it is a separate, explicit action so neither the app nor its data is silently orphaned.

### Streaming Output

Long-running [API](#api) actions (build, deploy, etc.) and app logs need to stream output to the caller so an [MCP](#mcp) can follow progress and debug problems. The live experience for [UIs](#ui) is part of the UI epic; for the [API](#api) we should be able to stream via the existing generic SSE API (run a command, then tail its output), with a web-app-specific endpoint as an option if that proves insufficient.

### `ea-podman`

Other things were evaluated and are problematic for one reason or another.

See https://webpros.atlassian.net/wiki/spaces/ZC/pages/6692208704/AI+friendly+Web+Apps+Technical#podman for the benefits of this approach.

### Adapters

An “adapter” is what will contain all data and logic about languages and their frameworks that we need to inform the [API](#api) so that it can operate on an app of a given language/framework.

The exact structure will materialize as the feature progresses.

They will definitely include:

1. What images/tags we support
2. What default CPU and memory limits should be
3. Detection logic
4. Determining exact commands to run for the task at hand, like build and start

**They must be separate from [API](#api) code/files**.

So separate that they could be managed in their own package without needing to update the [API](#api). Doing them in a separate package, while not required, would make that separation clearer, easier to preserve, and facilitate more rapid maintenance like any upstream-based EA4 pkg (after initial release the [API](#api) will rarely update but the adapters will regularly change). If we want to do that initially or sometime later we will use `ea-webapp`.

**They must be extendable by 3rd parties and admins**.

This is very simple, see https://webpros.atlassian.net/wiki/spaces/ZC/pages/6691619038/Settings+Config#3rdparty for more)

### Out of scope for July 2026 release

- WHM UI
- Jupiter UI
- dormant behavior (podman’s pause/unpause)
- staging apps
- Backup hooks/transfers
- Mass upgrade management for admin or user (there is `ea-podman upgrade --all`)
- Private git repo SSH key management (phase 2 — not July). Initial release supports public repos (and zip uploads); secure storage/handling of deploy keys for private repos comes later.
- Databases (see [Databases](#databases)) — DB wizard is a fast follow
- Application Manager deprecation or app migration:
