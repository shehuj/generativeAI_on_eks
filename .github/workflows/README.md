# CI/CD for the JARK stack

Three independent pipelines, composed by one orchestrator.

| Workflow | File | Purpose | Runs on |
| --- | --- | --- | --- |
| **Deploy** (orchestrator) | `deploy.yml` | Runs `infra` + `ci` in parallel, then `cd` once **both** succeed | push to `main` (paths: `ai-ml/jark-stack/**`), manual |
| **Infra** | `infra.yml` | Terraform `plan`/`apply`/`destroy` for the EKS platform | PR (plan), called by `deploy`, manual |
| **CI** | `ci.yml` | Python lint/test, Terraform fmt/validate, build & push app images | PR, called by `deploy`, manual |
| **CD** | `cd.yml` | Deploy `dogbooth` RayService + Streamlit app to EKS | called by `deploy`, manual |

```
infra ─┐
       ├─► cd      (cd needs: [infra, ci])
ci ────┘
```

`infra` and `ci` have no dependency on each other, so they run concurrently. `cd`
declares `needs: [infra, ci]`, so it only starts after both finish — and its `if`
guard requires both to have *succeeded* (never on failure/cancel).

Each pipeline is also a normal reusable/standalone workflow, so you can run any of
them on their own (e.g. `infra` with `action: plan` on a PR, or `cd` via
**Run workflow** to roll out a specific image tag).

## Required configuration

All config is read from **GitHub Actions secrets**. Set them under
**Settings → Secrets and variables → Actions → Secrets** (not the Variables tab).
Reusable workflows receive them via `secrets: inherit` from `deploy.yml`.

| Secret | Used by | Required? | Notes |
| --- | --- | --- | --- |
| `AWS_ROLE_ARN` | infra, cd | **yes** | IAM role assumed via GitHub OIDC (Terraform + EKS perms). |
| `AWS_REGION` | infra, cd | no | Defaults to `us-east-1` if unset. |
| `EKS_CLUSTER_NAME` | cd | **yes (cd)** | e.g. `jark-stack`. |
| `HUGGINGFACE_TOKEN` | infra | no | Passed as `TF_VAR_huggingface_token`. |
| `TF_STATE_BUCKET` | infra | for `apply` | S3 remote-state bucket. Without it, state is ephemeral (fine for `plan`). |
| `TF_STATE_KEY` | infra | no | Defaults to `jark-stack/terraform.tfstate`. |
| `TF_STATE_REGION` | infra | no | Defaults to `AWS_REGION`. |
| `TF_LOCK_TABLE` | infra | no | DynamoDB lock table. |
| `DOCKERHUB_USERNAME` | ci, cd | no | Docker Hub namespace. Enables image push (ci) + image overrides (cd). |
| `DOCKERHUB_TOKEN` | ci | no | Docker Hub access token (push). |

> **Important:** store these as **Secrets**, not Variables. The workflows read
> `${{ secrets.* }}`; a value placed in the Variables tab won't be picked up
> (that was the original `AWS_REGION` failure).

Optional/absent secrets degrade gracefully: no `TF_STATE_BUCKET` → ephemeral
state (plan only); no `DOCKERHUB_*` → ci builds without pushing and cd deploys the
upstream public images.

## One-time setup

1. **OIDC trust** — create an IAM role trusting `token.actions.githubusercontent.com`,
   grant it Terraform/EKS permissions, and put its ARN in the `AWS_ROLE_ARN` secret.
2. **Remote state** — create the S3 bucket (+ optional DynamoDB lock table) and set
   `TF_STATE_BUCKET`/`TF_STATE_KEY`/`TF_LOCK_TABLE` secrets. The `infra` job injects
   a partial `backend "s3" {}` at runtime; local `terraform` keeps local state.
3. **Docker Hub** — create the `dogbooth-app` and `dogbooth` repos and set
   `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN`. If the repos are private, add an
   `imagePullSecret` in the cluster.
4. **Approval gate (optional)** — add reviewers to the `production` environment to
   gate `apply` and `cd`.
