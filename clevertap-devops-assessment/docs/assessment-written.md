# CleverTap Staff DevOps Engineer — Written Assessment

---

## Section 1b: Terraform State & Drift Management

### State Structure

The state backend uses **S3 + DynamoDB** with a strict path convention:

```
s3://clevertap-tfstate-{account-alias}/
  {account}/            # dev, staging, prod
    {region}/           # us-east-1, ap-south-1, eu-west-1
      {component}.tfstate   # vpc, eks, rds, elasticache
```

**Why this structure:**

- **Account isolation** is the first-level key because a Terraform mistake in staging should not be able to affect production state — they must be in different buckets or at minimum different prefixes with explicit IAM deny policies between them. I prefer separate buckets per account: the prod bucket policy denies writes from any principal that is not the `TerraformDeployRole` in the prod account.

- **Component-level state files** rather than a monolithic state per region prevents blast radius. If the `rds` state becomes corrupted, it doesn't affect `eks`. Separate state also speeds up plan/apply by keeping state files small.

- **DynamoDB locking** with `LockID` prevents concurrent applies from two engineers or two CI jobs from corrupting state.

**Multi-team access:** Each team gets an IAM role (`NetworkTeam`, `DataInfraTeam`, `PlatformTeam`) with S3 prefix-level permission boundaries. The networking team can read/write `vpc.tfstate` but cannot touch `eks.tfstate`. This is enforced via S3 bucket policies, not just IAM — so even an over-privileged token can't cause cross-team damage.

**Workspaces vs. directories:** I prefer explicit directory structures over Terraform workspaces for environment separation. Workspaces share module code but the state key is derived from the workspace name — this makes it too easy for a `terraform workspace select staging` + `terraform apply` to accidentally operate against the wrong environment. Directory-per-environment makes the target explicit in the path.

---

### Drift Detection & Remediation

**Tooling choice: Driftctl + Atlantis + custom Lambda reconciler**

| Layer | Tool | Purpose |
|---|---|---|
| Scheduled drift scan | `driftctl scan` (or `terraform plan -detailed-exitcode`) | Detects out-of-band changes |
| Pipeline enforcement | Atlantis PR automation | Plans are reviewed before applies |
| Alerting | Lambda → SNS → PagerDuty | Routes drift alerts to on-call |
| Audit trail | AWS Config + CloudTrail | Who made what change when |

**Drift detection workflow:**

A scheduled EventBridge rule fires daily (off-peak) and triggers a CodeBuild project that runs `terraform plan` across all environment roots. The plan output is parsed: any non-empty diff is a drift signal. The CodeBuild job posts the diff to a dedicated `#terraform-drift` Slack channel and opens a Jira ticket tagged `drift-remediation`.

**Drift remediation decision:**

Not all drift is equal. We classify it:

- **Intentional drift (hotfix):** An SRE manually patched a security group during an incident. Remediation: reconcile IaC with the actual state (`terraform import` or update the module), not blindly apply over it.
- **Malicious/unauthorized drift:** A resource was modified outside of Terraform by a non-authorized principal. Remediation: revert the change (apply from known-good state), escalate to security for access review.
- **Click-ops debt:** The 40% of infrastructure not yet in CDK/Terraform. Remediation: sprint-plan the import effort; block further click-ops via SCP (`Deny` on `ec2:RunInstances`, `rds:CreateDBInstance`, etc. without a `terraform:managed` tag).

---

### Transit Gateway vs. VPC Peering — Justification

**Choice: AWS Transit Gateway**

VPC Peering is point-to-point (N×(N-1)/2 connections for N VPCs) and does not support transitive routing. With two regions today expanding to EU-West-1 tomorrow, VPC Peering would require 3 separate peering connections, 6 route table entries per VPC, and manual updates every time a new VPC is added.

Transit Gateway provides a hub-and-spoke model: each VPC attaches once to the TGW, and the TGW's route table controls which attachments can reach each other. Adding EU-West-1 is a single new attachment + route table entry. TGW also supports inter-region peering between TGW instances, giving a clean `TGW-USE1 ↔ TGW-EUW1` peering with full routing control.

