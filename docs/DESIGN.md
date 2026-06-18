# Web App Hub

## This Document

This document is not a design doc in the traditional sense. It's more like the base principles and requirements to base implementation on. In other words, if all of these things are met we have succeeded.

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

We should be able to support any language/framework. All languages/frameworks are supported via [Adaptors](#adaptors) and should require no changes to the [API](#api). e.g. If an [API](#api) change is required to add support for a new thing we have failed.

## API

This should cover all necessary tasks in web app lifecycle and management.

The API MUST have no [App Type](#app-types) specific knowledge and MUST do no [App Type](#app-types) specific logic.

Instead it will consume [App Type adaptors](#adaptors) and then, based on the adaptor/limits/input/etc, call [`ea-podman`](#ea-podman) appropriately.

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

**Cascading resource limits** (CPU and Memory per [App Type](#app-types)). Each level defaults to the next one up, so the effective value resolves in this precedence: **App → User → Global → [Adaptor](#adaptors) default**. A more specific level overrides the broader one and may set any value, higher or lower.

1. **[Adaptor](#adaptors)** default CPU and Memory per [App Type](#app-types)
1. **Global** default CPU and Memory per [App Type](#app-types) for this server
1. **User** default CPU and Memory per [App Type](#app-types)
1. **App** CPU and Memory of a specific _instance_

**Standalone limits** (set at a single level, no cascade).

1. **Global** Web App Hub feature on or off
1. **Global** [App Types](#app-types) allowed
1. **User** How many of each [App Type](#app-types) a user is allowed

## Domains

An app is **always deployed to a subdomain** whose label is the app’s [slug](#general-flow). A file URI / subdirectory on an existing domain is **YAGNI** — we’re not building it.

A new subdomain gets SSL the usual way and time frame. The open question is **SSL timing**: a user shouldn’t create an app, open its URL, and get a certificate error while AutoSSL catches up — a cert needs to be in place before the app is presented as ready. A **temporary domain** is also an option (works out of the box) and an acceptable fallback if prompt SSL proves too difficult for the initial release.

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
   2. detect which [App Type](#app-types) it is, using [Adaptors](#adaptors)
   3. configure it based on [Adaptors](#adaptors) and input
   4. deploy it to a subdomain
2. Lifecycle management
   1. Config updating
   2. Service state/control
   3. Update git (git pull)/container (`ea-podman upgrade …`)
3. Uninstall (`ea-podman uninstall …`)
   * Should cleanup subdomain and web server config and anything else outside of ea-podman.

Each app should have a slug, either given or derived from the zip or git name. That slug is used in the podman name (pod name and directory), the subdomain, and anywhere else we need to refer to it. Because the slug must be a valid subdomain label, its format is constrained to lowercase alphanumerics and hyphens — which also makes it path-safe for use in directory names.

Each app will log to `~/logs/webapps/SLUG.log`. `podman` can do this (and rotate them in real time) using the example flags in [the podman wiki article](https://webpros.atlassian.net/wiki/spaces/ZC/pages/6692208704/AI+friendly+Web+App+Hub+Technical#podman).

### `ea-podman`

Other things were evaluated and are problematic for one reason or another.

See https://webpros.atlassian.net/wiki/spaces/ZC/pages/6692208704/AI+friendly+Web+App+Hub+Technical#podman for the benefits of this approach.

### Adaptors

An “adaptor” is what will contain all data and logic about languages and their frameworks that we need to inform the [API](#api) so that it can operate on an app of a given language/framework.

The exact structure will materialize as the feature progresses.

They will definitely include:

1. What images/tags we support
2. What default CPU and memory limits should be
3. Detection logic
4. Determining exact commands to run for the task at hand, like build and start

**They must be separate from [API](#api) code/files**.

So separate that they could be managed in their own package without needing to update the [API](#api). Doing them in a separate package, while not required, would make that separation clearer, easier to preserve, and facilitate more rapid maintenance like any upstream-based EA4 pkg (after initial release the [API](#api) will rarely update but the adaptors will regularly change). If we want to do that initially or sometime later we will use `ea-web-app-hub`.

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
