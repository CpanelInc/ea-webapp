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

Prose that is not a requirement (rationale, background, the podman flag table) is kept as written and does not carry an ID.

The section is organized as: the requirements (below, through [Standalone limits](#standalone-limits)), then [Acceptance criteria](#acceptance-criteria), [Examples](#examples), [Constraints](#constraints) and [Out of scope](#out-of-scope).

* **LIM-1** The system shall not allow a user to change their resource totals, their app count maximum, or anything that sets them.
* **LIM-2** The system shall let a user choose, within their total, how much each of their apps gets.
* **LIM-3** The system shall not apply limits per [App Type](#app-types); the system shall base limits only on the resources and ports an app uses.

> **Note — these limits govern what our system does on a user’s behalf.** They’re the values the [API](#api)/[UI](#ui)/[MCP](#mcp) apply when deploying and managing an app through Web Apps. A user with normal shell access still has ordinary container operability outside of that — they can run an arbitrary image or container directly, just as they can today, and those aren’t bound by Web Apps’ limits. That’s expected container behavior, not a gap in this design; we’re noting it so the scope of the limits is clear. (And it may not even arise for WebPros Dashboard users if they can’t log into their cPanel account as a normal user.)

### Resource limits

The resources are **CPU** and **Memory**.

Memory amounts are in MiB (1,048,576 bytes), the unit podman’s `m` suffix and the plugin’s `memory_mb` values use.

* **LIM-RES-1** The system shall support limits on two resources: CPU and Memory.
* **LIM-RES-2** Where a resource has both a hard and a soft limit, the system shall support both and track each on its own.
* **LIM-RES-3** The system shall count hard allocations against the hard total and soft memory allocations against the soft memory total. CPU weights, the soft CPU limit, are not counted (LIM-RES-37).

**Total per user.** Each level defaults to the one above it. A more specific level overrides a broader one and may set any value, higher or lower.

1. **Default** — the built-in total per user, shipped with Web Apps.
1. **Global** — this server’s total per user.
1. **User** — this user’s total, set on their WHM account package.

* **LIM-RES-4** The system shall resolve a user’s effective total for each resource limit in the precedence User, then Global, then Default, using the first level that has a value.
* **LIM-RES-5** Where a more specific level sets a total, the system shall use it whether it is higher or lower than the broader level’s.

**Allocation per app.** Every app _instance_ has its own CPU and Memory setting, which the user chooses from their remaining total. It also has a CPU weight, which the user chooses from five fixed values and which is not drawn from a total (LIM-RES-19, LIM-RES-37).

* **LIM-RES-6** The system shall give every app instance its own CPU setting, its own CPU weight, and its own Memory setting, where the Memory setting is a hard limit and a soft limit.
* **LIM-RES-7** The system shall not create an app instance without a CPU setting, a CPU weight and a Memory setting.
* **LIM-RES-8** The system shall not provide a fallback for an app instance that has no setting; such an app is a defect, not a state to handle.
* **LIM-RES-9** The system shall calculate usage as the sum of the configured per-app settings that have a total (LIM-RES-37), and shall not use measured consumption.
* **LIM-RES-10** When a deploy is requested, if the app’s setting does not fit within the remaining total (total minus usage), then the system shall refuse the deploy.
* **LIM-RES-11** When a change to an app’s setting is requested, if the new value does not fit within the remaining total, counting that app’s current allocation as available, then the system shall refuse the change.
* **LIM-RES-12** When a deploy is requested, the system shall count the app’s allocation toward usage immediately, so that queued or concurrent deploys cannot together exceed the total.
* **LIM-RES-34** The system shall check and reserve a user’s allocation (LIM-RES-10, LIM-RES-12) and app slot (LIM-CNT-2) as one critical section under that user’s registry lock, held from the check until the reservation is saved.
* **LIM-RES-13** When an app is deleted, the system shall release its allocation.
* **LIM-RES-14** When a deploy fails or is cancelled, the system shall release the allocation reserved for it when it was requested.
* **LIM-RES-15** When a total is lowered below current usage, the system shall not stop running apps, and shall flag the overage (see LIM-RES-22 and LIM-RES-23).
* **LIM-RES-16** While usage exceeds a total, the system shall refuse new deploys.
* **LIM-RES-17** If a limit value is not positive, then the system shall reject it.
* **LIM-RES-18** If an app’s soft memory limit exceeds its hard memory limit, or a user’s soft memory total exceeds their hard memory total, then the system shall reject it.
* **LIM-RES-19** The system shall support a soft CPU limit as a CPU weight, which the [API](#api) accepts as one of five named values: `very_low`, `low`, `normal`, `high` and `very_high`. CPU therefore has a hard limit and a weight, and Memory has a hard limit and a soft limit. A user may also set any other `--cpu-shares` value in their own `ea-podman.json` (LIM-RES-41).

**Lock hold time.** The registry lock is per user, so it only makes one user’s own requests wait for each other. Today `stage()` holds it across a git clone or archive extraction bounded at 300 seconds, so a second request from the same user can wait that long. This is accepted. The new checks are cheap reads of the registry, and LIM-RES-34 must not add network or build work inside the lock.

**CPU weight.** A CPU weight is a priority among a user’s own apps, not an amount of CPU. Each weight maps to a fixed `--cpu-shares` value, and each step doubles the one below it:

| `cpu_weight` | `--cpu-shares` | Relative to `normal` |
|---|---|---|
| `very_low` | 256 | 1/4 |
| `low` | 512 | 1/2 |
| `normal` | 1024 | 1 |
| `high` | 2048 | 2 |
| `very_high` | 4096 | 4 |

* **LIM-RES-35** The system shall map each CPU weight to the `--cpu-shares` value in the table above, and shall not accept any other share value through the [API](#api).
* **LIM-RES-36** When a deploy request gives no CPU weight, the system shall use `normal`. The weight lives only as the `--cpu-shares` value in the container’s recorded start arguments (`ea-podman.json`), and the system shall not store it anywhere else.
* **LIM-RES-37** The system shall not count CPU weights toward usage or against a total, and shall not give them a total, a cascade level or an overage.
* **LIM-RES-38** If a CPU weight in an [API](#api) request is not one of the five values, including `custom`, then the system shall reject it.
* **LIM-RES-40** The system shall read an app’s CPU weight from the `--cpu-shares` value in its container’s recorded start arguments. When the value is one of those in the table above, the [API](#api) shall report its name. For any other value, the [API](#api) shall report `cpu_weight` of `custom` and the raw number as `cpu_shares`, and shall not accept `custom` as input.
* **LIM-RES-41** Where a user has set their own `--cpu-shares` value in an app’s `ea-podman.json`, the system shall pass it unchanged and shall not rewrite it on a redeploy, a restart or any other change, except a change of CPU weight through the [API](#api) (LIM-ENF-16). A weight only ranks that user’s own apps (LIM-RES-37), so the system shall not restrict the value; choosing one that podman accepts is the user’s responsibility.

**Build containers.** An app is built in a separate, temporary container that needs far more than the app does while running.

* **LIM-RES-20** The system shall not count the resources of a build container toward a user’s usage.
* **LIM-RES-21** The system shall limit each build container to a fixed cap that the user cannot change.
* **LIM-RES-32** The system shall run at most one build container per user at a time, so that the memory a user’s builds can use is bounded by one build cap, not by the number of apps.
* **LIM-RES-33** If a user requests a deploy while one of their build containers is running, then the system shall refuse the deploy, before reserving any allocation or app slot, and return the error category `build_in_progress`.
* **LIM-RES-39** The system shall run each build container at the `low` CPU weight, fixed and not changeable by the user, so that a build contests the user’s running apps for CPU at half the weight of a `normal` app.

**Overage.** An overage is usage above a total, for example after the total is lowered (LIM-RES-15).

* **LIM-RES-22** The system shall derive an overage from the current totals and usage each time it is needed, and shall not store it.
* **LIM-RES-23** The [API](#api) shall report, for each resource, the amount by which usage exceeds the total, in the same call that reports limits and usage.
* **LIM-RES-24** If a deploy or a change is refused because of a limit, then the [API](#api) shall return the error category `limit_exceeded` and a separate `error_limit` value that names which limit was hit (see LIM-RES-30).

**Existing apps.** Apps deployed before per-app allocations existed have no setting, which LIM-RES-7 and LIM-RES-8 do not allow.

* **LIM-RES-25** When Web Apps is upgraded to a version with per-app allocations, the system shall once, during the upgrade and not on first read, set the Memory of each existing app instance to the amount it has at that time.
* **LIM-RES-26** When the upgrade in LIM-RES-25 runs, the system shall set the CPU of each existing app instance to the default for its [Adapter](#adapters), because CPU has not been limited until then and a limit must be positive (LIM-RES-17), and shall record `--cpu-shares=1024` (`normal`) in the start arguments of its container, which takes effect at the next recreate (LIM-RES-36).
* **LIM-RES-27** The built-in Default totals shall be 2048 MiB of hard memory, 1024 MiB of soft memory and 4.0 CPU, enough for the default maximum of 4 apps at 512 MiB hard, 256 MiB soft and 1.0 CPU each. The Default soft memory total is always set, so the cascade in LIM-RES-4 always ends in a value for every resource. An adapter that sets no default CPU of its own shall default to 1.0 CPU.
* **LIM-RES-28** If the upgrade in LIM-RES-25 leaves a user in overage, for example a package that allows 10 apps against the 2048 MiB Default, then the system shall leave their apps running and refuse new deploys under LIM-RES-16 until their usage is within the total; this is intended, not a defect.
* **LIM-RES-29** When the upgrade in LIM-RES-25 finishes, the system shall log how many users it left in overage.

**Error identifiers.** A failed call carries one `error_category` value. Every refusal for a limit uses the category `limit_exceeded`, and a second metadata field, `error_limit`, names the limit. Three other failures are their own categories.

| `error_category` | `error_limit` | Returned when |
|---|---|---|
| `limit_exceeded` | `memory_hard` | a deploy or change does not fit the hard memory total |
| `limit_exceeded` | `memory_soft` | a deploy or change does not fit the soft memory total |
| `limit_exceeded` | `cpu_hard` | a deploy or change does not fit the CPU total |
| `limit_exceeded` | `app_count` | the user is not under their maximum app count |
| `port_pool_exhausted` | none | the server’s port pool is exhausted |
| `build_in_progress` | none | the user already has a build container running |
| `webapps_unavailable_limits_not_enforced` | none | limits cannot be enforced for either resource and the administrator has not acknowledged |

* **LIM-RES-30** The [API](#api) shall use the `error_category` and `error_limit` values in the table above, and shall not rename them once released.
* **LIM-RES-31** The system shall keep returning `limit_exceeded` as the `error_category` for an app count refusal, as it does today, so clients that match on it keep working, and shall add `error_limit` without changing that category.

#### Podman flags

| Limit | Podman flag | cgroup v2 | cgroup v1 |
|---|---|---|---|
| Hard memory | `--memory` | `memory.max` — ceiling; OOM-kill above it | `memory.limit_in_bytes` — ceiling; OOM-kill above it |
| Hard memory (swap) | `--memory-swap`, set equal to `--memory` | `memory.swap.max` | `memory.memsw.limit_in_bytes` — needs kernel swap accounting |
| Soft memory | `--memory-reservation` | `memory.low` — floor protected from reclaim | `memory.soft_limit_in_bytes` — reclaim target under memory pressure |
| Hard CPU | `--cpus` (shorthand for `--cpu-period` + `--cpu-quota`) | `cpu.max` — ceiling on CPU time | `cpu.cfs_quota_us` / `cpu.cfs_period_us` — ceiling on CPU time |
| Soft CPU (CPU weight) | `--cpu-shares` | `cpu.weight` - relative priority, converted from shares | `cpu.shares` - relative priority, default 1024 |

* **LIM-ENF-1** When the system starts an app container, it shall apply the app’s limits for each resource whose limits can be enforced (LIM-ENF-4), using the podman flags in the table above.
* **LIM-ENF-2** When the system applies a hard memory limit, it shall set `--memory-swap` equal to `--memory` where swap can be limited, meaning the user’s service manager has a `memory.swap.max` file. Where swap cannot be limited, the system shall pass `--memory` alone and note that swap is not capped, because podman refuses to start a container that is given `--memory-swap` without swap accounting.
* **LIM-ENF-3** Where soft memory limits can be enforced (LIM-ENF-4), the system shall set `MemoryLow` on the account’s user slice, matching the user’s soft memory total.
* **LIM-ENF-4** Where the host uses cgroup v2, the system shall treat a resource’s limits as enforceable when the controller for it is delegated to the user’s service manager (`user@<uid>.service`): the memory controller for Memory limits, the cpu controller for CPU limits (the hard limit and the weight). Soft memory limits are enforceable only when, in addition, the cgroup2 mount has `memory_recursiveprot`, because that is what lets the floor set on the user slice (LIM-ENF-3) reach containers below the intermediate cgroups. The system shall enforce limits that are enforceable and report each of hard memory, soft memory and CPU as enforced or not.
* **LIM-ENF-4a** If a limit cannot be enforced, then the system shall not pass its flags, because podman ignores them with a warning on every start: `--memory` and `--memory-swap` for hard memory, `--memory-reservation` and `MemoryLow` for soft memory, and `--cpus` and `--cpu-shares` for CPU. A `--cpu-shares` value the user set in their own `ea-podman.json` is theirs and stays (LIM-RES-41); where the cpu controller is not delegated, podman ignores it with a warning.
* **LIM-ENF-5** If a config the account controls contains any of the flags below, then ea-podman shall reject it (this is ea-podman’s work, tracked in CPANEL-57893, not the Web Apps plugin’s), because they bypass the caps or set limits the admin didn’t. `--cpu-shares` and `-c` are deliberately not in this list (LIM-RES-41):
  * `--memory`, `--memory-swap`, `--memory-reservation`
  * `--cpus`, `--cpu-period`, `--cpu-quota`
  * `--cgroup-parent`, `--cgroups=disabled`
* **LIM-ENF-6** If a resource’s limits cannot be enforced on the host (see LIM-ENF-4), then the system shall still apply all totals, allocation checks, and app count checks, and shall report that resource as not enforced.
* **LIM-ENF-7** If a limit cannot be enforced on the host, then the system shall warn the administrator in WHM, naming that limit (hard memory, soft memory or CPU), that it is not enforced, that a running app can use more than its allocation, and what is required for enforcement: cgroup v2 with the controller for it delegated, and for soft memory also `memory_recursiveprot`.
* **LIM-ENF-8** While neither Memory limits nor CPU limits can be enforced on the host and an administrator has not explicitly acknowledged that, the system shall treat Web Apps as unavailable on the server. While at least one of them can be enforced, the system shall treat Web Apps as available and shall still warn under LIM-ENF-7.
* **LIM-ENF-9** The [API](#api) shall report, for each of hard memory, soft memory and CPU, in a machine-readable field, whether that limit is enforced, so that [UIs](#ui) and [MCPs](#mcp) can tell their users.
* **LIM-ENF-10** The warning in LIM-ENF-7 shall link to a public-facing documentation page that describes the limitations of cgroup v1 hosts and the ways to move to cgroup v2, including the CloudLinux LVE alternative for account-wide limits.
* **LIM-ENF-11** The system shall store the administrator’s acknowledgement in LIM-ENF-8 as a WHM Tweak Setting, in the shared `Plugins` Tweak Settings module (`Whostmgr::TweakSettings::Plugins`, stored in `/var/cpanel/plugins/plugins.config`).
* **LIM-ENF-12** The Web Apps plugin shall require the `cpanel-plugin-common` package at a version that defines the acknowledgement setting in LIM-ENF-11.
* **LIM-ENF-13** The acknowledgement in LIM-ENF-8 shall apply to the whole server, and the system shall read it each time it checks whether Web Apps is available, not cache it from install time.
* **LIM-ENF-14** While limits can be enforced for at least one resource (LIM-ENF-4), the system shall ignore the acknowledgement; if enforcement is later lost for both, the stored acknowledgement shall apply again without a new prompt.
* **LIM-ENF-15** While Web Apps is unavailable under LIM-ENF-8, the system shall refuse Web Apps API calls and [UIs](#ui) and [MCPs](#mcp) shall hide the feature, and the system shall not stop apps that are already running.
* **LIM-ENF-16** When a change to a deployed app’s CPU weight through the [API](#api) is accepted, the system shall remove every `--cpu-shares` and `-c` entry from the container’s recorded start arguments, including one the user added, write a single `--cpu-shares` entry with the new value, so that a recreate keeps it, and shall apply it to the running container with `podman update --cpu-shares` where CPU limits can be enforced (LIM-ENF-4). If the live update fails, the weight takes effect at the next recreate, and the system shall report that it has not yet taken effect.

**Swap.** `--memory-swap` is set equal to `--memory` so a container cannot use swap beyond its memory cap; otherwise podman allows up to twice the cap in total. It requires kernel swap accounting, on cgroup v1 and on v2; where it is unavailable, swap cannot be limited, and Memory limits are still enforced for memory itself.

**Hard limits** are absolute amounts, so summing them against a user’s total means exactly what it says, on either cgroup version.

**Soft memory** protection is hierarchical on cgroup v2: a container’s `memory.low` is effective only up to the protection set on its parent cgroups. Enforcement therefore sets a root-side floor (`MemoryLow`) on the account’s user slice, matching the user’s soft total. That floor reaches the containers below the intermediate cgroups only where the cgroup2 mount has `memory_recursiveprot`, which can be read from `/proc/self/mountinfo`. On cgroup v1, the soft limit protects nothing; the kernel only uses it under system-wide memory pressure, reclaiming first from cgroups furthest over their soft limit.

**Soft CPU** is a ratio, not an amount, on either cgroup version (`--cpu-shares`, `cpu.weight` on v2, `cpu.shares` on v1). Shares only divide contested CPU among siblings in the same parent cgroup, so a rootless container’s weight ranks a user’s apps, and their build container, against each other, and only while they compete for CPU. A stopped app drops out of the ranking. A weight is therefore not a guarantee of any amount of CPU, and it gives no protection from other accounts. Summing shares against a total does not correspond to a quantity of CPU, so a weight has no total, and the user picks one of five fixed values instead of a raw share number (LIM-RES-35, LIM-RES-37). Like hard CPU, a weight applies only where the cpu controller is delegated (LIM-ENF-4). A user who needs a finer value than the five names can set `--cpu-shares` in their own `ea-podman.json`. It is passed unchanged, applies at the next recreate, and is reported as `custom` (LIM-RES-40, LIM-RES-41). This is an advanced option and is documented as such.

**cgroup v1 hosts.** Rootless podman cannot apply resource limits on cgroup v1; it ignores them with a warning. Web Apps containers are rootless, so on v1 hosts none of these limits are enforced, and the API must not report them as applied. The v1 column applies only to rootful containers. Web Apps is still allowed on such hosts, but only after the administrator explicitly acknowledges that limits are not enforced (LIM-ENF-8). The administrator can get enforcement by moving the host to cgroup v2, either by a distro that defaults to it or, on EL8, by a kernel boot parameter and a reboot. Cgroup v2 alone is not enough: the controller for each resource (memory for Memory, cpu for CPU) must also be delegated to the user’s service manager (`user@<uid>.service`). The cpu controller in particular is often not delegated, so a v2 host can enforce Memory limits and not CPU limits.

**CloudLinux.** On CloudLinux, account-wide limits can come from LVE instead. That is not a Web Apps limit, it does not enforce per-app limits, and it is deliberately left out of the warning in LIM-ENF-7. It should instead be covered in the public-facing documentation page that the warning links to (LIM-ENF-10).

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

* **LIM-REC-1** Each [Adapter](#adapters) shall specify a recommended minimum CPU and Memory for its [App Type](#app-types), and shall not specify a CPU weight.
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

### Acceptance criteria

Each criterion cites the requirements it verifies. Values match the [Examples](#examples).

1. **Total cascade** (LIM-RES-4, LIM-RES-5)
   * GIVEN Default memory is 2048 MiB, Global is 4096 MiB, and the user has no User value
   * WHEN the user’s effective memory total is resolved
   * THEN it is 4096 MiB.
   * GIVEN the same, and the user’s package sets 512 MiB
   * WHEN it is resolved
   * THEN it is 512 MiB, lower than both broader levels.
1. **Deploy fits** (LIM-RES-10, LIM-RES-12)
   * GIVEN a user with a 2048 MiB hard memory total and 1536 MiB already allocated
   * WHEN they deploy an app with 512 MiB
   * THEN the deploy is accepted and 2048 MiB is counted as used immediately, before the build finishes.
1. **Deploy does not fit** (LIM-RES-10, LIM-RES-24)
   * GIVEN the same user
   * WHEN they deploy an app with 768 MiB
   * THEN the deploy is refused, nothing is allocated, and the error identifier names the hard memory limit.
1. **Concurrent deploys** (LIM-RES-12, LIM-RES-34, LIM-CNT-2)
   * GIVEN 512 MiB remaining and two simultaneous deploy requests of 512 MiB each
   * WHEN both are processed
   * THEN the second request waits on the user’s registry lock until the first’s reservation is saved, re-checks against the reduced remainder of 0 MiB, and is refused with `limit_exceeded` and `error_limit` of `memory_hard`; exactly one is accepted.
   * GIVEN one app slot remaining and two simultaneous requests from the same user
   * WHEN both are processed
   * THEN the second request waits on the lock the same way, finds no slot left, and is refused with `limit_exceeded` and `error_limit` of `app_count`; exactly one is accepted, and no request is accepted on a check made before the other’s reservation was saved.
1. **Release on failure** (LIM-RES-13, LIM-RES-14, LIM-CNT-3, LIM-CNT-4)
   * GIVEN an accepted deploy that then fails or is cancelled, or a deployed app that is deleted
   * WHEN that happens
   * THEN its memory, CPU and app slot are released.
1. **Change an allocation** (LIM-RES-11)
   * GIVEN an app with 512 MiB and 512 MiB remaining in the total
   * WHEN the user raises it to 1024 MiB
   * THEN the change is accepted, because the app’s own 512 MiB counts as available; raising it to 1280 MiB is refused.
1. **Lowered total** (LIM-RES-15, LIM-RES-16, LIM-RES-22, LIM-RES-23)
   * GIVEN usage of 2048 MiB
   * WHEN the user’s total is lowered to 1024 MiB
   * THEN no running app is stopped, the API reports an overage of 1024 MiB, and new deploys are refused until usage is at or under the total.
1. **Invalid values** (LIM-RES-17, LIM-RES-18)
   * GIVEN any limit value of 0 or below, an app with a soft memory limit of 768 MiB and a hard limit of 512 MiB, or a user with a soft memory total of 3072 MiB and a hard total of 2048 MiB
   * WHEN it is submitted
   * THEN it is rejected.
1. **One build at a time** (LIM-RES-32, LIM-RES-33)
   * GIVEN a user whose app A is building and who has room in their totals
   * WHEN they deploy app B
   * THEN the deploy is refused with the error category `build_in_progress`, no allocation or slot is reserved, and A’s build continues.
   * GIVEN A’s build then finishes
   * WHEN they deploy app B again
   * THEN it is accepted.
1. **Soft memory fits** (LIM-RES-3, LIM-RES-10, LIM-RES-24)
   * GIVEN a user with a 1024 MiB soft memory total and 768 MiB of soft memory allocated
   * WHEN they deploy an app with a 256 MiB soft limit that fits their hard total
   * THEN the deploy is accepted.
   * GIVEN the same user
   * WHEN they deploy an app with a 384 MiB soft limit
   * THEN the deploy is refused, and the error identifier names the soft memory limit.
1. **Soft memory enforcement** (LIM-ENF-1, LIM-ENF-3)
   * GIVEN an enforced host and a user with a 1024 MiB soft memory total
   * WHEN an app starts with a 512 MiB hard and 256 MiB soft memory limit
   * THEN podman runs with `--memory=512m --memory-swap=512m --memory-reservation=256m`, and `MemoryLow` on the user’s slice is 1024 MiB.
1. **CPU weight** (LIM-RES-19, LIM-RES-35, LIM-RES-36, LIM-RES-37, LIM-RES-38)
   * GIVEN a user with 0.5 CPU remaining
   * WHEN they deploy an app with 0.5 CPU and `cpu_weight` of `high`
   * THEN the deploy is accepted, the container’s recorded start arguments hold `--cpu-shares=2048`, the API reports `high`, the remaining CPU becomes 0.0, and the weight is not counted anywhere in usage or overage.
   * GIVEN a deploy that gives no `cpu_weight`
   * WHEN it is accepted
   * THEN the start arguments hold `--cpu-shares=1024` and the API reports `normal`.
   * GIVEN a request with `cpu_weight` of `turbo`, or of `custom`
   * WHEN it is submitted
   * THEN it is rejected and nothing is allocated.
1. **Granular CPU weight in ea-podman.json** (LIM-RES-40, LIM-RES-41, LIM-ENF-5, LIM-ENF-16)
   * GIVEN a user who has set `--cpu-shares=3000` in their app’s `ea-podman.json`
   * WHEN the app is redeployed
   * THEN the container starts with `--cpu-shares=3000`, the value is not rewritten, and the API reports `cpu_weight` of `custom` and `cpu_shares` of 3000.
   * GIVEN the same app
   * WHEN the user then changes its weight to `low` through the API
   * THEN the start arguments hold a single `--cpu-shares=512`, the 3000 is gone, and the API reports `low`.
   * GIVEN an account-controlled config containing `--cpu-shares=3000`
   * WHEN ea-podman reads it
   * THEN it is accepted.
1. **CPU weight on a running app** (LIM-ENF-16)
   * GIVEN an enforced host and a running app at `normal`
   * WHEN the user changes it to `very_high`
   * THEN the recorded start arguments hold `--cpu-shares=4096`, and the running container is updated to 4096 shares.
   * GIVEN the live update fails
   * WHEN the change is accepted
   * THEN the recorded value is still saved, the response reports that the weight has not yet taken effect, and it applies at the next recreate.
1. **Build container weight** (LIM-RES-39)
   * GIVEN an enforced host
   * WHEN an app is built
   * THEN the build container runs with `--cpu-shares=512`, whatever weight the app has.
1. **App count** (LIM-CNT-1, LIM-CNT-6, LIM-CNT-7)
   * GIVEN a user with a maximum of 4 apps and 4 deployed
   * WHEN they deploy another
   * THEN it is refused with the app count error.
   * GIVEN a user under their maximum and an exhausted port pool
   * WHEN they deploy
   * THEN it fails with a port pool error.
1. **Enforced host** (LIM-ENF-1, LIM-ENF-2, LIM-ENF-4, LIM-ENF-9)
   * GIVEN cgroup v2 with the cpu and memory controllers delegated to the user’s service manager
   * WHEN an app container starts with 512 MiB and 0.5 CPU
   * THEN podman runs with `--memory=512m --memory-swap=512m --cpus=0.5 --cpu-shares=1024` (no weight was given, so `normal`), and the API reports hard memory, soft memory and CPU as enforced.
1. **No swap accounting** (LIM-ENF-2)
   * GIVEN cgroup v2 with the memory controller delegated and no `memory.swap.max` for the user
   * WHEN an app container starts with 512 MiB
   * THEN podman runs with `--memory=512m` and no `--memory-swap`, the container starts, a note records that swap is not capped, and the API reports hard memory as enforced.
1. **No recursive protection** (LIM-ENF-3, LIM-ENF-4, LIM-ENF-4a, LIM-ENF-7)
   * GIVEN cgroup v2 with the memory controller delegated and a cgroup2 mount without `memory_recursiveprot`
   * WHEN an app container starts with a 512 MiB hard and 256 MiB soft memory limit
   * THEN podman runs with `--memory=512m --memory-swap=512m` and no `--memory-reservation`, `MemoryLow` is not set, the API reports hard memory as enforced and soft memory as not enforced, and the administrator is warned about soft memory.
1. **Partly enforced host** (LIM-ENF-4, LIM-ENF-4a, LIM-ENF-7, LIM-ENF-8, LIM-ENF-9)
   * GIVEN cgroup v2 with the memory controller delegated and the cpu controller not
   * WHEN an app container starts with 512 MiB and 0.5 CPU
   * THEN podman runs with `--memory=512m --memory-swap=512m` and no `--cpus` or `--cpu-shares`, Web Apps is available without acknowledgement, the API reports hard and soft memory as enforced and CPU as not enforced, and the administrator is warned about CPU.
1. **Unenforced host** (LIM-ENF-6, LIM-ENF-8, LIM-ENF-9)
   * GIVEN a cgroup v1 host and no administrator acknowledgement
   * WHEN anyone asks whether Web Apps is available
   * THEN it is unavailable and the API reports hard memory, soft memory and CPU as not enforced.
   * GIVEN the administrator then acknowledges
   * WHEN availability is asked again
   * THEN Web Apps is available, totals and counts are still checked, and the API still reports hard memory, soft memory and CPU as not enforced.
1. **Acknowledgement over time** (LIM-ENF-13, LIM-ENF-14, LIM-ENF-15)
   * GIVEN a cgroup v1 host where the administrator has acknowledged, and two apps running
   * WHEN the host moves to cgroup v2 with the cpu and memory controllers delegated
   * THEN the API reports hard memory, soft memory and CPU as enforced and the acknowledgement is ignored.
   * GIVEN the host later loses the memory and cpu delegation
   * WHEN availability is checked
   * THEN Web Apps is available without a new prompt and the API reports hard memory, soft memory and CPU as not enforced.
   * GIVEN the administrator clears the acknowledgement on an unenforced host
   * WHEN availability is checked
   * THEN API calls are refused, and the two running apps keep running.
1. **Account-controlled flags** (LIM-ENF-5)
   * GIVEN an account-controlled config containing `--memory=8g`
   * WHEN ea-podman reads it
   * THEN it is rejected.
1. **Recommendations** (LIM-REC-2, LIM-REC-3)
   * GIVEN an adapter recommending 256 MiB and an app set to 128 MiB that otherwise fits
   * WHEN it is deployed
   * THEN the user is warned and the deploy is accepted.
1. **Upgrade backfill** (LIM-RES-25, LIM-RES-26, LIM-RES-27)
   * GIVEN an existing app with no allocation, using 512 MiB
   * WHEN Web Apps is upgraded
   * THEN its Memory is set to 512 MiB, its CPU to its adapter’s default and `--cpu-shares=1024` (`normal`) in its container’s start arguments, during the upgrade itself.
1. **Upgrade into overage** (LIM-RES-16, LIM-RES-28, LIM-RES-29)
   * GIVEN a user whose package allows 10 apps, all deployed at 512 MiB, and the Default memory total of 2048 MiB
   * WHEN Web Apps is upgraded
   * THEN all 10 apps keep running, the API reports a memory overage of 3072 MiB, a new deploy is refused, and the upgrade log counts this user.

### Examples

Concrete values for a user whose effective totals are **2048 MiB hard memory**, **1024 MiB soft memory** and **2.0 CPU** (set on the package), with two apps deployed: app A at 512 MiB hard, 256 MiB soft and 0.5 CPU, app B at 1024 MiB hard, 512 MiB soft and 1.0 CPU. Usage is 1536 MiB hard, 768 MiB soft and 1.5 CPU; remaining is 512 MiB hard, 256 MiB soft and 0.5 CPU. Error identifiers are those in LIM-RES-30.

**Happy path: deploy fits** (LIM-RES-10, LIM-RES-12)

```
input:  deploy { type: "nodejs", memory_mb: 512, soft_memory_mb: 256, cpu: 0.5, cpu_weight: "high" }
output: { status: 1, data: { app: "C", memory_mb: 512, soft_memory_mb: 256, cpu: 0.5, cpu_weight: "high" } }
after:  usage 2048 / 2048 MiB hard, 1024 / 1024 MiB soft, 2.0 / 2.0 CPU, overage { memory_mb: 0, cpu: 0 }
        (the weight is not counted; podman runs with --cpu-shares=2048)
```

**Error case: deploy does not fit** (LIM-RES-10, LIM-RES-24)

```
input:  deploy { type: "nodejs", memory_mb: 768, soft_memory_mb: 256, cpu: 0.5 }
output: { status: 0, error_category: "limit_exceeded", error_limit: "memory_hard",
          detail: "Requested 768 MiB, 512 MiB remaining of 2048 MiB." }
after:  unchanged, usage 1536 MiB, no allocation reserved
```

**Error case: soft memory does not fit** (LIM-RES-3, LIM-RES-24)

```
input:  deploy { type: "nodejs", memory_mb: 512, soft_memory_mb: 384, cpu: 0.5 }
output: { status: 0, error_category: "limit_exceeded", error_limit: "memory_soft",
          detail: "Requested 384 MiB soft, 256 MiB remaining of 1024 MiB." }
after:  unchanged, usage 768 MiB soft, no allocation reserved
```

**Happy path: enforced host** (LIM-ENF-4, LIM-ENF-9)

```
input:  get_available   (cgroup v2, cpu and memory controllers delegated)
output: { limits_enforced: { memory_hard: true, memory_soft: true, cpu: true },
          memory_mb: { total: 2048, usage: 1536, overage: 0 },
          cpu:       { total: 2.0,  usage: 1.5,  overage: 0 } }
```

**Error case: unenforced host, not acknowledged** (LIM-ENF-8, LIM-ENF-9)

```
input:  deploy { type: "nodejs", memory_mb: 512, cpu: 0.5 }   (cgroup v1, no acknowledgement)
output: { status: 0, error_category: "webapps_unavailable_limits_not_enforced",
          limits_enforced: { memory_hard: false, memory_soft: false, cpu: false } }
after:  nothing deployed; the WHM warning (LIM-ENF-7) links to the documentation page (LIM-ENF-10)
```

### Constraints

* A resource’s limits are enforced only on cgroup v2 with its controller (memory or cpu) delegated to the user’s service manager, and soft memory also needs `memory_recursiveprot` on the cgroup2 mount (LIM-ENF-4). Web Apps containers are rootless, and rootless podman ignores limits on cgroup v1.
* Usage is the sum of configured per-app settings, never measured consumption (LIM-RES-9).
* Every app has a CPU setting, a CPU weight and a Memory setting. There is no fallback for one without (LIM-RES-8).
* CPU has a hard limit and a weight. Memory has hard and soft. The API accepts one of five fixed weights, a user may set any other value in their own `ea-podman.json`, and a weight is not counted against a total and ranks only a user’s own apps and their build container (LIM-RES-19, LIM-RES-35, LIM-RES-37, LIM-RES-41). Every limit value is positive and a soft memory limit never exceeds its hard limit (LIM-RES-17, LIM-RES-18).
* Users cannot change their totals or app count maximum (LIM-1). Build container caps are fixed (LIM-RES-21), and a user runs at most one build at a time (LIM-RES-32).
* The [API](#api) has no [App Type](#app-types) specific logic, so limits cannot differ by App Type (LIM-3).
* App count exists only because the port pool is shared by every account on the server (LIM-CNT-7).
* Errors are machine-readable with stable identifiers (see [Errors](#errors) and LIM-RES-24).
* The acknowledgement setting lives in `cpanel-plugin-common`, so the Web Apps plugin must require a version that defines it (LIM-ENF-11, LIM-ENF-12).
* Overage is never stored, only derived (LIM-RES-22).
* Limit checks and reservations run under the user’s registry lock (LIM-RES-34), which stage holds for up to 300 seconds, so a user’s own concurrent requests can wait that long.
* Limits bind only what Web Apps does on a user’s behalf, per the Note at the top of this section.

### Out of scope

* Pids limiting.
* General account disk space and database limits (owned outside this plugin).
* WHM controls for setting limits (CPANEL-56151). The WHM warning (LIM-ENF-7) and the acknowledgement Tweak Setting (LIM-ENF-11) are not such controls: they set no limit value and are not a WHM page for managing limits, so they are in scope here and are not the “WHM UI” item under [Out of scope for July 2026 release](#out-of-scope-for-july-2026-release).
* A soft CPU total, a way to set a granular share value through the API, or administrator-set share values. The API accepts one of five fixed weights and a weight is not counted (LIM-RES-19, LIM-RES-35, LIM-RES-37). A user can set any value in their own `ea-podman.json` (LIM-RES-41).
* Protecting one account’s CPU from another’s. A weight only ranks a user’s own apps.
* Limits on containers a user runs directly from the shell, outside Web Apps (see the Note above).
* CloudLinux LVE account-wide limits. It is not a Web Apps limit; it is only mentioned in the public documentation page (LIM-ENF-10).
* Rootful containers.
* Stopping or throttling running apps when a total is lowered (LIM-RES-15).
* Limits that vary by [App Type](#app-types) (LIM-3).

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