For the EU data residency requirement specifically, TGW route tables can be configured to explicitly **not propagate** EU subnet routes to non-EU TGW route tables, enforced at the network layer.

---

## Section 1c: EU Data Residency Architecture

### Challenge

EU customer data must never leave `eu-west-1`. We need a single control plane for deployments, but routing, storage, and compute for EU tenants must be isolated.

### Architecture

**Cluster topology:**
- Three EKS clusters: `clevertap-prod-use1`, `clevertap-prod-aps1`, `clevertap-prod-euw1`
- Cluster federation via **ArgoCD with ApplicationSets** — a single ArgoCD instance (deployed in us-east-1, the control plane region) manages all three clusters. ArgoCD only pushes Kubernetes manifests and Helm chart deployments; it does not route customer data.
- The EU cluster is provisioned identically via the same Terraform EKS module but instantiated in `eu-west-1`. No cross-region data plane traffic.

**IAM boundary enforcement:**

An AWS Service Control Policy (SCP) on the EU AWS account enforces:

```json
{
  "Effect": "Deny",
  "Action": [
    "s3:PutObject",
    "rds:CreateDBInstance",
    "elasticache:CreateCacheCluster",
    "kafka:CreateCluster"
  ],
  "Resource": "*",
  "Condition": {
    "StringNotEquals": {
      "aws:RequestedRegion": "eu-west-1"
    }
  }
}
```

This means even if a misconfigured Terraform module or CI job targets the wrong region, the SCP denies the API call at the AWS level — infrastructure cannot be provisioned outside EU-West-1 from the EU account.

**Tenant routing:**

Tenant metadata is tagged at account creation with `data_region: eu`. The API gateway tier (running in all regions) reads this tag and routes EU tenant requests exclusively to the `eu-west-1` cluster endpoint. This routing logic is tested as part of the CI pipeline with integration tests that assert EU-tagged synthetic requests never reach non-EU endpoints.

**CI/CD pipeline enforcement:**

The GitHub Actions deployment workflow has a step that reads the target ArgoCD Application's cluster annotation:

```yaml
- name: Enforce data residency
  run: |
    TARGET_CLUSTER=$(yq '.spec.destination.server' argocd-app.yaml)
    if [[ "$TARGET_CLUSTER" == *"euw1"* ]]; then
      # Verify the image was built and scanned in an EU-compliant pipeline
      aws ecr describe-images \
        --registry-id $AWS_ACCOUNT_EU \
        --region eu-west-1 \
        --repository-name $SERVICE_NAME \
        --image-ids imageTag=$IMAGE_TAG
    fi
```

ECR repositories for EU services are in `eu-west-1`. Images are built and pushed to the EU ECR — they never transit through US-region registries for EU deployments.

**Data at rest:** RDS and ElastiCache for EU tenants are in `eu-west-1` subnets. KMS keys are regional (eu-west-1 KMS) — these keys are never replicated cross-region by AWS. S3 buckets for EU data have `BucketReplication` disabled and a bucket policy denying `s3:ReplicateObject`.

---

## Section 2a: Observability Stack Design

### Philosophy

At 40B events/day, the primary observability enemies are cardinality explosion, alert noise, and MTTD (mean time to detect) being measured in minutes rather than seconds. The stack must be optimised for signal-to-noise ratio, not comprehensiveness.

### Tooling by Pillar

**Metrics:**
- **Collection:** Prometheus with `remote_write` to Thanos Receive
- **Storage:** Thanos (long-term, multi-region query federation) backed by S3
- **Rationale:** CloudWatch alone is expensive at high cardinality and lacks cross-region federation. Thanos provides unlimited retention on S3 at a fraction of CloudWatch Metrics cost, with global query via Thanos Query Frontend.
- **Cardinality control:** `relabel_configs` in each Prometheus scrape config drop high-cardinality labels (e.g., `user_id`, `session_id`, `request_id`) before ingestion. We enforce a per-job series limit (`sample_limit: 100000`) to prevent a runaway service from exploding the TSDB. Prometheus `tsdb.max_block_bytes` and retention policies are set per tier (hot: 15d local, cold: 1y in Thanos/S3).

