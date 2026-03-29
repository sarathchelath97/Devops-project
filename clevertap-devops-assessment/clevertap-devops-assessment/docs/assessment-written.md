# CleverTap Staff DevOps Engineer — Written Assessment
# Revision 2: All reviewer gaps addressed

---

## Section 1b: Terraform State & Drift Management

### State Structure

**Why S3 + DynamoDB + Atlantis (not Terraform Cloud or Spacelift):**
Both Terraform Cloud and Spacelift are valid. I choose self-managed S3+DynamoDB here because state files contain ARNs, subnet IDs, and resource references — storing these in a third-party SaaS adds a data egress concern. At CleverTap's scale the cost difference is meaningful, and Atlantis provides equivalent PR-gate + RBAC capability on-prem. Spacelift or TF Cloud become preferable at 50+ teams where managed SSO, audit logs, and UI justify the cost.

**State path convention:**

```
s3://clevertap-tfstate-{account-alias}/
  {account}/              # dev | staging | prod | eu-prod
    {region}/             # us-east-1 | ap-south-1 | eu-west-1
      {component}.tfstate # vpc | eks | rds | elasticache | iam
```

**Three isolation layers and the rationale behind each:**

*Separate S3 bucket per account:* A Terraform mistake in staging cannot corrupt prod state. The prod bucket policy has an explicit `Deny` for all principals except `arn:aws:iam::{prod-account-id}:role/TerraformDeployRole`. Cross-account role assumptions to write prod state are blocked at the bucket policy level — not just IAM.

*Component-level state files:* Monolithic state per region creates a blast-radius and locking problem. A `terraform apply` on VPC that runs for 3 minutes locks the entire state, blocking the EKS team simultaneously. Separate component files mean teams work in parallel. If EKS state is corrupted, VPC and RDS state are unaffected.

*Workspace isolation for feature branches:* Engineers testing a module change use a dedicated workspace (`workspaces/feature-{name}/eks.tfstate`). This never touches the `default` workspace and is cleaned up when the PR merges.

**RBAC on state access (enforced at bucket policy, not just IAM):**

```json
{
  "Effect": "Allow",
  "Action": ["s3:GetObject", "s3:PutObject"],
  "Principal": {"AWS": "arn:aws:iam::{account}:role/NetworkTeamRole"},
  "Resource": "arn:aws:s3:::clevertap-tfstate-prod/prod/*/vpc.tfstate"
},
{
  "Effect": "Deny",
  "Action": ["s3:*"],
  "Principal": {"AWS": "arn:aws:iam::{account}:role/NetworkTeamRole"},
  "Resource": "arn:aws:s3:::clevertap-tfstate-prod/prod/*/eks.tfstate"
}
```

The Network team can read/write `vpc.tfstate` but is explicitly denied on `eks.tfstate`. S3 bucket policy level — overrides any IAM policy grant.

**Atlantis for PR-gated applies (see `atlantis.yaml`):**

No one runs `terraform apply` locally against prod or staging. All applies flow through Atlantis which: (a) posts the plan as a PR comment, (b) checks `allowed_owners` per environment (prod restricted to `clevertap/platform-leads`), (c) requires PR approval + branch up-to-date before unblocking apply.

---

### Drift Detection & Remediation

**Tooling stack:**

| Layer | Tool | Purpose |
|---|---|---|
| Managed resource drift | `terraform plan -detailed-exitcode` via CodeBuild (nightly) | Detects in-place changes to Terraform-managed resources |
| Unmanaged resource audit | `driftctl scan` (nightly) | Finds resources that exist in AWS but not in any state file |
| Compliance baseline | AWS Config managed + custom rules | Continuous config compliance validation |
| Change attribution | CloudTrail → EventBridge → Lambda | Who changed what, when, outside of Terraform |
| Alerting | SNS → PagerDuty + `#terraform-drift` Slack | Classified alerts routed by severity |

**Why both `terraform plan` AND `driftctl`:** They catch different things. `terraform plan` finds managed resources that were changed in-place. `driftctl` finds the 40% of infrastructure that isn't in Terraform at all — click-ops resources that never had state. Both run nightly in CodeBuild, parse exit codes, and post structured diffs to Slack.

**Drift classification and remediation decision tree:**

