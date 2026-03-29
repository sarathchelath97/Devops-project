# CleverTap Staff DevOps Engineer – Technical Assessment

**Candidate Submission** | Role: Staff DevOps Engineer | Company: CleverTap

---

## Repository Structure

```
clevertap-devops-assessment/
├── terraform/
│   ├── modules/
│   │   ├── eks/                    # Reusable EKS cluster module (Section 1a)
│   │   └── vpc/                    # Multi-region VPC module (Section 1a)
│   └── environments/
│       ├── dev/
│       ├── staging/
│       └── prod/
│           ├── us-east-1/
│           └── ap-south-1/
├── kubernetes/
│   ├── manifests/                  # Argo Rollouts canary config (Section 3a)
│   └── helm/                       # Helm values for environments
├── ci-cd/
│   └── .github/workflows/
│       ├── pr.yml                  # PR pipeline (Section 3a)
│       └── staging.yml             # Staging promotion pipeline (Section 3a)
├── runbooks/
│   └── pod-crashlooping.md         # KubePodCrashLooping runbook (Section 2b)
└── docs/
    └── assessment-written.md       # Written answers (Sections 1b, 1c, 2a, 2c, 3b, 4a, 4b)
```

## Sections Covered

| Section | Topic | Files |
|---------|-------|-------|
| 1a | Terraform EKS + VPC Modules | `terraform/modules/eks/`, `terraform/modules/vpc/` |
| 1b | State & Drift Management | `docs/assessment-written.md` |
| 1c | EU Data Residency Architecture | `docs/assessment-written.md` |
| 2a | Observability Stack Design | `docs/assessment-written.md` |
| 2b | CrashLooping Runbook | `runbooks/pod-crashlooping.md` |
| 2c | Alert Noise Reduction | `docs/assessment-written.md` |
| 3a | CI/CD Pipeline (PR + Staging) | `ci-cd/.github/workflows/` |
| 3b | Internal Developer Platform | `docs/assessment-written.md` |
| 4a | 90-Day Cost Reduction Plan | `docs/assessment-written.md` |
| 4b | FinOps Process Design | `docs/assessment-written.md` |
