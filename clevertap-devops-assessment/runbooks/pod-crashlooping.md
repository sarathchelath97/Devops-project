# Runbook: KubePodCrashLooping — event-ingestion-service

**Severity:** P1 (Critical — Kafka feed at risk)
**Service:** `event-ingestion-service` | Namespace: `event-ingestion`
**Audience:** On-call engineers (6+ months experience)
**Escalation owner:** Platform Engineering On-Call

---

## Context

The `event-ingestion-service` receives inbound campaign events and publishes them to a Kafka topic (`campaign-events-prod`). A sustained CrashLoop in this service can cause event loss, campaign delivery failure, and downstream consumer lag.

**Impact when down:**
- Campaign events dropped or delayed
- Kafka producer lag builds up
- Customer campaigns may fail to trigger

---

## 0. Acknowledge the Alert (< 2 minutes)

1. Acknowledge in PagerDuty / OpsGenie to stop escalation timer.
2. Join the `#incidents-p1` Slack channel and post:

```
🚨 Investigating KubePodCrashLooping for event-ingestion-service in prod.
Started: <timestamp>
On-call: @your-name
```

---

## 1. Initial Triage (target: resolve or escalate within 15 minutes)

### 1.1 Confirm scope

```bash
# Which pods are crashing?
kubectl get pods -n event-ingestion -l app=event-ingestion-service \
  --sort-by='.status.containerStatuses[0].restartCount'

# How many restarts and since when?
kubectl get events -n event-ingestion \
  --field-selector reason=BackOff \
  --sort-by='.lastTimestamp' | tail -20
```

**Expected output to note:**
- Number of affected pods
- Restart count and frequency
- Whether it's all pods (cluster-wide issue) or a subset (rolling issue)

### 1.2 Check current pod logs (last crash)

```bash
# Logs from the PREVIOUS crashed container (before current restart)
kubectl logs -n event-ingestion \
  -l app=event-ingestion-service \
  --previous \
  --tail=200

# If multiple pods affected, check a specific one:
POD=$(kubectl get pods -n event-ingestion -l app=event-ingestion-service \
  -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n event-ingestion $POD --previous --tail=200
```

**What to look for:**
| Log pattern | Likely cause |
|---|---|
| `OOMKilled` in describe | Memory limit too low or leak |
| `connection refused` / `dial tcp` | Dependency (Kafka, DB) unreachable |
| `panic:` / `fatal error:` | Application bug / bad deploy |
| `permission denied` | Missing IAM role or secret |
| `certificate expired` / `TLS handshake` | Cert rotation issue |
| `config map not found` | Missing/deleted ConfigMap |

### 1.3 Describe the pod

```bash
kubectl describe pod $POD -n event-ingestion
```

**Key fields to inspect:**
- `Last State`: exit code and reason
  - Exit 0 = graceful shutdown (not a crash — check liveness probe config)
  - Exit 1/2 = application error
  - Exit 137 = OOMKilled (SIGKILL)
  - Exit 139 = segfault
  - Exit 143 = SIGTERM not handled correctly
- `Events` section: scheduling failures, image pull errors, probe failures

### 1.4 Check upstream dependencies

```bash
# Is Kafka reachable from within the cluster?
kubectl run -it --rm debug --image=confluentinc/cp-kafka:7.5.0 \
  -n event-ingestion --restart=Never -- \
  kafka-topics --bootstrap-server kafka-brokers.kafka.svc.cluster.local:9092 --list

# Check Kafka consumer group lag
kubectl exec -it kafka-client -n kafka -- \
  kafka-consumer-groups.sh \
  --bootstrap-server kafka-brokers.kafka.svc.cluster.local:9092 \
  --describe --group event-ingestion-service
```

### 1.5 Check secrets and config

```bash
# Were secrets recently rotated? Check ESO sync status
kubectl get externalsecret event-ingestion-service-secrets \
  -n event-ingestion -o jsonpath='{.status.conditions}'

# Check ConfigMap exists and is not empty
kubectl get configmap event-ingestion-config -n event-ingestion -o yaml
```

---

## 2. Decision Tree

```
CrashLoop detected
│
├── Exit 137 (OOMKilled)?
│   └── YES → Go to §3.A: Scale-Out / Mem increase
│
├── Exit 1 + "connection refused" in logs?
│   └── Kafka down? → Escalate to Data Infra on-call
│   └── Secret missing/rotated? → Go to §3.C: Config Hotfix
│
├── All pods crashing after a recent deploy?
│   └── YES → Go to §3.B: Rollback
│
├── Only 1–2 pods crashing (others healthy)?
│   └── Node issue → cordon + drain the node (§3.D)
│   └── Transient → delete the pod, monitor
│
└── Unknown / can't diagnose in 10 min → Escalate (§4)
```

---

## 3. Remediation Actions

### 3.A — Scale-Out (for OOM or traffic spike)

```bash
# Temporarily increase memory limit (will trigger rolling restart)
kubectl set resources deployment/event-ingestion-service \
  -n event-ingestion \
  --limits=memory=2Gi \
  --requests=memory=1Gi

# Scale out horizontally to reduce per-pod load
kubectl scale deployment/event-ingestion-service \
  -n event-ingestion \
  --replicas=30

# Monitor recovery
kubectl rollout status deployment/event-ingestion-service -n event-ingestion
```