**Logs:**
- **Collection:** Fluent Bit as a DaemonSet (lighter than Fluentd, ~10MB RSS vs ~40MB)
- **Aggregation/Storage:** OpenSearch (self-managed on EC2 reserved instances for cost control), with ILM policies: hot → warm → cold → delete
- **Rationale:** CloudWatch Logs at this scale costs ~$0.50/GB ingested + $0.03/GB stored. With 40B events/day generating tens of TB of logs, this is cost-prohibitive. OpenSearch with tiered storage is ~80% cheaper.
- **Structured logging mandate:** All services must emit JSON logs with standard fields: `trace_id`, `service`, `level`, `timestamp`, `account_id` (for tenant debugging). Unstructured logs are rejected by a Fluent Bit filter that drops non-JSON lines.

**Traces:**
- **Collection/Storage:** AWS X-Ray (for Lambda and EKS via ADOT Collector) + Jaeger for high-volume services
- **Rationale:** X-Ray integrates natively with ALB, API Gateway, and Lambda — zero instrumentation cost there. For high-throughput services (event ingestion, Kafka consumers), use Jaeger with tail-based sampling (10% baseline, 100% on error) to control storage costs while capturing all failure paths.
- **Trace-metric-log correlation:** All three pillars share `trace_id` as a common field. Grafana's unified data source query allows jumping from a Grafana alert → Jaeger trace → OpenSearch log in one click.

**Events:**
- AWS EventBridge for infrastructure events (ASG scale events, EKS node additions, RDS failovers)
- Kubernetes Events exported to OpenSearch via `kube-state-metrics` + custom exporter
- Deployment events: every Helm release emits a structured event to OpenSearch tagged `event_type: deployment` — enables overlaying deployments on metric graphs to instantly see correlation.

### SLO-Based Alerting

**Why SLO alerting reduces noise:**

Traditional threshold alerting fires when a metric crosses a static line — even briefly. A 30-second CPU spike to 85% is not actionable. SLO alerting asks "are we consuming error budget faster than sustainable?" — and only pages when the burn rate indicates we will miss our SLO.

**Implementation:**

For the event-ingestion service with a 99.9% availability SLO (43.8 minutes/month error budget):

```yaml
# Prometheus alerting rule — burn rate based
- name: slo.event_ingestion
  rules:
    # Fast burn: consuming 5% of monthly budget in 1 hour → page immediately
    - alert: EventIngestionFastBurn
      expr: |
        (
          rate(http_requests_total{service="event-ingestion-service",status=~"5.."}[1h])
          /
          rate(http_requests_total{service="event-ingestion-service"}[1h])
        ) > (14.4 * 0.001)
      for: 2m
      labels:
        severity: critical
        team: platform

    # Slow burn: consuming 10% of monthly budget in 6 hours → ticket (not page)
    - alert: EventIngestionSlowBurn
      expr: |
        (
          rate(http_requests_total{service="event-ingestion-service",status=~"5.."}[6h])
          /
          rate(http_requests_total{service="event-ingestion-service"}[6h])
        ) > (6 * 0.001)
      for: 15m
      labels:
        severity: warning
        team: platform
```

The `14.4` multiplier means: firing only when the error rate is 14.4× the error budget rate, which represents consuming 5% of the monthly budget in 1 hour. This approach generates a small number of high-signal alerts rather than 200 noisy threshold violations.

---

## Section 2c: Alert Noise Reduction

### Problem Statement

200 alerts/day, 60% auto-resolving in <5 minutes = 120 false-positive pages/day. At roughly 5-10 minutes of human attention per alert, this is 10-20 engineer-hours/day wasted on noise. More critically: alert fatigue means real P1s get ignored.

### Systematic Approach

**Phase 1: Audit (Week 1)**

