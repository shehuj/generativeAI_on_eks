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

Config lives in **AWS Secrets Manager**, not in GitHub. The `infra`, `cd`, and
`ci` (build) jobs assume the OIDC role, then read one JSON secret at runtime (via
the `.github/actions/aws-config` composite action) and export each key as an env var.

### GitHub side (the bootstrap minimum)

The OIDC role *is* the AWS credential, so it must live in GitHub. Everything else
comes from Secrets Manager.

| Where | Name | Required? | Notes |
| --- | --- | --- | --- |
| **Secret** | `AWS_ROLE_ARN` | **yes** | IAM role assumed via GitHub OIDC. The only required GitHub setting. |
| Variable | `AWS_REGION` | no | Bootstrap region for auth + Secrets Manager. Defaults to `us-west-2`. |
| Variable | `CONFIG_SECRET_ID` | no | Secrets Manager secret id. Defaults to `jark-stack/config`. |

### AWS Secrets Manager side (the `jark-stack/config` secret)

A single JSON secret holds the rest. Any key present is exported to the job env:

```json
{
  "AWS_REGION":         "us-west-2",
  "EKS_CLUSTER_NAME":   "jark-stack",
  "HUGGINGFACE_TOKEN":  "hf_xxx",
  "TF_STATE_BUCKET":    "my-tf-state-bucket",
  "TF_STATE_KEY":       "jark-stack/terraform.tfstate",
  "TF_STATE_REGION":    "us-west-2",
  "TF_LOCK_TABLE":      "my-tf-lock-table",
  "DOCKERHUB_USERNAME": "myuser",
  "DOCKERHUB_TOKEN":    "dckr_pat_xxx"
}
```

`HUGGINGFACE_TOKEN` / `DOCKERHUB_TOKEN` are masked in logs. `TF_STATE_BUCKET` is
required for `apply` (without it, state is ephemeral — fine for `plan` only).
`DOCKERHUB_*` enable image push (`ci`) and image overrides (`cd`); omit them to
build without pushing and deploy the upstream public images.

## One-time setup

1. **OIDC trust** — create an IAM role trusting `token.actions.githubusercontent.com`,
   grant it Terraform/EKS permissions **plus** `secretsmanager:GetSecretValue` on the
   config secret, and put its ARN in the `AWS_ROLE_ARN` GitHub secret.
2. **Create the config secret:**
   ```bash
   aws secretsmanager create-secret \
     --name jark-stack/config --region us-west-2 \
     --secret-string '{"AWS_REGION":"us-west-2","EKS_CLUSTER_NAME":"jark-stack","HUGGINGFACE_TOKEN":"hf_xxx","TF_STATE_BUCKET":"my-tf-state-bucket"}'
   # update later with: aws secretsmanager put-secret-value --secret-id jark-stack/config --secret-string '{...}'
   ```
3. **Remote state** — create the S3 bucket (+ optional DynamoDB lock table) and put
   `TF_STATE_BUCKET`/`TF_STATE_KEY`/`TF_LOCK_TABLE` in the secret. The `infra` job
   injects a partial `backend "s3" {}` at runtime; local `terraform` keeps local state.
4. **Docker Hub** — create the `dogbooth-app` and `dogbooth` repos, and put
   `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` in the config secret (`ci` uses them to
   push, `cd` for image refs). If the repos are private, add an `imagePullSecret`
   in the cluster.
5. **Approval gate (optional)** — add reviewers to the `production` environment.

> **All three pipelines read from Secrets Manager.** `ci`'s build job pushes
> best-effort: if `AWS_ROLE_ARN` is absent (e.g. fork PRs) or the secret can't be
> read, it builds to cache only and still passes — so lint/test/build work on PRs
> without any AWS access.