```
Drift detected
│
├── Is this resource managed by Terraform?
│   ├── YES → terraform plan shows a diff
│   │   ├── Was there a recent incident? → Hotfix drift → terraform import or
│   │   │   update module to match actual state. Do NOT blindly apply over it.
│   │   ├── Was the change made by an authorised principal? → Config drift →
│   │   │   Schedule reconciliation PR within 48h
│   │   └── Unauthorised principal? → Security incident → Revert immediately,
│   │       escalate to security, review CloudTrail for lateral movement
│   └── NO → Unmanaged resource (driftctl finds it)
│       └── Sprint-plan terraform import. Block further click-ops via SCP:
│           Deny ec2:RunInstances, rds:CreateDBInstance without
│           terraform:managed = true tag condition.
```

**Drift health metrics to track over time:**

- Drift events per week (target: trending toward 0)
- Mean time to remediate drift (target: < 24h non-critical, < 4h security-related)
- % infrastructure under IaC (target: 100% within 90 days on Day 30)

---

## Section 1c: EU Data Residency Architecture

### Problem

EU customer data must never leave `eu-west-1`. GDPR fines are existential. The control plane (ArgoCD, CI/CD) can remain centralised; the data plane must be fully isolated. "Separate region" alone is not sufficient — we need hard enforcement at every layer.

### Layer 1: Separate AWS Account (strongest isolation)

EU runs in a dedicated `clevertap-eu-prod` account, separate from `clevertap-us-prod`. This is the most important decision:

- **No shared Kafka, no shared RDS, no shared ElastiCache cross-region.** EU tenant events flow into a Kafka cluster in eu-west-1 only.
- **SCP on the EU account** enforces a blanket deny on data service APIs targeting non-EU regions:

```json
{
  "Sid": "DenyNonEUDataServices",
  "Effect": "Deny",
  "Action": [
    "s3:PutObject", "s3:CopyObject",
    "rds:CreateDBInstance", "rds:RestoreDBInstance",
    "elasticache:CreateCacheCluster",
    "kafka:CreateCluster",
    "ec2:RunInstances"
  ],
  "Resource": "*",
  "Condition": {
    "StringNotEquals": { "aws:RequestedRegion": "eu-west-1" }
  }
}
```

Even a misconfigured CI job or Terraform module cannot provision data infrastructure outside eu-west-1. The SCP is enforced at AWS Organizations level — no IAM policy in the EU account can override it.

- **S3 bucket policy** on all EU buckets denies `s3:ReplicateObject` to prevent accidental cross-region replication.
- **KMS keys are regional.** The KMS key for EU data encryption lives in eu-west-1 and is never replicated cross-region by AWS.

### Layer 2: Cluster Topology — Single Control Plane, Isolated Data Plane

```
ArgoCD Control Plane (us-east-1, control-plane account)
  ├── pushes manifests → clevertap-prod-use1 (US)
  ├── pushes manifests → clevertap-prod-aps1 (APAC)
  └── pushes manifests → clevertap-eu-prod-euw1 (EU, eu-west-1)
                         [different AWS account]
```

ArgoCD pushes only Kubernetes manifests and Helm chart parameters — no customer data transits the ArgoCD connection. The EU cluster's API endpoint is private (VPN-accessible only). ArgoCD connects via a cross-account IAM role with least-privilege access to only `update` deployments in the EU cluster.

### Layer 3: CI/CD Pipeline Enforcement

The pipeline enforces residency at every promotion step:

```yaml
- name: Enforce data residency
  run: |
    TARGET_SERVER=$(yq '.spec.destination.server' "$ARGOCD_APP_FILE")
    EU_SERVER="https://eks-eu-west-1.clevertap.internal"

    # Block EU service deploying to non-EU cluster
    if [[ "$SERVICE_DATA_REGION" == "eu" && "$TARGET_SERVER" != "$EU_SERVER" ]]; then
      echo "::error::EU-tagged service must deploy to EU cluster only. Target: $TARGET_SERVER"
      exit 1
    fi

    # Verify image was built and pushed to EU ECR (never pull from US registry)
    if [[ "$SERVICE_DATA_REGION" == "eu" ]]; then
      aws ecr describe-images \
        --registry-id "$AWS_ACCOUNT_EU" \
        --region eu-west-1 \
        --repository-name "$SERVICE_NAME" \
        --image-ids imageTag="$IMAGE_TAG" \
        || { echo "::error::Image not in EU ECR. EU services must build to eu-west-1."; exit 1; }
    fi
```