Export all alert definitions and their firing history from Prometheus Alertmanager. For each alert, compute:
- Fire count in last 30 days
- Auto-resolve rate (resolved without human action within N minutes)
- Time-to-acknowledge (if it was acked at all)
- Correlated with actual incidents (did a P0/P1 occur within 1 hour of this alert?)

Build a classification matrix:

| Class | Definition | Action |
|---|---|---|
| **Actionable** | Correlated with incident OR requires human response | Keep, tune thresholds |
| **Noisy-but-real** | Real condition, but fires too often / too sensitively | Convert to SLO burn rate or increase `for:` duration |
| **Autopilot** | Always auto-resolves, no human action | Delete or convert to a dashboard annotation |
| **Redundant** | Fires when another higher-severity alert for the same root cause also fires | Suppress via Alertmanager inhibit rules |
| **Orphaned** | Fires for services that no longer exist or were renamed | Delete immediately |

**Phase 2: Remediation (Weeks 2-4)**

Concrete changes for each class:
- **Autopilot alerts:** Delete them. Add a metric annotation instead so they appear as a "blip" on dashboards. No human should see these in their pager.
- **Noisy-but-real:** Migrate to multi-window burn rate. Extend `for:` duration from 1m to 5-15m. A condition that lasts 15 minutes is far more likely to need attention than one lasting 30 seconds.
- **Redundant:** Use Alertmanager `inhibit_rules` so that when `NodeDown` fires, it suppresses all pod-level alerts for pods on that node.
- **Threshold-based CPU/memory:** Replace with Kubernetes HPA (auto-scale instead of alert) for elasticity. Alert only on sustained resource exhaustion that HPA cannot fix.

**Phase 3: Measure & Prevent Regression (Ongoing)**

Track alerting health metrics in a Grafana dashboard visible to all engineers:

| Metric | Target |
|---|---|
| Alerts/day | < 20 |
| Auto-resolve rate | < 10% |
| Mean time to acknowledge | < 5 minutes |
| Alert-to-incident correlation | > 80% |
| Error budget burn rate (for SLO alerts) | Primary paging signal |

Make it painful to add noisy alerts: require a PR review for any new alert rule. The review checklist asks: "What is the action when this fires?" If the answer is "monitor it" — it's a dashboard item, not an alert.

---

## Section 3a: Production Canary — Prose Description

The production canary is managed by **Argo Rollouts** (see `kubernetes/manifests/rollout.yaml`). The flow after the manual approval gate in the staging pipeline:

1. `production-canary.yml` GitHub Actions workflow dispatches with the approved image tag.
2. The workflow patches the Argo Rollout's image tag via `kubectl argo rollouts set image`.
3. Argo Rollouts begins the canary: 10% of traffic routes to the new pods via weighted ALB target groups. 90% stays on the stable version.
4. After 2 minutes bake time, an `AnalysisRun` executes three Prometheus queries (error rate, p99 latency, Kafka consumer lag). If all pass, the rollout auto-advances to 50%.
5. Another analysis run at 50%. If it passes, the rollout completes to 100%.
6. If any analysis metric fails (error rate > 1%, p99 > 500ms, or Kafka lag > 10K and growing), Argo Rollouts automatically sets canary weight back to 0% and marks the rollout `Degraded`. The stable version continues serving 100% of traffic.

**Secret injection at runtime:**

Secrets are never in YAML files or environment variables with static values. The flow is:

```
AWS Secrets Manager (source of truth)
    ↓
External Secrets Operator (cluster-side controller)
    ↓ watches for ExternalSecret CR
    ↓ fetches secret, creates/updates Kubernetes Secret
Kubernetes Secret
    ↓ mounted by pod via envFrom.secretRef
Application reads env vars at startup
```

The `ExternalSecret` CR specifies the AWS secret path and the Kubernetes secret name. The ESO controller uses IRSA to authenticate to Secrets Manager without any static credentials. Secret rotation is handled by rotating the value in Secrets Manager; ESO syncs the Kubernetes Secret within its polling interval (default 1h, configurable). Pods pick up the new secret on the next restart — for rolling rotation without downtime, a `reloader` sidecar (Stakater Reloader) watches for Secret changes and triggers a rolling restart.

---