> ⚠️ **After stabilisation:** File a ticket to investigate the root cause of the OOM. Update HPA limits and Helm values in the next deployment cycle. Do NOT leave manually-patched resources — update IaC.

### 3.B — Rollback Last Deployment

```bash
# Check rollout history
kubectl rollout history deployment/event-ingestion-service -n event-ingestion

# Rollback to previous revision
kubectl rollout undo deployment/event-ingestion-service -n event-ingestion

# OR with Argo Rollouts
kubectl argo rollouts abort event-ingestion-service -n event-ingestion
kubectl argo rollouts undo event-ingestion-service -n event-ingestion

# Watch pods recover
watch kubectl get pods -n event-ingestion -l app=event-ingestion-service
```

> ⚠️ **Notify the deploying team immediately.** Block the failing image tag from being re-promoted.

### 3.C — Config / Secret Hotfix

```bash
# Force ESO to re-sync the secret
kubectl annotate externalsecret event-ingestion-service-secrets \
  -n event-ingestion \
  force-sync=$(date +%s) --overwrite

# If a ConfigMap needs manual patching (last resort):
kubectl edit configmap event-ingestion-config -n event-ingestion

# Restart pods to pick up new config
kubectl rollout restart deployment/event-ingestion-service -n event-ingestion
```

### 3.D — Node Isolation (single-node issue)

```bash
# Identify the bad node
kubectl get pods -n event-ingestion -o wide | grep CrashLoop

# Cordon (no new pods) and drain (evict existing)
NODE=<node-name>
kubectl cordon $NODE
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --force

# Monitor pods reschedule on healthy nodes
kubectl get pods -n event-ingestion -w
```

---

## 4. Escalation Criteria

Escalate to **Senior/Staff on-call** if:

- [ ] CrashLoop affecting > 50% of pods and not resolving after rollback
- [ ] Kafka lag > 1M messages and growing
- [ ] Unable to determine root cause within 15 minutes
- [ ] Issue persists after rollback + scale-out
- [ ] Dependency (Kafka, RDS) is the root cause — escalate to Data Infra team

### Escalation Path

| Who | When | Contact |
|-----|------|---------|
| Platform Engineering Senior | After 15 min no progress | PagerDuty: `platform-senior` |
| Data Infrastructure (Kafka) | Kafka identified as root cause | PagerDuty: `data-infra` |
| Engineering Manager | Customer impact > 15 min | Slack: `#incidents-leadership` |

---

## 5. Communication Templates

### Internal (Slack #incidents-p1)

```
🔴 INCIDENT UPDATE — <timestamp>

Service: event-ingestion-service (prod)
Status: [Investigating / Identified / Mitigating / Resolved]

What happened: <1-line description>
Impact: <N% pods crashing | Kafka lag at X | Customer campaigns affected Y/N>
Current action: <what you are doing right now>
ETA to resolution: <best estimate or "unknown — escalating">

Next update in: 10 minutes
On-call: @your-name
```

### Customer-Facing (via Status Page / CSM)

```
We are currently investigating elevated error rates affecting campaign event processing.
Our engineering team has identified the issue and is actively working on a resolution.
Campaign event delivery may be delayed during this window.
We will provide an update in 30 minutes.
```

> ✅ Do NOT mention infrastructure details, Kafka, or internal service names in customer communications.

---

## 6. Verification — Confirm Resolution

```bash
# All pods Running, 0 restarts in last 5 min
kubectl get pods -n event-ingestion -l app=event-ingestion-service

# Error rate back to baseline (< 0.1%)
# Check in Grafana: dashboard "event-ingestion-service / Production Overview"

# Kafka consumer lag draining
kubectl exec -it kafka-client -n kafka -- \
  kafka-consumer-groups.sh \
  --bootstrap-server kafka-brokers.kafka.svc.cluster.local:9092 \
  --describe --group event-ingestion-service

# Confirm health endpoint
kubectl port-forward svc/event-ingestion-service 8080:80 -n event-ingestion &
curl -s http://localhost:8080/health/ready
```

Post resolution in Slack:

```
✅ RESOLVED — <timestamp>
event-ingestion-service is stable. All pods running. Kafka lag normalising.
Duration: <X minutes>
Root cause: <brief>
Follow-up ticket: <link>
```

---

## 7. Post-Incident Review (PIR) — Required Artifacts

File a PIR within **24 hours** of P1 resolution. The PIR document must capture:

| Section | Content |
|---|---|
| **Incident summary** | One-paragraph description of what happened and customer impact |
| **Timeline** | Chronological log: alert fired → detected → investigated → mitigated → resolved. Include exact timestamps. |
| **Root cause** | The specific technical cause. Use "5 Whys" to get to the systemic root, not just the proximate cause. |
| **Contributing factors** | Monitoring gaps, deployment process gaps, missing safeguards |
| **Customer impact** | Which accounts affected, for how long, estimated events dropped |
| **Immediate remediation** | What was done to resolve the incident |
| **Action items** | Specific, assigned, time-bound tasks to prevent recurrence. Each must have: owner, due date, ticket link. |
| **What went well** | Detection speed, communication quality, tooling that worked |
| **What didn't go well** | Alerting gaps, runbook gaps, things that slowed you down |
| **Runbook updates** | Was this runbook useful? What needs to be added or changed? |

> **PIR is blameless.** The goal is system improvement, not attribution.
