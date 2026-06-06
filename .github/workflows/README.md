# JARK stack CI/CD

One pipeline (`pipeline.yml`) takes a change from PR → production, with security
scanning throughout and **GitOps delivery via Argo CD**.

```
PR:    validate-secrets ┐
       lint-test        ├─ build & scan app image (no push)     (no infra, no deploy)
       SAST (Semgrep)   │
       SCA/secrets ─────┤
       IaC (tfsec) ─────┘

main:  ┌ scans ─────────────► build & scan & push app image ─┐
       └ iac-scan ► terraform apply (gated) ─────────────────┼─► validate infra ready
                                                             ┘          │
                                          deploy via Argo CD (GitOps)  ◄┘
                                                     │
                                          deployment validation (rollout + smoke test)
                                                     │
                                              summary & alerts → END
```

## Stages (jobs)

| Job | When | Purpose |
| --- | --- | --- |
| `validate-secrets` | PR (warn) / main (fail) | Required secrets present |
| `lint-test` | PR + main | flake8, pytest, `terraform fmt`/`validate` |
| `sast` | PR + main | Semgrep → SARIF (Security tab) |
| `repo-scan` | PR + main | Trivy fs: vulns + secrets + misconfig → SARIF |
| `iac-scan` | PR + main | tfsec on the Terraform → SARIF |
| `build-app` | PR (build) / main (build+push) | Build `dogbooth-app`, **Trivy image scan**, push to Docker Hub on main |
| `infra` | main | `terraform apply` — **gated by the `production` environment** |
| `validate-infra` | main | Cluster `ACTIVE`, Argo CD up, Application present |
| `deploy` | main | GitOps: bump image tag in `deploy/apps`, commit, Argo CD syncs, wait Synced+Healthy |
| `deploy-validation` | main | `rollout status` + in-cluster smoke test (`/_stcore/health`) |
| `monitoring` | main | Run summary; fails if a critical stage failed |

Scans are **report-only** (results appear under the repo **Security** tab); flip
`exit-code: "1"` (Trivy) / add `--error` (Semgrep) to make them gate the build.

## GitOps (Argo CD)

- Argo CD is installed in-cluster by Terraform (`enable_argocd` in `addons.tf`).
- `ai-ml/jark-stack/terraform/argocd.tf` bootstraps an Argo CD **Application** named
  `dogbooth` that watches **`deploy/apps/`** on `main` (Kustomize), auto-sync + self-heal.
- `deploy/apps/` holds the deployable manifests (`streamlit.yaml`, `ray-service.yaml`,
  `kustomization.yaml`). The pipeline runs `kustomize edit set image …:<sha>` and
  commits — Argo CD syncs the new image. The image-tag commit is made with
  `GITHUB_TOKEN`, so it does **not** retrigger the pipeline.
- The Ray model service keeps its **upstream public image** (its code is unchanged
  and the 6 GB image isn't pushed). Only the Streamlit app is built/pushed.

## Required configuration (GitHub Actions secrets)

| Secret | Used by | Notes |
| --- | --- | --- |
| `AWS_ROLE_ARN` | infra, validate, deploy | OIDC role (Terraform + EKS) |
| `AWS_REGION` | infra, deploy | defaults to `us-east-1` if unset |
| `EKS_CLUSTER_NAME` | validate, deploy | e.g. `jark-stack` |
| `HUGGINGFACE_TOKEN` | infra | `TF_VAR_huggingface_token` |
| `TF_STATE_BUCKET` (+ `TF_STATE_KEY` / `TF_STATE_REGION` / `TF_LOCK_TABLE`) | infra | remote state (required for apply) |
| `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` | build-app, deploy | push the app image + pull secret |

Permissions used: `contents: write` (GitOps commit), `id-token: write` (OIDC),
`security-events: write` (SARIF).

## Teardown

See `ai-ml/jark-stack/terraform/cleanup.sh` — it deletes the Argo CD Application
first (so self-heal doesn't re-create the apps), then runs the strategic teardown.

## Notes / caveats

- **Approval gate:** the `production` environment (required reviewer) gates the
  `terraform apply` job. Approve it from the run's *Review deployments* prompt.
- **Branch protection:** the GitOps image-tag commit pushes to `main` with
  `GITHUB_TOKEN`; if `main` is protected against Actions pushes, allow the
  `github-actions` bot or use a deploy key/PAT.
- **First Argo CD sync** can take a minute; the pipeline forces a refresh.