## Section 3b: Internal Developer Platform (IDP)

### Goal

Product engineers can provision isolated environments (databases, queues, caches) for feature testing without waiting for the DevOps team, while staying within security guardrails and cost limits.

### Architecture

**Layer 1 — Self-service portal (Backstage or internal tooling):**

Engineers go to an internal portal and fill a form: "I need: PostgreSQL 15 (small), Redis 7, SQS queue. Environment name: feature-payment-v2. TTL: 5 days."

**Layer 2 — Terraform module catalogue:**

A curated library of pre-approved Terraform modules covers all permitted resource types: `rds-ephemeral`, `elasticache-ephemeral`, `sqs-queue`, `s3-bucket-isolated`. These modules encode all security guardrails:
- RDS instances are always in private/intra subnets with no public access
- Encryption at rest with a per-environment KMS key
- Security groups only allow ingress from the namespace's pod CIDR
- Instance sizes are bounded: only approved sizes (t3.medium, t3.large) are permitted — larger sizes require a DevOps approval workflow

**Layer 3 — Cost governance (OPA/Atlantis):**

Every IDP-provisioned resource is tagged `provisioned-by: idp`, `env-ttl: 2025-06-01`, `cost-owner: {team}`, `feature-branch: {branch-name}`. An OPA policy enforces: the estimated monthly cost of a single feature environment cannot exceed $500 (checked by calling the AWS Pricing API during the Terraform plan step). Requests above the threshold route to a Slack approval flow.

**Layer 4 — Auto-cleanup:**

A Lambda function runs hourly and queries AWS Resource Groups Tagging API for all resources tagged `provisioned-by: idp`. For each resource, it compares `env-ttl` to the current date. If expired:
1. Posts a 24-hour warning to the owning team's Slack channel
2. If not extended after 24 hours: runs `terraform destroy` on the environment workspace

Engineers can extend TTL via the portal (max 2 extensions of 3 days each before requiring a DevOps review). This hard stop prevents "temporary" environments living for months.

**Security guardrails:**

- Environments are provisioned in an isolated AWS account (`clevertap-ephemeral`) — not the staging or prod account. Blast radius is contained.
- The `TerraformIDPRole` in the ephemeral account has explicit Deny SCPs preventing it from modifying IAM roles, security group rules affecting shared VPCs, or touching any resource not tagged with `provisioned-by: idp`.
- All data in ephemeral environments is synthetic — a CI step populates the RDS with seed data; production data can never be copied to ephemeral environments (enforced by IAM deny on `rds:RestoreDBInstance` from prod snapshots in the ephemeral account).

---

## Section 4a: 90-Day Cost Reduction Plan

**Target:** $105–126K/month reduction on $420K/month bill (~25–30%)

### Week 1–2: Quick Wins

| Initiative | Est. Savings | Effort | Risk |
|---|---|---|---|
| Delete unattached EBS volumes, unused EIPs, idle NAT GWs in non-prod | $8K/mo | Low | Low |
| S3 lifecycle policies: move objects > 30d to IA, > 90d to Glacier | $15K/mo | Low | Low |
| Right-size immediately over-provisioned RDS (check CPU/mem utilisation — target 70% avg) | $10K/mo | Medium | Low (blue/green resize) |
| Turn off non-prod EKS node groups overnight + weekends (scale to 0 via KEDA/cron) | $12K/mo | Low | Low (dev/staging only) |
| **Quick win total** | **~$45K/mo** | | |

### Month 1–2: Right-Sizing & Commitments

**Spot instances:** Shift 60% of EKS application workloads to Spot (already architected in the module — just tune the desired counts). Spot is 70% cheaper than On-Demand for the same instance type. Conservative estimate at 40% of total EC2 spend moving to Spot: ~$18K/mo saving.

