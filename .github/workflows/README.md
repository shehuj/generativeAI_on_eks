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

Set these under **Settings → Secrets and variables → Actions**.

### Secrets

| Secret | Used by | Notes |
| --- | --- | --- |
| `AWS_ROLE_ARN` | infra, cd | IAM role assumed via GitHub OIDC. Needs Terraform/EKS permissions. |
| `HUGGINGFACE_TOKEN` | infra | Passed as `TF_VAR_huggingface_token`. |
| `DOCKERHUB_TOKEN` | ci | Docker Hub access token (Account Settings → Security → New Access Token). Required to push images. |

### Variables

| Variable | Used by | Example / default |
| --- | --- | --- |
| `AWS_REGION` | infra, cd | `us-west-2` |
| `EKS_CLUSTER_NAME` | cd | `jark-stack` |
| `DOCKERHUB_USERNAME` | ci, cd | Docker Hub user/org namespace, e.g. `myuser` — *optional*. Images are pushed/deployed as `docker.io/<DOCKERHUB_USERNAME>/dogbooth-app` and `.../dogbooth`. If unset, CI builds without pushing and CD deploys the upstream public images. |
| `TF_STATE_BUCKET` | infra | S3 bucket for remote state. **Required for `apply`** (local state is ephemeral in CI). |
| `TF_STATE_KEY` | infra | default `jark-stack/terraform.tfstate` |
| `TF_STATE_REGION` | infra | default = `AWS_REGION` |
| `TF_LOCK_TABLE` | infra | DynamoDB lock table (optional) |

## One-time setup

1. **OIDC trust** — create an IAM role trusting `token.actions.githubusercontent.com`
   and grant it Terraform/EKS access; put its ARN in `AWS_ROLE_ARN`.
2. **Remote state** — create the S3 bucket (and optional DynamoDB lock table) and
   set the `TF_STATE_*` variables. The `infra` job injects a partial `backend "s3" {}`
   at runtime, so local `terraform` keeps using local state.
3. **Docker Hub** — create the `dogbooth-app` and `dogbooth` repositories under your
   Docker Hub account/org, set `DOCKERHUB_USERNAME`, and add a `DOCKERHUB_TOKEN`
   access token. This enables image build/push (CI) and image overrides (CD).
   If the repos are **private**, also create an `imagePullSecret` in the cluster so
   the nodes can pull them (public repos need nothing).
4. **Approval gate (optional)** — add required reviewers to the `production`
   environment to gate `apply` and `cd`.