ECR repositories for EU services are in eu-west-1. Docker images for EU deployments are built, scanned, and pushed within the EU pipeline — they never transit US-region registries.

### Layer 4: Tenant Routing

Every CleverTap account record carries a `data_region` field set immutably at account creation. The API gateway (deployed in all regions) reads this field and routes EU-tenant API calls exclusively to the eu-west-1 cluster load balancer. This routing logic is covered by contract tests in the CI pipeline that assert: a synthetic EU-tenant JWT never receives a response from a non-EU endpoint.

### Layer 5: IAM Permission Boundaries in EU Account

All IRSA roles and human IAM roles in the EU account have an attached permission boundary that explicitly denies any action on resources outside eu-west-1:

```json
{
  "Effect": "Deny",
  "Action": "*",
  "Resource": "*",
  "Condition": {
    "StringNotEquals": { "aws:RequestedRegion": "eu-west-1" },
    "StringNotLike": { "aws:RequestedRegion": ["IAM", "STS"] }
  }
}
```

Even if an attacker compromises a pod's IRSA role, they cannot exfiltrate data by calling APIs in other regions.

---

## Section 2a: Observability Stack Design

### Design Philosophy

At 40B events/day the observability enemies are: (1) cardinality explosion killing Prometheus TSDB, (2) alert fatigue making real incidents invisible, (3) log cost exploding with unstructured data. Every tool choice is made against these specific failure modes — not generically.

### Tool Choices by Pillar

**Metrics → Prometheus + Thanos:**

- Per-cluster Prometheus (local, 2-day hot retention) → remote_write to Thanos Receive → S3 (1-year, compressed Parquet blocks) → Thanos Query Frontend for global dashboards in Grafana.
- **Why not CloudWatch Metrics alone:** CloudWatch custom metrics cost $0.30/metric/month. At this scale with proper instrumentation you easily hit millions of series — CloudWatch becomes the largest line item. Thanos on S3 costs a fraction. We keep CloudWatch for AWS-native signals (EC2, RDS, ALB) where it's free/low-cost.
- **Why not Datadog:** Datadog pricing scales with hosts and ingested metrics volume. At CleverTap scale it would rival or exceed the AWS bill itself. Grafana + Thanos gives equivalent dashboarding at infrastructure-only cost.

**Logs → Fluent Bit + OpenSearch:**

