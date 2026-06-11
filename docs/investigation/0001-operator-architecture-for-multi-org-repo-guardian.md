---
id: INV-0001
title: "Operator architecture for multi-org repo-guardian"
status: In Progress
author: Donald Gifford
created: 2026-06-11
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0001: Operator architecture for multi-org repo-guardian

**Status:** In Progress
**Author:** Donald Gifford
**Date:** 2026-06-11

<!--toc:start-->
- [Question](#question)
- [Hypothesis](#hypothesis)
- [Context](#context)
  - [Reference systems](#reference-systems)
  - [Goal](#goal)
- [Approach](#approach)
- [Environment](#environment)
- [Findings](#findings)
  - [F1 — repo-guardian today: the service we are porting](#f1--repo-guardian-today-the-service-we-are-porting)
  - [F2 — Authentication: current model vs. desired per-org Apps](#f2--authentication-current-model-vs-desired-per-org-apps)
  - [F3 — Guardian domain logic and configuration](#f3--guardian-domain-logic-and-configuration)
  - [F4 — renovate-operator conventions worth mirroring](#f4--renovate-operator-conventions-worth-mirroring)
  - [F5 — The webhook-receiver gap](#f5--the-webhook-receiver-gap)
- [Proposed architecture](#proposed-architecture)
  - [Component overview](#component-overview)
  - [Multi-org model: one GitHub App per org](#multi-org-model-one-github-app-per-org)
  - [Per-org webhook routing](#per-org-webhook-routing)
  - [Event-to-reconcile flow](#event-to-reconcile-flow)
  - [Engine execution strategy (central decision)](#engine-execution-strategy-central-decision)
- [Proposed Kubernetes API (initial draft)](#proposed-kubernetes-api-initial-draft)
  - [The CRD triad](#the-crd-triad)
  - [GuardianOrg (cluster-scoped)](#guardianorg-cluster-scoped)
  - [GuardianPolicy (namespaced)](#guardianpolicy-namespaced)
  - [GuardianRun (namespaced, ephemeral)](#guardianrun-namespaced-ephemeral)
  - [Shared types](#shared-types)
  - [Sample custom resources](#sample-custom-resources)
- [Open questions and decisions](#open-questions-and-decisions)
- [Conclusion](#conclusion)
- [Recommendation: document roadmap](#recommendation-document-roadmap)
- [References](#references)
<!--toc:end-->

## Question

Can we re-platform the existing **repo-guardian** GitHub App as a Kubebuilder
operator that:

1. Manages **multiple GitHub organizations**, where **each org authenticates
   with its own GitHub App** (App ID + installation ID + private key)?
2. Exposes a **per-org inbound webhook endpoint** — e.g.
   `https://my-repo-guardian-operator.dev/my-main-org` — that validates and
   routes GitHub events to the guardian logic for *that org only*?

And if so, what is the most idiomatic shape for the CRDs, controllers, and the
webhook receiver — reusing the conventions already proven in
**renovate-operator**?

This is an **exploratory / scoping** investigation. Its purpose is not to ship
code but to produce a shared mental model and a concrete starting point so we
can split the work into focused RFC / ADR / DESIGN / IMPL docs (see
[Recommendation](#recommendation-document-roadmap)).

## Hypothesis

Yes, it is feasible, and the bulk of the structure can be lifted from
renovate-operator. We expect:

- A **three-CRD split by lifecycle** (identity+credentials → policy → execution)
  maps cleanly onto repo-guardian's domain, mirroring
  `RenovatePlatform → RenovateScan → RenovateRun`.
- The **multi-org / per-org-App** requirement is a *natural extension* of
  renovate-operator's "one platform CR per installation" pattern — we make the
  credential CR hold a **full per-org App** rather than sharing one App across
  installations.
- The **per-org webhook endpoint** is the one genuinely net-new component:
  *neither* reference repo has an inbound HTTP webhook receiver, so we must
  design it ourselves (HMAC verification per org, path-based routing keyed on
  the org slug).

The main open decision we expect to surface is **how the guardian engine
actually runs** (port the engine into the controller vs. run the existing
binary as a Job vs. have the operator deploy the existing service per org) —
see [Engine execution strategy](#engine-execution-strategy-central-decision).

## Context

This repo (`repo-guardian-operator`) is a freshly-scaffolded Kubebuilder v4
project (`domain: repo-guardian.dev`) with no APIs created yet. We want to
turn our existing standalone service into a cluster-native operator.

### Reference systems

| System | Repo | Role in this investigation |
|--------|------|----------------------------|
| **repo-guardian** | `github.com/donaldgifford/repo-guardian` | The service we are porting. Source of all domain logic, the auth model, and the existing single-endpoint webhook handler. |
| **renovate-operator** | `github.com/donaldgifford/renovate-operator` | A sibling Kubebuilder operator with the same author/conventions. The template for project layout, CRD design, credential handling, reconcile structure, and testing. |

### Goal

Support **N GitHub orgs** in one operator install. Each org:

- brings its **own GitHub App** credentials (so blast radius, rate limits, and
  permissions are isolated per org);
- gets its **own webhook URL** (`https://<host>/<org>`) so GitHub delivers that
  org's events to a path the operator can attribute and HMAC-verify with that
  org's secret;
- is governed by one or more **policies** (the guardian rules: required files,
  repo settings, branch protection, etc.).

**Triggered by:** New project initiative — porting `repo-guardian` to an
operator. No parent doc yet; this INV is the root of the doc tree.

## Approach

1. Clone and read **repo-guardian** end-to-end: entrypoint, auth (`internal/github`),
   webhook handler (`internal/webhook`), domain engine (`internal/checker`,
   `internal/policy`, `internal/reconciler`), config, and persistence.
2. Clone and read **renovate-operator** end-to-end: `PROJECT`, all `*_types.go`,
   controllers, credential handling, RBAC, watches, and testing patterns.
3. Identify what maps cleanly, what must be adapted for per-org Apps, and what
   is net-new (the webhook receiver).
4. Draft an initial CRD triad + a webhook-routing design concrete enough to
   review and to seed downstream RFC/ADR/DESIGN docs.

## Environment

| Component | Version / Value |
|-----------|----------------|
| Operator scaffold | Kubebuilder `4.14.0`, layout `go.kubebuilder.io/v4` (+ helm/v2-alpha, autoupdate, grafana plugins) |
| Operator domain | `repo-guardian.dev` |
| Go / controller-runtime | go `1.25.7`, controller-runtime `v0.23.3`, k8s libs `v0.35.0` |
| repo-guardian deps | `go-github/v68`, `bradleyfalzon/ghinstallation/v2`, `hashicorp/hcl/v2`, `pgx/v5`, `go-redis/v9` |
| renovate-operator deps | `go-github/v62`, `bradleyfalzon/ghinstallation/v2`, `robfig/cron/v3`, controller-runtime `v0.23.1` |
| repo-guardian layout | Standalone Go service (dual HTTP servers), **not** an operator today |
| renovate-operator layout | Single-group Kubebuilder operator, 3 CRDs, **cron-driven (no webhooks)** |

## Findings

### F1 — repo-guardian today: the service we are porting

repo-guardian is a **GitHub App that continuously reconciles repos against a
declarative policy** and opens PRs (or directly remediates) on drift. Today it
is a single Go binary running **two HTTP servers** (webhook + metrics) with a
work queue and worker pool — *not* a Kubernetes operator.

Core capabilities to preserve:

- **Required-file enforcement** — detects repos missing required files
  (CODEOWNERS, Dependabot, Renovate config, `catalog-info.yaml`, …) and opens a
  single PR on a deterministic branch (`repo-guardian/add-missing-files`). Three
  check modes: `exists`, `contains` (regex / YAML-path assertions), `exact`
  (template match, YAML-semantic for `.yml`/`.yaml`).
- **Repository setting enforcement** (optionally auto-remediated):
  `vulnerability_alerts_enabled`, `default_branch`, `has_issues`, `has_wiki`,
  `delete_branch_on_merge`, `allow_*_merge`.
- **Branch protection** via the GitHub **rulesets** API (named
  `repo-guardian-<rule>`): required PRs/approvals, status checks, linear history,
  enforce-admins, etc.
- **Post-check reconcilers**: `custom_properties` (Backstage `catalog-info.yaml`
  → repo custom properties), `label_sync`, `branch_protection`, `workflow_sync`.
- **Lifecycle/drift management**: PR-body refresh, orphan-file cleanup,
  auto-close of its own PR when rules become satisfied out-of-band, sticky
  reconcile-log comments, stale-repo re-sweeps.

Internal flow today:
`webhook OR scheduler OR push → work queue → worker pool → checker engine → GitHub API → reconcilers`.

The clean Go interfaces (`github.Client`, `queue.Queue`, `store.Store`,
`scheduler.Scheduler`, `reconciler.Reconciler`) are excellent seams for an
operator port — several of them (queue, scheduler, store) get **replaced** by
controller-runtime primitives (workqueue, requeue, CRD status/`observedGeneration`).

### F2 — Authentication: current model vs. desired per-org Apps

**Today (repo-guardian):** *one* GitHub App per process. The binary holds a
single App ID + private key + one webhook secret (env vars
`GITHUB_APP_ID`, `GITHUB_PRIVATE_KEY[_PATH]`, `GITHUB_WEBHOOK_SECRET`). It
services many orgs by treating each as a separate **installation** of that one
App, caching a client per installation ID:

```go
type GitHubClient struct {
    appTransport   *ghinstallation.AppsTransport
    appClient      *gh.Client
    mu             sync.Mutex
    installClients map[int64]*gh.Client // keyed by installation ID
    installationID int64                // non-zero when scoped to an installation
    scopedGHClient *gh.Client
}
```

Installation IDs are discovered dynamically from webhook payloads
(`e.GetInstallation().GetID()`) and `ListInstallations`. **One App, many
installations, one shared webhook secret.**

**Desired (operator):** *one GitHub App per org*. This is a deliberate change —
each org carries its own App ID + installation ID + private key **and** its own
webhook secret, so rate limits, permissions, and blast radius are isolated. This
is *more* isolation than either reference provides today, but it is a small
delta on renovate-operator's model:

> renovate-operator already declares **one `RenovatePlatform` per installation**
> (its doc comment: *"declare one RenovatePlatform per installation rather than
> overloading a single resource"*). It stores only **pointers** in the CRD
> (App ID, installation ID, and a `SecretKeyReference` to the PEM), never key
> material, and keeps Secrets in the operator's namespace.

We adopt that pointer convention verbatim and extend the per-org CR to also hold
a **`webhookSecretRef`** — which renovate-operator has no need for.

renovate-operator's credential type, for reference (we will mirror its shape):

```go
type GitHubAppAuth struct {
    AppID          int64              `json:"appID"`          // +Minimum=1
    InstallationID int64              `json:"installationID"` // +Minimum=1
    PrivateKeyRef  SecretKeyReference `json:"privateKeyRef"`  // key default "private-key.pem"
}
```

### F3 — Guardian domain logic and configuration

repo-guardian's policy is an **HCL document** (with a built-in default policy
when none is supplied). The top-level shape:

```go
type PolicyConfig struct {
    Guardian              GuardianConfig
    IgnoreList            IgnoreConfig
    Scope                 *ScopeConfig                 // multi-org "strict mode"
    Defaults              *DefaultsConfig
    FileRules             []FileRuleConfig             // rule "file" "<name>" {}
    SettingRules          []SettingRuleConfig          // rule "setting" "<name>" {}
    BranchProtectionRules []BranchProtectionRuleConfig // rule "branch_protection" "<name>" {}
}
```

Notable for CRD design:

- It already has a **multi-org `scope { orgs = [...] }`** concept (strict mode:
  once a top-level scope exists, every rule must declare its own scope). That
  intent maps onto **binding a `GuardianPolicy` to a `GuardianOrg`** in the
  operator world.
- A rule carries `enabled`, `check`, `paths`, `template`, `assertions`, a `pr {}`
  template block, optional `reconcile {}` sub-blocks, and per-rule
  `ignore`/`scope`. There is a `defaults { pr {} } → rule { pr {} } → reconcile { pr {} }`
  inheritance cascade.
- The **only persisted state** is per-repo reconcile bookkeeping
  (`RepoState{ InstallationID, Owner, Repo, LastCheckedAt, LastCheckStatus,
  LastError, PolicyVersion }`) — exactly the kind of thing a controller tracks
  natively in CRD `status` + `observedGeneration`, letting us drop Postgres/Valkey
  for the common case.

**Design tension:** the policy schema is large. We can either (a) model it as
typed CRD fields, (b) keep authoring it as HCL/JSON and reference it from a
`ConfigMap`, or (c) inline it via `runtime.RawExtension`. The initial draft
below proposes a **typed core + a `RawExtension` escape hatch**; the final call
belongs in an RFC.

### F4 — renovate-operator conventions worth mirroring

The patterns we will copy wholesale:

1. **Three-CRD split by lifecycle/owner**: long-lived **cluster-scoped identity
   + credentials**; long-lived **namespaced config**; **ephemeral
   controller-created execution**. (`RenovatePlatform / RenovateScan / RenovateRun`.)
2. **Credentials as Secret pointers**, Secrets live in the operator namespace,
   CRDs store only references (`SecretKeyReference` with default keys). One CR
   per org/installation.
3. **Snapshot parent specs into the ephemeral execution CR** so mid-flight edits
   can't mutate an in-progress run.
4. **Thin reconcilers + pure builder packages** (renovate has `jobspec`,
   `sharding`, `credentials`, `conditions`) returning objects to apply —
   unit-testable without envtest.
5. **Centralized `conditions` package**, `metav1.Condition` everywhere,
   CamelCase reasons, `observedGeneration` every reconcile, status-conflict →
   short requeue.
6. **Inner `reconcile()` mutates status; outer `Reconcile()` does the single
   `Status().Update`.**
7. **Owner-reference cascade GC instead of finalizers**; history-limit GC +
   TTL for ephemeral children. (We will likely *add* finalizers where we touch
   GitHub-side state — see open questions.)
8. **Map-func watches** to wake dependents on credential rotation / readiness
   flips, gated by namespace predicates (e.g. `secretsForPlatform`).
9. **Injectable seams** (`Clock`, client factory function types, client options)
   for testability; **CEL `XValidation`** for cross-field invariants like
   "exactly one of githubApp/token".
10. **Phase state machine + idempotent steps** for the execution controller,
    with transient-vs-permanent error classification driving requeue vs.
    terminal-fail.

renovate-operator's `RenovatePlatform` (cluster-scoped, status conditions, CEL
validations, printcolumns) is almost exactly the skeleton our `GuardianOrg`
needs.

### F5 — The webhook-receiver gap

**This is the one place with no precedent to copy.**

- **renovate-operator** is entirely **cron/poll-driven**. It has *no* webhook
  receiver, *no* `Service` for app traffic, *no* `Ingress`, and *no*
  `internal/webhook/` handlers. Its only HTTP listeners are metrics, health
  probes, and pprof. The scaffolded `webhook.Server` in `cmd/main.go` is unused.
- **repo-guardian** *does* receive webhooks, but on a **single** endpoint
  (`POST /webhooks/github`) with **one shared** secret and **no per-org
  routing** — the org is inferred later from the installation ID embedded in the
  payload. It validates via `gh.ValidatePayload` (HMAC `X-Hub-Signature-256`),
  parses with `gh.ParseWebHook`, and handles `RepositoryEvent(created)`,
  `InstallationRepositoriesEvent(added)`, `InstallationEvent(created)`, and
  `PushEvent` (default branch, watched paths). It also has an optional GitHub-IP
  allowlist middleware.

So for the operator we must **design a new per-org webhook receiver**:

- A path like `/<org>` selects a `GuardianOrg` (by `spec.org`).
- HMAC is verified against **that org's** `webhookSecretRef` (not a global
  secret).
- Verified events are turned into reconciliation work (see
  [Event-to-reconcile flow](#event-to-reconcile-flow)).
- This needs a `Service` + `Ingress` (or Gateway `HTTPRoute`), which neither
  reference repo provides.

We can lift repo-guardian's **event-parsing and HMAC logic** directly; the
**routing + per-org secret lookup + K8s plumbing** is net-new.

## Proposed architecture

### Component overview

```mermaid
flowchart TD
    subgraph GitHub
      A1[App: my-main-org] -->|webhook /my-main-org| WR
      A2[App: other-org]   -->|webhook /other-org|   WR
    end

    subgraph Cluster [repo-guardian-operator]
      ING[Ingress / HTTPRoute<br/>host: my-repo-guardian-operator.dev] --> WR
      WR[Webhook Receiver<br/>per-org HMAC + routing] -->|create| RUN[(GuardianRun CRs)]
      MGR[Controller Manager]
      MGR --- ORGCTL[GuardianOrg controller<br/>validate creds + publish URL]
      MGR --- POLCTL[GuardianPolicy controller<br/>schedule sweeps + bind org]
      MGR --- RUNCTL[GuardianRun controller<br/>execute guardian engine]
      POLCTL -->|scheduled sweep: create| RUN
      RUNCTL -->|App token for org| GH[GitHub API]
      ORGCTL -. reads .-> SEC[(Secrets:<br/>PEM + webhook secret)]
      RUNCTL -. reads .-> SEC
    end
```

Three controllers + one webhook receiver. The receiver and the manager can ship
in the **same binary** (an extra HTTP listener alongside metrics, like
renovate's metrics server) or as a **separate Deployment** — see
[open questions](#open-questions-and-decisions).

### Multi-org model: one GitHub App per org

Each org is a **cluster-scoped `GuardianOrg`** holding its own App credentials
and webhook secret (as Secret pointers). This generalizes renovate-operator's
"one platform per installation" to "one App per org," and is the unit the
webhook receiver routes to.

- Secrets (PEM + webhook secret) live in the **operator namespace**; the CR
  stores only references.
- The `GuardianOrg` controller **validates** credentials (PEM parses, Secret
  exists) and publishes the resolved **webhook URL** into status — it does *not*
  mint tokens (token minting happens lazily in the run controller, as renovate
  does).

### Per-org webhook routing

We recommend **path-based routing on a single host** to match the stated goal
(`https://<host>/<org>`):

- One `Ingress`/`HTTPRoute` for the receiver `Service`; the receiver does
  internal dispatch on the first path segment → `GuardianOrg.spec.org`.
- HMAC verified with that org's `webhookSecretRef`; unknown org or bad signature
  → `404`/`401`.
- The receiver maintains an in-memory index of `org → {installationID,
  webhookSecret}` built from a **watch** on `GuardianOrg` (no per-request API
  calls).

Alternative: **host-based routing** (`my-main-org.<host>`) with a per-org
`Ingress` reconciled by the `GuardianOrg` controller (owner-referenced) — more
moving parts, useful if orgs need TLS/host isolation. Defer to an ADR.

### Event-to-reconcile flow

```
GitHub event ──▶ Ingress ──▶ Receiver(/<org>)
   ├─ resolve GuardianOrg by spec.org           (in-memory index)
   ├─ verify HMAC with org webhook secret
   ├─ parse event (repository.created, installation_repositories.added,
   │              installation.created, push@default+watched-path)
   └─ create GuardianRun CR(s)  ──▶ GuardianRun controller
                                      ├─ snapshot policy
                                      ├─ mint App token for org
                                      ├─ run guardian engine for the repo
                                      └─ status: PRs opened / drift / errors
```

A **`GuardianPolicy` schedule** drives periodic full sweeps (list repos for the
org → create `GuardianRun`s), exactly like renovate's `Scan → Run`. So
`GuardianRun`s have two sources: webhook events and scheduled sweeps.

### Engine execution strategy (central decision)

repo-guardian's reconciliation is **in-process Go**, not an external container
(unlike renovate, which runs the `renovate` CLI in a Job). So "how a run
executes" is the biggest fork in the road and the main thing the first RFC must
settle:

| | **A. Native engine (library)** | **B. Job runner** | **C. Operator-as-deployer** |
|---|---|---|---|
| Idea | Extract `checker`+`policy`+`github` into a library; `GuardianRun` controller calls it in-process | Add a "check one repo" subcommand to the existing binary; spawn a Job per run (mirrors renovate exactly) | Operator deploys the *existing* repo-guardian service per org (Deployment+Service+Ingress+Secrets); webhooks hit the app directly; **no `GuardianRun`** |
| Reuse | Reuse engine code as a lib | Reuse the whole binary/container | Reuse the whole app unchanged |
| Operator-native? | Most native (CRD-per-repo observability, controller workqueue replaces queue/store) | Medium (lots of pods) | Least native (operator is a packaging/lifecycle layer) |
| Per-repo visibility | High (one CR per run) | High (one Job per run) | Low (internal to the app) |
| Effort | High (port + re-test engine) | Medium | Low (fastest to multi-org + per-org webhooks) |
| Webhook receiver | Built into operator | Built into operator | The deployed app already has it (needs per-org secret wiring) |

**Tentative recommendation:** phase it. **Phase 1 = C** to get multi-org +
per-org webhooks shipping fast on the proven app, with the operator owning
identity, secrets, deployment, and routing. **Evolve toward A** when we want
CRD-level observability/retry of individual repo reconciliations. **B** is the
fallback if engine extraction proves costly. The CRD draft below is written for
the **A/B native model** (since it's the most demanding); under **C**,
`GuardianRun` disappears and `GuardianOrg`/`GuardianPolicy` instead render a
`Deployment` + config. This trade-off deserves its own RFC + ADR.

## Proposed Kubernetes API (initial draft)

> Illustrative only — to anchor review and downstream design. Not generated by
> `kubebuilder create api` yet. Group `repo-guardian.dev`, version `v1alpha1`,
> single-group layout (matching renovate-operator). Kinds use a `Guardian*`
> prefix to mirror renovate's `Renovate*` family.

### The CRD triad

| Kind | Scope | shortNames | Lifecycle | Renovate analog |
|------|-------|-----------|-----------|-----------------|
| `GuardianOrg` | **Cluster** | `gorg` | Long-lived identity + per-org App creds + webhook secret | `RenovatePlatform` |
| `GuardianPolicy` | Namespaced | `gpol` | Long-lived rules + schedule, bound to an org | `RenovateScan` |
| `GuardianRun` | Namespaced | `grun` | Ephemeral, controller-created, one per repo reconciliation | `RenovateRun` |

### GuardianOrg (cluster-scoped)

```go
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Cluster,shortName=gorg
// +kubebuilder:printcolumn:name="Org",type=string,JSONPath=".spec.org"
// +kubebuilder:printcolumn:name="Webhook",type=string,JSONPath=".status.webhookURL"
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=`.status.conditions[?(@.type=="Ready")].status`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=".metadata.creationTimestamp"
type GuardianOrg struct {
    metav1.TypeMeta   `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty"`
    Spec   GuardianOrgSpec   `json:"spec,omitempty"`
    Status GuardianOrgStatus `json:"status,omitempty"`
}

type GuardianOrgSpec struct {
    // Org is the GitHub organization login. Also the webhook path segment:
    // https://<host>/<org>.
    // +kubebuilder:validation:Required
    // +kubebuilder:validation:Pattern=`^[a-zA-Z0-9](?:[a-zA-Z0-9]|-(?=[a-zA-Z0-9])){0,38}$`
    Org string `json:"org"`

    // BaseURL is the GitHub API base URL. Empty for github.com; set for GHES.
    // +optional
    BaseURL string `json:"baseURL,omitempty"`

    // App holds this org's dedicated GitHub App credentials (pointers only).
    // +kubebuilder:validation:Required
    App GitHubAppAuth `json:"app"`

    // Webhook configures this org's inbound receiver endpoint.
    // +optional
    Webhook WebhookConfig `json:"webhook,omitempty"`
}

type GitHubAppAuth struct {
    // +kubebuilder:validation:Minimum=1
    AppID int64 `json:"appID"`
    // +kubebuilder:validation:Minimum=1
    InstallationID int64 `json:"installationID"`
    // PrivateKeyRef → Secret holding the App PEM (default key "private-key.pem").
    // +kubebuilder:validation:Required
    PrivateKeyRef SecretKeyReference `json:"privateKeyRef"`
    // WebhookSecretRef → Secret holding this org's webhook HMAC secret
    // (default key "webhook-secret").
    // +optional
    WebhookSecretRef *SecretKeyReference `json:"webhookSecretRef,omitempty"`
}

type WebhookConfig struct {
    // +kubebuilder:default=true
    Enabled *bool `json:"enabled,omitempty"`
    // Path overrides the URL path segment (defaults to spec.org).
    // +optional
    Path string `json:"path,omitempty"`
}

type GuardianOrgStatus struct {
    // +listType=map
    // +listMapKey=type
    Conditions         []metav1.Condition `json:"conditions,omitempty"` // Ready, WebhookConfigured
    WebhookURL         string             `json:"webhookURL,omitempty"`
    ObservedGeneration int64              `json:"observedGeneration,omitempty"`
}
```

### GuardianPolicy (namespaced)

```go
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=gpol
// +kubebuilder:printcolumn:name="Org",type=string,JSONPath=".spec.orgRef.name"
// +kubebuilder:printcolumn:name="Schedule",type=string,JSONPath=".spec.schedule"
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=`.status.conditions[?(@.type=="Ready")].status`
type GuardianPolicySpec struct {
    // OrgRef selects the GuardianOrg this policy applies to.
    // +kubebuilder:validation:Required
    OrgRef LocalObjectReference `json:"orgRef"`

    // Schedule is an optional cron expression for periodic full sweeps.
    // Webhook events trigger reconciliation regardless of schedule.
    // +optional
    Schedule string `json:"schedule,omitempty"`

    // +optional
    Scope *ScopeSpec `json:"scope,omitempty"`
    // Ignore lists repo globs to exclude (e.g. "*-archived").
    // +optional
    Ignore []string `json:"ignore,omitempty"`

    // +kubebuilder:default=true
    SkipForks *bool `json:"skipForks,omitempty"`
    // +kubebuilder:default=true
    SkipArchived *bool `json:"skipArchived,omitempty"`
    // DryRun makes all actions log-only.
    // +optional
    DryRun bool `json:"dryRun,omitempty"`

    // FileRules enforce presence/content of repo files.
    // +optional
    FileRules []FileRule `json:"fileRules,omitempty"`
    // SettingRules enforce repository settings.
    // +optional
    SettingRules []SettingRule `json:"settingRules,omitempty"`
    // BranchProtectionRules enforce rulesets on branches.
    // +optional
    BranchProtectionRules []BranchProtectionRule `json:"branchProtectionRules,omitempty"`

    // RawPolicy is an escape hatch for the full HCL/JSON policy when typed
    // fields are insufficient.
    // +kubebuilder:pruning:PreserveUnknownFields
    // +optional
    RawPolicy *runtime.RawExtension `json:"rawPolicy,omitempty"`
}

type FileRule struct {
    Name string `json:"name"`
    // +kubebuilder:default=true
    Enabled *bool `json:"enabled,omitempty"`
    // +kubebuilder:validation:Enum=exists;contains;exact
    // +kubebuilder:default=exists
    Check    string   `json:"check,omitempty"`
    Paths    []string `json:"paths"`
    Template string   `json:"template,omitempty"`
    // Assertions apply when Check is "contains".
    // +optional
    Assertions []Assertion `json:"assertions,omitempty"`
}

type SettingRule struct {
    Name string `json:"name"`
    // +kubebuilder:default=true
    Enabled *bool `json:"enabled,omitempty"`
    // e.g. "delete_branch_on_merge", "has_wiki", "default_branch".
    Property string `json:"property"`
    // Expected value (bool or string), opaque JSON.
    // +kubebuilder:pruning:PreserveUnknownFields
    Expected *runtime.RawExtension `json:"expected"`
    // Remediate applies the setting via the API rather than only reporting drift.
    // +optional
    Remediate bool `json:"remediate,omitempty"`
}

type BranchProtectionRule struct {
    Name              string   `json:"name"`
    Branch            string   `json:"branch"`
    RequirePR         bool     `json:"requirePR,omitempty"`
    RequiredApprovals int      `json:"requiredApprovals,omitempty"`
    RequireStatusChecks []string `json:"requireStatusChecks,omitempty"`
    EnforceAdmins     bool     `json:"enforceAdmins,omitempty"`
    RequireLinearHistory bool  `json:"requireLinearHistory,omitempty"`
    Remediate         bool     `json:"remediate,omitempty"`
}

type Assertion struct {
    Pattern    string `json:"pattern,omitempty"`
    NotPattern string `json:"notPattern,omitempty"`
    YAMLPath   string `json:"yamlPath,omitempty"`
    Equals     string `json:"equals,omitempty"`
    Message    string `json:"message,omitempty"`
}

type ScopeSpec struct {
    // Repos limits the policy to matching repo globs (e.g. "service-*").
    Repos []string `json:"repos,omitempty"`
}

type GuardianPolicyStatus struct {
    // +listType=map
    // +listMapKey=type
    Conditions            []metav1.Condition       `json:"conditions,omitempty"` // Ready, Scheduled
    LastSweepTime         *metav1.Time             `json:"lastSweepTime,omitempty"`
    NextSweepTime         *metav1.Time             `json:"nextSweepTime,omitempty"`
    ActiveRuns            []corev1.ObjectReference  `json:"activeRuns,omitempty"`
    ObservedGeneration    int64                    `json:"observedGeneration,omitempty"`
}
```

### GuardianRun (namespaced, ephemeral)

```go
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=grun
// +kubebuilder:printcolumn:name="Repo",type=string,JSONPath=".spec.repo"
// +kubebuilder:printcolumn:name="Trigger",type=string,JSONPath=".spec.trigger"
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=".status.phase"
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=".metadata.creationTimestamp"
type GuardianRunSpec struct {
    OrgRef    LocalObjectReference `json:"orgRef"`
    PolicyRef LocalObjectReference `json:"policyRef"`
    // Repo is "owner/name".
    Repo string `json:"repo"`
    // +kubebuilder:validation:Enum=webhook;push;schedule;manual
    Trigger string `json:"trigger"`
    // PolicySnapshot freezes the policy spec at enqueue time so edits mid-run
    // don't change behavior.
    PolicySnapshot GuardianPolicySpec `json:"policySnapshot"`
}

type GuardianRunStatus struct {
    // +listType=map
    // +listMapKey=type
    Conditions     []metav1.Condition `json:"conditions,omitempty"` // Started, Succeeded, Failed
    // +kubebuilder:validation:Enum=Pending;Running;Succeeded;Failed
    Phase          string       `json:"phase,omitempty"`
    StartTime      *metav1.Time `json:"startTime,omitempty"`
    CompletionTime *metav1.Time `json:"completionTime,omitempty"`
    // PullRequests opened or updated by this run (URLs).
    PullRequests       []string `json:"pullRequests,omitempty"`
    ObservedGeneration int64    `json:"observedGeneration,omitempty"`
}
```

### Shared types

```go
// SecretKeyReference points at a key in a Secret in the operator namespace.
type SecretKeyReference struct {
    // +kubebuilder:validation:MinLength=1
    Name string `json:"name"`
    // Key defaults per-field (e.g. "private-key.pem", "webhook-secret").
    // +optional
    Key string `json:"key,omitempty"`
}

// LocalObjectReference names another resource; scope is documented per field
// (OrgRef → cluster-scoped GuardianOrg; PolicyRef → same namespace).
type LocalObjectReference struct {
    // +kubebuilder:validation:MinLength=1
    Name string `json:"name"`
}
```

### Sample custom resources

```yaml
apiVersion: repo-guardian.dev/v1alpha1
kind: GuardianOrg
metadata:
  name: my-main-org           # cluster-scoped
spec:
  org: my-main-org
  app:
    appID: 123456
    installationID: 7891011
    privateKeyRef:
      name: my-main-org-app    # Secret in the operator namespace
      key: private-key.pem
    webhookSecretRef:
      name: my-main-org-app
      key: webhook-secret
  webhook:
    enabled: true              # → https://my-repo-guardian-operator.dev/my-main-org
---
apiVersion: repo-guardian.dev/v1alpha1
kind: GuardianPolicy
metadata:
  name: baseline
  namespace: repo-guardian
spec:
  orgRef:
    name: my-main-org
  schedule: "0 6 * * 1"        # weekly sweep; webhooks fire continuously
  skipForks: true
  skipArchived: true
  fileRules:
    - name: codeowners
      check: exists
      paths: [".github/CODEOWNERS"]
    - name: dependabot
      check: exists
      paths: [".github/dependabot.yml"]
  settingRules:
    - name: delete-branch-on-merge
      property: delete_branch_on_merge
      expected: true
      remediate: true
  branchProtectionRules:
    - name: protect-main
      branch: main
      requirePR: true
      requiredApprovals: 1
      requireLinearHistory: true
      remediate: true
```

## Open questions and decisions

These are the seeds for the downstream RFC/ADR/DESIGN docs.

1. **Engine execution strategy** — Native library (A) vs. Job runner (B) vs.
   operator-as-deployer (C)? *(→ RFC + ADR; the single most important decision.)*
2. **Webhook receiver topology** — in-manager extra listener vs. separate
   Deployment? Path-based (one Ingress + internal dispatch) vs. host-based
   (per-org Ingress)? *(→ ADR + DESIGN.)*
3. **Policy modeling** — typed CRD fields vs. `ConfigMap`/HCL reference vs.
   `RawExtension`? How much of the rich HCL schema (defaults cascade, PR
   templates, reconcilers, per-rule scope) do we type out vs. pass through?
   *(→ RFC.)*
4. **`GuardianRun` granularity & volume** — one CR per repo per event could be
   very chatty for large orgs. Coalesce/debounce? History-limit GC and TTL like
   renovate? Or keep an internal workqueue and only materialize CRs for failures?
   *(→ ADR.)*
5. **State / idempotency** — do we keep repo-guardian's `RepoState`
   (`LastCheckedAt`, `PolicyVersion`) at all, or rely solely on CRD status +
   `observedGeneration` + GitHub as source of truth? Drop Postgres/Valkey?
   *(→ ADR.)*
6. **Finalizers** — repo-guardian creates GitHub-side state (PRs, rulesets,
   branches). renovate-operator uses none. Do we need finalizers to clean up
   (e.g. close open guardian PRs) when a policy/org is deleted? *(→ ADR.)*
7. **Multi-org Secret placement** — all per-org Secrets in the operator
   namespace (renovate convention) vs. per-org namespaces? RBAC implications.
   *(→ DESIGN.)*
8. **Webhook IP allowlist & security** — port repo-guardian's GitHub-IP
   allowlist middleware? TLS/cert-manager for the Ingress? *(→ DESIGN.)*
9. **App bootstrapping** — do we help register the per-org GitHub Apps (App
   manifest flow) and surface the webhook URL/secret, or assume Apps are
   created out-of-band? *(→ future INV/RFC.)*

## Conclusion

**Answer: Yes — feasible, and largely a port-with-adaptation rather than a
greenfield build.**

- The **CRD triad** (`GuardianOrg / GuardianPolicy / GuardianRun`) maps
  repo-guardian's domain onto renovate-operator's proven
  `Platform / Scan / Run` lifecycle split.
- **Multi-org with per-org GitHub Apps** is a small, well-understood extension
  of renovate-operator's "one credential CR per installation" pattern — we
  promote the credential CR to hold a full per-org App **plus a webhook secret**.
- The **per-org webhook endpoint is the only genuinely net-new component**.
  Neither reference repo has an inbound webhook receiver; we design one that
  routes `/<org>` → `GuardianOrg`, verifies HMAC with that org's secret, and
  turns events into reconciliation work. The event-parsing/HMAC code lifts
  directly from repo-guardian.
- The **central unresolved decision** is *how the guardian engine runs*
  (in-process library vs. Job vs. operator-deploys-the-existing-app). It changes
  whether `GuardianRun` exists at all, so it must be settled first.

## Recommendation: document roadmap

Promote this INV into a focused doc set:

1. **RFC-0001 — repo-guardian operator: architecture & engine strategy.** The
   big-picture proposal; resolves open question #1 (and frames #3, #4).
2. **ADR-0001 — Engine execution model** (native library vs. Job vs. deployer).
3. **ADR-0002 — Per-org GitHub App credential model** (one App per `GuardianOrg`,
   Secrets in operator namespace).
4. **ADR-0003 — Webhook receiver topology & routing** (path-based, single
   Ingress, in-manager listener — or alternatives).
5. **DESIGN-0001 — Webhook receiver** (routing, per-org HMAC, event→`GuardianRun`
   mapping, security/IP-allowlist, TLS).
6. **DESIGN-0002 — CRD API** (`GuardianOrg / GuardianPolicy / GuardianRun`
   finalized types, validations, status conditions, printcolumns).
7. **IMPL-0001 — Phase 1 scaffold** (`kubebuilder create api` for the three
   kinds, `GuardianOrg` controller + credential validation + e2e smoke, mirroring
   renovate-operator's envtest/Ginkgo setup).

Next concrete step: open **RFC-0001** to lock the engine strategy, then the two
foundational ADRs, before any `kubebuilder create api`.

## References

- repo-guardian (service being ported): `github.com/donaldgifford/repo-guardian`
  - Auth: `internal/github/client.go` (ghinstallation per-installation cache)
  - Webhook: `internal/webhook/handler.go` (single endpoint, HMAC, event routing)
  - Policy: `internal/policy/types.go` (HCL rule schema), `internal/policy/defaults.go`
  - Engine: `internal/checker/engine_policy.go`, `internal/reconciler/*`
  - State: `internal/store/store.go` (`RepoState`)
- renovate-operator (operator template): `github.com/donaldgifford/renovate-operator`
  - `PROJECT`, `api/v1alpha1/*_types.go` (Platform/Scan/Run), `shared_types.go`
  - Controllers: `internal/controller/*` (thin reconcilers + pure builders)
  - Credentials: `internal/credentials/mirror.go`; conditions: `internal/conditions/`
- Kubebuilder Book: <https://book.kubebuilder.io>
- GitHub Apps / webhooks: <https://docs.github.com/en/apps>
- `bradleyfalzon/ghinstallation`: <https://github.com/bradleyfalzon/ghinstallation>
- This project: `CLAUDE.md` (Kubebuilder conventions), `PROJECT` (domain `repo-guardian.dev`)
