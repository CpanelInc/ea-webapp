# Web App Hub

## This Document

This document is not a design doc in the traditional sense. It’s more like the base principles and requirements to base implementation on. In other words, if all of these things are met we have succeeded.

As such, it is intentionally light on implementation detail.

## The Feature

This feature is intended to improve the experience of deploying web apps from any source but especially AI-generated apps and AI-based deployment.

## Background

This document is distilled from https://webpros.atlassian.net/wiki/spaces/ZC/pages/6692208704/AI+friendly+Web+App+Hub+Technical

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

User should not be able to change these.

> **Note — these limits govern what our system does on a user’s behalf.** They’re the values the [API](#api)/[UI](#ui)/[MCP](#mcp) apply when deploying and managing an app through Web App Hub. A user with normal shell access still has ordinary container operability outside of that — they can run an arbitrary image or container directly, just as they can today, and those aren’t bound by Web App Hub’s limits. That’s expected container behavior, not a gap in this design; we’re noting it so the scope of the limits is clear. (And it may not even arise for WebPros Dashboard users if they can’t log into their cPanel account as a normal user.)

**Cascading resource limits** (CPU and Memory per [App Type](#app-types)). Each level defaults to the next one up, so the effective value resolves in this precedence: **App → User → Global → [Adapter](#adapters) default**. A more specific level overrides the broader one and may set any value, higher or lower.

1. **[Adapter](#adapters)** default CPU and Memory per [App Type](#app-types)
1. **Global** default CPU and Memory per [App Type](#app-types) for this server
1. **User** default CPU and Memory per [App Type](#app-types)
1. **App** CPU and Memory of a specific _instance_

**Standalone limits** (set at a single level, no cascade).

1. **Global** Web App Hub feature on or off
1. **Global** [App Types](#app-types) allowed
1. **User** How many of each [App Type](#app-types) a user is allowed

## Domains

An app can be deployed to any of three locations:

* `<SLUG>.<DOMAIN>` — a subdomain whose label is the app’s [slug](#general-flow). **Preferred/default.**
* `<DOMAIN>/<URI>` — a subdirectory of an existing domain.
* `<DOMAIN>` — the root of an existing domain.

In every case the target must be free to be used by the app:

* **If the location is not already a Web App Hub app** it may have existing content (e.g. the document root or subdirectory already serves something), so we **warn** that deploying the app will take over that location and any content there.
* **If the location is already a Web App Hub app**, it is **unavailable** — another app can’t be deployed over it.

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

Each app will log to `~/logs/webapps/SLUG.log`. `podman` can do this (and rotate them in real time) using the example flags in [the podman wiki article](https://webpros.atlassian.net/wiki/spaces/ZC/pages/6692208704/AI+friendly+Web+App+Hub+Technical#podman).

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

See https://webpros.atlassian.net/wiki/spaces/ZC/pages/6692208704/AI+friendly+Web+App+Hub+Technical#podman for the benefits of this approach.

### Adapters

An “adapter” is what will contain all data and logic about languages and their frameworks that we need to inform the [API](#api) so that it can operate on an app of a given language/framework.

The exact structure will materialize as the feature progresses.

They will definitely include:

1. What images/tags we support
2. What default CPU and memory limits should be
3. Detection logic
4. Determining exact commands to run for the task at hand, like build and start

**They must be separate from [API](#api) code/files**.

So separate that they could be managed in their own package without needing to update the [API](#api). Doing them in a separate package, while not required, would make that separation clearer, easier to preserve, and facilitate more rapid maintenance like any upstream-based EA4 pkg (after initial release the [API](#api) will rarely update but the adapters will regularly change). If we want to do that initially or sometime later we will use `ea-web-app-hub`.

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