- Fluent Bit DaemonSet (10MB RSS vs. Fluentd's 40MB — at 200+ nodes this is 6GB of saved node memory per cluster).
- OpenSearch on EC2 Reserved Instances: hot (7d on m6g.2xlarge), warm (15d on m6g.large), cold/UltraWarm (90d), delete at 365d. Cost is ~80% lower than CloudWatch Logs Insights at this volume.
- **Structured JSON log mandate:** All services must emit JSON with standard fields: `timestamp`, `level`, `service`, `trace_id`, `account_id`, `message`. Unstructured log lines are dropped by a Fluent Bit Lua filter and counted in a `dropped_log_lines_total` metric — teams see their own compliance rate.
- **Why not Loki:** Loki excels at medium scale with chunk-based querying. For ad-hoc incident debugging across 40B events/day with full-text search requirements, OpenSearch's inverted index is significantly faster. Loki would be reconsidered for batch/archive workloads.

**Traces → AWS X-Ray + Jaeger (tail-based sampling):**

- X-Ray for AWS-native integration points (ALB, API GW, Lambda) — zero instrumentation cost.
- Jaeger for application services with **tail-based sampling**: decide to keep a trace *after* it completes. 100% of error traces are kept. 100% of traces with p99 > 500ms are kept. Normal traces: 10% sample. This gives full fidelity for debugging while controlling storage at scale.
- `trace_id` propagated via W3C Trace Context headers, included in structured logs, enabling: Grafana alert → Jaeger trace → OpenSearch logs in one click.

**Events → EventBridge + Alertmanager:**

- EventBridge captures infrastructure lifecycle (ASG scale events, Spot interruptions, RDS failovers) → forwarded to OpenSearch tagged `event_type: infrastructure`.
- **Deployment events** overlay: every Helm release emits a structured event to OpenSearch. Grafana annotations pull these, so every graph shows vertical deployment lines — the most useful debugging pattern: "did the metric degrade correlate with a deploy?"

### Data Flow

```
Pods (stdout/stderr JSON)
  → Fluent Bit DaemonSet
  → OpenSearch [hot 7d → warm 15d → cold 90d → delete]

Pods (metrics /metrics endpoint)
  → Prometheus per-cluster (2d local)
  → Thanos Receive → S3 (1yr)
  → Thanos Query Frontend → Grafana

Pods (traces via ADOT/Jaeger agent)
  → Jaeger Collector (tail-based sampling)
  → Elasticsearch backend [7d hot, 30d cold]

AWS services
  → EventBridge → Lambda → OpenSearch (infrastructure events)
  → CloudWatch (AWS-native metrics) → Grafana CloudWatch datasource
```

### Cardinality Management

High-cardinality labels — `user_id`, `account_id`, `request_id`, `trace_id` as Prometheus metric labels — are the #1 way to kill a TSDB. One mislabelled counter across 4B devices creates 4B series. Controls:

1. **`relabel_configs`** in every scrape config drop known high-cardinality labels before TSDB ingestion.
2. **`sample_limit: 50000`** per scrape job — if a service emits more than 50K series, Prometheus drops the scrape and fires `PrometheusScrapeExceededSampleLimit` to the *service team*, not the platform on-call.
3. **Metrics design review gate** in CI: label names matching `.*_id$` or `.*_uuid$` are rejected by a lint rule unless approved via a metrics design PR.
4. **Cardinality dashboard** visible to all engineers (using `topk(10, count by(__name__)({__name__=~".+"}))`): teams see their own series footprint. High-cardinality services appear in the weekly FinOps digest alongside cost data.
5. **Thanos Compactor downsampling** at 5m and 1h resolutions for data older than 7d — reduces long-term query cost without losing trend visibility.

### SLO-Based Alerting

**Why threshold alerting fails at this scale:** A CPU alert at 80% fires on every campaign burst. A 5xx rate at 0.1% fires during the first 30 seconds of every canary deploy. These are not incidents — they're noise that trains on-call to ignore alerts.

**SLO burn rate alerting:** For event-ingestion-service with 99.9% availability (43.8 min/month error budget):

```yaml
# Fast burn: consuming 5% of monthly budget in 1 hour → page now
- alert: EventIngestionFastBurn
  expr: |
    (
      rate(http_requests_total{service="event-ingestion-service",status=~"5.."}[1h])
      / rate(http_requests_total{service="event-ingestion-service"}[1h])
    ) > (14.4 * 0.001)
  for: 2m
  labels: {severity: critical, page: "true"}
  annotations:
    summary: "Event ingestion burning error budget at 14.4x — will exhaust monthly budget in 5h"

# Slow burn: daytime investigation, no page
- alert: EventIngestionSlowBurn
  expr: |
    (
      rate(http_requests_total{service="event-ingestion-service",status=~"5.."}[6h])
      / rate(http_requests_total{service="event-ingestion-service"}[6h])
    ) > (6 * 0.001)
  for: 15m
  labels: {severity: warning, page: "false"}
```

The `14.4×` multiplier: firing only when the error rate is 14.4 times the budget rate, meaning 5% of the monthly budget would be consumed in 1 hour. This approach reduces 200 alerts/day to ~10 high-signal pages.

---

## Section 2c: Alert Noise Reduction

### Problem

120 auto-resolving pages/day × 5 min human attention = 10 engineer-hours/day wasted. More critically, chronic alert fatigue makes real P0s invisible — on-call teams start ack-ing without investigating.

### Phase 1: Audit and Classify (Week 1)

Export 30-day alert history from Alertmanager. For every alert rule, compute:

| Signal | Formula | Threshold for action |
|---|---|---|
| Auto-resolve rate | % resolved < 5min without ack | > 20% → candidate for removal |
| Fire rate | Fires per day | > 10/day → investigate sensitivity |
| Incident correlation | % followed by P0/P1 within 1h | < 30% → not actionable |
| Ack rate | % that received any acknowledgement | < 50% → likely ignored noise |

**Five classification categories:**

- **Actionable** (keep, tune): High incident correlation, low auto-resolve. These are the alerts worth keeping.
- **Noisy-but-real** (migrate to burn rate): Real condition, fires too sensitively. Convert to multi-window SLO burn rate. Extend `for:` from 1m to 10–15m.
- **Autopilot** (delete): Always auto-resolves. No human action ever needed. Delete entirely — add a Grafana annotation instead so the blip is visible on dashboards without waking anyone.
- **Redundant** (inhibit): Always co-fires with a higher-severity parent. Add `inhibit_rules` to Alertmanager:
  ```yaml
  inhibit_rules:
    - source_matchers: [alertname="NodeDown"]
      target_matchers: [alertname=~"KubePodCrashLooping|KubeContainerWaiting"]
      equal: [node]
  ```
- **Orphaned** (delete): Fires for services that no longer exist. Delete immediately — no discussion.

### Phase 2: Remediation (Weeks 2–4)

1. Delete orphaned + autopilot alerts — immediate, no risk.
2. Convert noisy threshold alerts to burn rate (see §2a for implementation).
3. **Alert deduplication in Alertmanager** — group_by `[alertname, cluster, namespace]` with `group_wait: 30s`. A deployment rollout that creates 15 pod alerts arrives as 1 grouped notification, not 15 pages.
4. **Deployment silence policies** — the staging/production pipeline calls `POST /api/v1/silences` against Alertmanager at deploy start, expiring in 15 minutes. Canary-related noise is automatically suppressed.
5. **Replace CPU/memory threshold alerts with HPA** — if the platform auto-scales in response to load, no human action is needed. Alert only on HPA at max replicas AND error rate increasing simultaneously (that's a real problem). A CPU spike that HPA handles is not an incident.

### Phase 3: Measure Alerting Health (Ongoing)

Grafana dashboard tracking alerting system health, visible to all engineers:

| Metric | Target |
|---|---|
| Pages reaching on-call per day | < 20 |
| Auto-resolve rate | < 10% |
| Mean time to acknowledge | < 5 min |
| Alert → incident correlation | > 80% |
| MTTD (metric anomaly to alert firing) | < 5 min |

**Governance gate:** Any new alert rule requires a PR review checklist: (1) What is the action when this fires? (2) Runbook link? (3) Was it back-tested against 30 days of historical data? If the answer to (1) is "monitor it" — it's a Grafana panel, not an alert rule.

---

## Section 3a: Production Canary — Full Description

See `kubernetes/manifests/rollout.yaml` for the full Argo Rollouts config.

**Rollout steps:**
1. Set canary weight to 10% — ALB weighted target group splits traffic at load balancer level (no sidecar/Istio required).
2. Bake for 2 minutes.
3. `AnalysisRun` executes three Prometheus queries (see rollout.yaml): error rate, p99 latency, Kafka consumer lag.
4. If all pass: advance to 50%, bake 5 minutes, run analysis again.
5. If all pass: advance to 100%.

**Automated rollback triggers:**
- HTTP error rate > 1% in the canary pods
- p99 latency > 500ms
- Kafka consumer lag > 10,000 messages (signals the canary is falling behind processing and buffering upstream)

On any `AnalysisRun` failure: Argo Rollouts sets canary weight to 0% automatically. Stable version serves 100% of traffic. A PagerDuty alert fires for the automated rollback — team knows to investigate without an outage occurring.

**Secret injection (no values in YAML):**

```
AWS Secrets Manager (source of truth)
  ↓
External Secrets Operator (IRSA-authenticated, no static credentials)
  ↓ watches ExternalSecret CRs, syncs on schedule
Kubernetes Secret (in-cluster, namespace-scoped)
  ↓ referenced via envFrom.secretRef in pod spec
Application reads env vars at startup
```

Secret rotation: update the value in Secrets Manager. ESO syncs to the Kubernetes Secret within its polling interval. Stakater Reloader detects the Secret change and triggers a rolling restart — zero-downtime secret rotation without any pipeline involvement.

---

## Section 3b: Internal Developer Platform (IDP)

### Architecture (5 Layers)

**Layer 1 — Self-service UI (Backstage Software Templates):**
Engineers fill a form: resource type, size (small/medium), TTL (1–7 days), team name. Backstage renders a Terraform module invocation and opens a PR against the `ephemeral-envs` repo. Atlantis plans it, the engineer approves their own PR (one-click), Atlantis applies. No DevOps team involvement for standard requests.

**Layer 2 — Pre-approved module catalogue:**
Permitted resource types: `rds-ephemeral`, `elasticache-ephemeral`, `sqs-queue`, `s3-isolated`. Modules hard-code all security decisions: private subnets only, `publicly_accessible = false`, encryption enabled, `deletion_protection = false` (required for auto-cleanup). Instance size allow-list: only `t3.medium` and `t3.large` — larger sizes trigger a Slack approval workflow to the requesting team's manager.

**Layer 3 — Dedicated ephemeral AWS account:**
All IDP resources are in `clevertap-ephemeral`. Separate from staging and prod — blast radius fully contained. The Terraform IDP role has SCPs blocking IAM modifications, VPC peering changes, and access to any resource not tagged `provisioned-by: idp`.

**Layer 4 — Cost governance (OPA + infracost):**
Before Atlantis apply, an OPA Rego policy evaluates the Terraform plan JSON against an infracost estimate: total monthly cost of the environment must be ≤ $500. Above this threshold: apply blocked, Slack approval required from an engineering manager. Every resource is tagged: `provisioned-by: idp`, `env-ttl: {date}`, `cost-owner: {team}`, `feature-branch: {branch}`.

**Layer 5 — Auto-cleanup Lambda (cost control and hygiene):**
Runs hourly. Queries AWS Resource Groups Tagging API for `provisioned-by: idp` resources. Lifecycle:
- T-24h: Slack warning with "Extend 3 days" button
- T=0: No response → `terraform destroy` on the workspace
- Max 2 extensions (6 days total) before requiring DevOps review

**Production data safety:** SCP in ephemeral account explicitly denies `rds:RestoreDBInstanceFromDBSnapshot` for snapshots from prod accounts. Feature environments can only use synthetic seed data from an approved seed dataset — production data can never be copied to a feature environment.

---

## Section 4a: 90-Day Cost Reduction Plan

**Target:** $105–126K/month reduction on $420K/month (~25–30%)

**Measure before cutting:** Week 1 is instrumentation, not action. Enable AWS Cost Explorer cost allocation tags. Query VPC Flow Logs via Athena to identify top cross-region byte-pair costs (the hidden cost driver). Without measurement, optimisation is guesswork.

### Week 1–2: Quick Wins

| Initiative | Est. Savings | Effort | Risk |
|---|---|---|---|
| Delete unattached EBS volumes, stale snapshots, idle EIPs | $6K/mo | Low | None |
| S3 lifecycle: IA at 30d, Glacier at 90d, delete at 365d | $15K/mo | Low | Low |
| Scale non-prod EKS node groups to 0 overnight + weekends | $12K/mo | Low | Low (dev/staging only) |
| Right-size top-3 over-provisioned RDS (< 30% avg CPU per Performance Insights) | $10K/mo | Medium | Low (blue/green resize) |
| Consolidate dev NAT Gateways (1 per VPC → 1 per region in dev) | $4K/mo | Low | None |
| **Quick win total** | **~$47K/mo** | | |

### Month 1–2: Right-Sizing & Commitments

**Spot expansion:** The EKS module already has Spot node groups. Shift 60–70% of stateless application pods to Spot (configured via node affinity + the spot node group labels). Spot is 60–70% cheaper for equivalent instances. Conservative: ~$20K/mo.

**Savings Plans vs. Reserved Instances — the distinction matters:**

Use **Compute Savings Plans** for EKS EC2: apply to any instance family/size/region. We are actively diversifying instance types (c5/m5/r5 mix). Compute SPs flex with us. Buying EC2 RIs for EKS would lock us into specific families while we're changing the mix — waste.

Use **RDS Reserved Instances (1-year, partial upfront)**: RDS instance types are stable and predictable. Buy RIs *after* right-sizing is confirmed — never before. 1-year over 3-year for flexibility during the architectural changes in month 2–3.

Same logic for **ElastiCache Reserved Nodes**: stable, predictable, 35–40% discount.

Buy commitments only after right-sizing is confirmed. Buying RIs on over-provisioned instances locks in waste.

Estimated commitment savings: ~$25K/mo.

### Month 2–3: Architectural Changes

**Cross-region data transfer (the hidden cost driver):**

This is the most important cost to investigate at CleverTap's scale. Athena query against VPC Flow Logs:

```sql
SELECT srcaddr, dstaddr, SUM(bytes)/1e9 AS gb_transferred
FROM vpc_flow_logs
WHERE year='2024' AND month='06'
  AND srcaddr LIKE '10.10.%'    -- us-east-1 CIDR
  AND dstaddr LIKE '10.20.%'    -- ap-south-1 CIDR
GROUP BY 1,2 ORDER BY 3 DESC LIMIT 20;
```

At $0.02/GB cross-region transfer, 500TB/month = $10K. Common culprits at this scale: event data replication jobs, analytics pulling raw events cross-region, redundant health check probes polling cross-region endpoints.

Remediation: implement **regional write-local** — events ingested in each region are processed in that region. Only aggregated campaign metrics (KB/s, not GB/s) are replicated cross-region. Estimated 60–70% reduction in cross-region transfer: $15–20K/mo.

**CloudFront for campaign config fetches:**
4B+ devices repeatedly fetching campaign configuration payloads (segment rules, templates). These are small, read-heavy, and highly cacheable. CloudFront edge caching eliminates redundant origin compute and data transfer: ~$8K/mo.

**Aurora Serverless v2 for non-prod DBs:**
Staging databases run 24/7 but are active ~8 hours/day. Aurora Serverless v2 scales to 0.5 ACU when idle. Estimated: ~$6K/mo.

**Total estimated savings: $47K + $25K + $29K ≈ $101–110K/month** — meeting the 25–30% target.

---

## Section 4b: FinOps Process Design

### Mandatory Tagging Policy

Enforced at two levels: (1) SCP tag-on-create conditions in prod block resource creation without mandatory tags; (2) AWS Config `required-tags` rule fires within 1 hour. Untagged resources after 48h → Slack warning to `cost-owner` team; after 72h → scheduled for termination.

| Tag | Values | Enforcement Layer |
|---|---|---|
| `Environment` | dev, staging, prod, eu-prod | SCP tag-on-create |
| `Team` | Enum from approved list | Config rule |
| `Service` | Matches service registry | Config rule |
| `CostCenter` | Finance cost code | Config rule |
| `ManagedBy` | terraform, idp (manual = drift alert) | Config rule + drift alert |
| `DataRegion` | us, ap, eu | Required on all data services |

### Showback → Chargeback Model

**Phase 1 — Showback (months 1–3):** AWS Cost Explorer cost allocation tags + weekly Lambda job generates per-team cost reports posted to team Slack channels every Monday. No budget consequence yet. Goal: establish awareness, let teams identify their own waste.

**Phase 2 — Chargeback (month 4+):** Cloud spend becomes a line item in each team's engineering budget in annual planning. Shared infrastructure (TGW, central logging, control plane) is allocated to a platform overhead cost center — not charged to product teams. Accuracy is critical for buy-in.

### Cost Dashboards

Grafana dashboard per team (self-serve) includes: MTD spend vs. budget gauge with 70%/90% alert bands, daily spend trend (30d), top 5 resources by cost, Spot coverage %, Savings Plan utilisation %, and untagged resource count linked to AWS Config findings.

### Alerting Thresholds

| Alert | Threshold | Channel |
|---|---|---|
| Budget forecast breach | Forecasted to exceed 100% by month-end | Team + EM (Slack + email) |
| Budget actuals | Actual > 90% of monthly budget | Team (Slack) |
| Cost anomaly | 7-day rolling spend > 25% above baseline | Platform FinOps (Slack) |
| Untagged resource | Resource untagged > 48h | Resource owner's team |
| Savings Plan coverage | Coverage drops below 65% | Platform FinOps |
| RI utilisation | Drops below 80% (RI being wasted) | Platform FinOps |

**Weekly FinOps digest (automated Lambda → Slack):**

```
📊 Weekly Cloud Cost Digest — Team: Product / Payments
Week ending: 2024-06-14

This week:     $8,420  (+12% vs last week)
Month to date: $21,340 / $35,000 budget (61%)
Forecast EOMonth: $33,800  ✅ On track

Top spenders:
  RDS (db.r6g.2xlarge × 2)      $2,800
  EKS compute (m5.2xlarge × 8)   $2,100
  Cross-region data transfer      $1,200  ⚠️

🔍 Savings opportunities:
  → 2 idle EBS volumes: $140/mo  [Clean up →]
  → RDS CPU avg 18% last 7d — consider downsizing  [View →]
  → 0 Spot nodes in use — shift stateless pods for ~40% compute saving  [Runbook →]
```
