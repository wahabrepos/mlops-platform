# mlops-platform

An MLOps / AI platform built as six connected projects in one monorepo: data platform, experiment tracking, scalable inference, GitOps CI/CD, drift observability, and responsible-AI governance on Go, .NET, Kubernetes,Terraform and Azure.

---

## Repository layout

```
mlops-platform/
├── README.md               ← you are here; the whole instruction set
├── Makefile                ← every repeated command
│
├── services/
│   ├── dataset-api/        P1  Go: catalog, versioning, quality gate
│   ├── drift-collector/    P5  Go: drift metrics → Prometheus
│   └── governance-api/     P6  .NET 8: model cards, promotion gates
├── tools/expctl/           P2  Go CLI: one-command experiment submission
│
├── pipelines/
│   ├── airflow/dags/       P1  dataset build + validate + freeze
│   ├── quality/            P1  expectation engine (GE-compatible)
│   └── training/           P2  training entrypoints logging to MLflow
│
├── models/
│   ├── serving/            P3  KServe InferenceServices (champion/contender)
│   └── alpr/triton-repo/   P3  Triton model repository
│
├── gitops/                 P4  Argo CD Applications, Kustomize overlays
├── policy/opa/             P4/P6  admission policy + tests
├── observability/          P5  Prometheus, alerts, Grafana provisioning
│
├── platform/
│   ├── local/              Docker Compose stack + kind config
│   ├── k8s/                Kubernetes manifests
│   └── terraform/
│       ├── modules/        resource-group, acr, storage, aks
│       └── envs/
│           ├── shared/     ← always on,  ~$5/month
│           └── burst/      ← ephemeral,  ~$0.22/hour
│
├── scripts/                seed data, kind bootstrap, canary promotion
└── docs/                   build plan, budget ledger, demo scripts
```

---