**Savings Plans vs. Reserved Instances:**
- **Compute Savings Plans** for EKS EC2 nodes: apply to any EC2 instance regardless of type/size/region. Buy at 1-year no-upfront for flexibility (we are actively resizing). Estimated 30-40% discount on committed compute. Do NOT buy RIs for EKS nodes because we are actively changing instance types (mixing c5/m5 families) — Compute SPs flex across families.
- **RDS Reserved Instances (1-year, partial upfront):** RDS instance types are stable and predictable. RI gives 40% discount. Since we are right-sizing RDS first, buy RIs after the right-size is confirmed — not before.
- **ElastiCache Reserved Nodes:** Same logic as RDS. Stable, predictable, 35-40% discount with RIs.

Estimated commitment savings (after right-sizing): ~$30K/mo

### Month 2–3: Architectural Changes

**S3 Transfer Acceleration / cross-region data transfer:** Audit VPC Flow Logs to identify the top inter-region data transfer patterns. Event data replication between us-east-1 and ap-south-1 is likely the #1 data transfer cost driver. Options:
- Implement regional write-local: events are ingested and processed in the originating region, with only aggregated/summarised data replicated cross-region. This can reduce cross-region transfer by 60-80%.
- Enable S3 transfer acceleration only where latency matters; for bulk replication, use standard transfer with S3 Replication (cheaper than application-level copy).

Estimated: ~$20K/mo reduction in data transfer costs.

**CloudFront caching:** Static assets and campaign config payloads that are repeatedly fetched by devices can be cached at CloudFront edge. This reduces origin API traffic and data transfer. Estimated: ~$8K/mo.

**RDS Aurora Serverless v2** for non-prod: Staging databases that see bursty, unpredictable traffic are a poor fit for fixed-size RDS. Aurora Serverless v2 scales to zero when idle. Staging DB cost drops from fixed instance cost to actual usage.

**Total estimated savings: $45K + $30K + $28K ≈ $103–110K/month**, meeting the 25-30% target.

---

## Section 4b: FinOps Process Design

### Tagging Strategy

**Mandatory tags (enforced via SCP/Config Rules — resources without these tags are flagged and auto-stopped after 48h warning):**

| Tag | Values | Purpose |
|---|---|---|
| `Environment` | dev, staging, prod | Cost allocation by environment |
| `Team` | platform, data-infra, product-payment, etc. | Showback to team |
| `Service` | event-ingestion, campaign-delivery, etc. | Per-service cost |
| `CostCenter` | Jira team code | Finance allocation |
| `ManagedBy` | terraform, idp, manual | Identify click-ops |
| `provisioned-by` | terraform, idp | For auto-cleanup eligibility |

### Showback / Chargeback Model

**Phase 1 — Showback (first 90 days):** Use AWS Cost Explorer cost allocation tags to generate weekly per-team cost reports. Post these in team Slack channels automatically via a Lambda + Cost Explorer API job. No billing consequence yet — teams just see their spend.

**Phase 2 — Chargeback (after 90 days):** Cloud spend is allocated to team budgets in the annual planning process. Teams see their AWS spend as a line item in their engineering budget. This creates natural incentive: teams right-size their own services because overprovisioning now costs their team's budget.

**Tooling:** AWS Cost Explorer + Grafana cost dashboard (using the CloudWatch Billing metrics source). A custom Lambda generates a weekly "FinOps digest" posted to every team's Slack:

```
📊 Weekly Cloud Cost Digest — Team: Platform Engineering
This week: $12,340 (+8% vs last week)
Top spenders: EKS compute $7,200 | RDS $2,100 | Data transfer $1,900
Alerts: 2 untagged resources found (links)
Savings opportunity: 3 idle EBS volumes ($180/mo) → [Clean up]
```

### Alerting Thresholds

- **Team budget alert:** SNS email + Slack when team spend exceeds 80% of monthly budget (forecasted or actual)
- **Anomaly detection:** AWS Cost Anomaly Detection enabled for all services. Threshold: alert when 7-day rolling spend deviates > 20% from expected baseline
- **Untagged resource alert:** AWS Config rule fires hourly; resources missing mandatory tags after 48 hours are scheduled for termination (with Slack warning to team)
- **Savings plan coverage:** Alert when EC2/Fargate Savings Plan coverage drops below 70% (indicates new unplanned compute that should be committed)
