#!/usr/bin/env bash
#
# Strategic teardown for the JARK stack.
#
# Order matters: Kubernetes objects that provision AWS resources (LoadBalancers,
# Karpenter EC2 instances, EBS volumes) must be removed *before* the cluster/VPC
# so their controllers can release the underlying AWS resources. We then run
# `terraform destroy` in dependency order, and finally sweep any leaked,
# tag-identified AWS resources directly — so cleanup still works even when the
# Terraform state is incomplete or lost.
#
# Usage:
#   ./cleanup.sh [--yes] [--skip-terraform] [--dry-run]
#
# Env overrides:
#   CLUSTER_NAME (default: jark-stack)
#   REGION       (default: us-east-1)
#
set -uo pipefail

# --------------------------------------------------------------------------- #
# Configuration & flags
# --------------------------------------------------------------------------- #
CLUSTER_NAME="${CLUSTER_NAME:-jark-stack}"
REGION="${REGION:-us-east-1}"
APP_DOMAIN="${APP_DOMAIN:-claudiq.com}"   # app records + ACM cert to remove (zone itself is kept)
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TF_DIR/../../.." && pwd)"

AUTO_APPROVE="false"
SKIP_TERRAFORM="false"
DRY_RUN="false"

for arg in "$@"; do
  case "$arg" in
    --yes|-y)         AUTO_APPROVE="true" ;;
    --skip-terraform) SKIP_TERRAFORM="true" ;;
    --dry-run)        DRY_RUN="true" ;;
    *) echo "Unknown argument: $arg"; exit 2 ;;
  esac
done

export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; NC=$'\033[0m'
log()   { echo "${BLU}[cleanup]${NC} $*"; }
ok()    { echo "${GRN}[ ok ]${NC} $*"; }
warn()  { echo "${YLW}[warn]${NC} $*"; }
err()   { echo "${RED}[fail]${NC} $*"; }
phase() { echo; echo "${BLU}=======================================================${NC}"; echo "${BLU}>> $*${NC}"; echo "${BLU}=======================================================${NC}"; }

# run a destructive command (honours --dry-run); never aborts the script
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    ${YLW}DRY-RUN${NC} $*"
  else
    echo "    + $*"
    "$@" || warn "command failed (continuing): $*"
  fi
}

aws_q() { aws "$@" 2>/dev/null; }  # read-only query, swallow errors

confirm() {
  [[ "$AUTO_APPROVE" == "true" || "$DRY_RUN" == "true" ]] && return 0
  echo
  warn "This will PERMANENTLY DELETE the '${CLUSTER_NAME}' cluster and all"
  warn "associated AWS resources in ${REGION} (account $(aws_q sts get-caller-identity --query Account --output text))."
  read -r -p "Type the cluster name to confirm: " reply
  [[ "$reply" == "$CLUSTER_NAME" ]] || { err "Confirmation did not match. Aborting."; exit 1; }
}

# Wait until no resources of a given tag-query remain (best-effort, bounded).
wait_gone() {
  local desc="$1"; shift
  [[ "$DRY_RUN" == "true" ]] && { echo "    ${YLW}DRY-RUN${NC} (skip wait for $desc)"; return 0; }
  local timeout="${WAIT_TIMEOUT:-300}" elapsed=0
  while :; do
    local n; n="$("$@" | wc -w | tr -d ' ')"
    [[ "$n" == "0" ]] && { ok "$desc fully released"; return 0; }
    (( elapsed >= timeout )) && { warn "$desc still has $n item(s) after ${timeout}s — continuing"; return 0; }
    log "waiting for $desc to release ($n remaining, ${elapsed}s)…"
    sleep 15; elapsed=$((elapsed + 15))
  done
}

# --------------------------------------------------------------------------- #
# Tag-query primitives (used by both the wait loops and the sweep)
# --------------------------------------------------------------------------- #
lbs_for_cluster()  { aws_q resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing:loadbalancer --tag-filters "Key=elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" --query 'ResourceTagMappingList[].ResourceARN' --output text; }
tgs_for_cluster()  { aws_q resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing:targetgroup  --tag-filters "Key=elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" --query 'ResourceTagMappingList[].ResourceARN' --output text; }
karpenter_nodes()  { aws_q ec2 describe-instances --filters "Name=tag:karpenter.sh/nodepool,Values=*" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text; }

cluster_exists() { aws_q eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.status' --output text | grep -q .; }

# --------------------------------------------------------------------------- #
# PHASE 0 — preflight
# --------------------------------------------------------------------------- #
phase "Phase 0: Preflight"
command -v aws >/dev/null       || { err "aws CLI not found"; exit 1; }
command -v terraform >/dev/null || { err "terraform not found"; exit 1; }
aws_q sts get-caller-identity --query Arn --output text | grep -q . || { err "AWS credentials not configured"; exit 1; }
ok "AWS identity: $(aws_q sts get-caller-identity --query Arn --output text)"
log "Cluster: ${CLUSTER_NAME}   Region: ${REGION}   Dry-run: ${DRY_RUN}"
confirm

KUBE_OK="false"
if cluster_exists; then
  if [[ "$DRY_RUN" == "false" ]]; then
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1 \
      && kubectl cluster-info >/dev/null 2>&1 && KUBE_OK="true"
  fi
  [[ "$KUBE_OK" == "true" ]] && ok "Cluster reachable — will drain Kubernetes resources first" \
                             || warn "Cluster exists but kubectl not reachable — skipping in-cluster drain"
else
  warn "Cluster '${CLUSTER_NAME}' not found — skipping Kubernetes drain, going straight to sweep"
fi

# --------------------------------------------------------------------------- #
# PHASE 1 — drain Kubernetes-owned AWS resources
# --------------------------------------------------------------------------- #
phase "Phase 1: Drain Kubernetes-owned AWS resources"
if [[ "$KUBE_OK" == "true" ]]; then
  # 1a. Delete the Argo CD Application first — its finalizer cascades to prune the
  #     synced resources, and removing it stops self-heal from re-creating them.
  run kubectl -n argocd delete application dogbooth --ignore-not-found --timeout=120s
  # Fallback: delete the app manifests + namespaces directly (in case Argo CD is gone).
  run kubectl delete -f "${REPO_ROOT}/deploy/apps/streamlit.yaml"   --ignore-not-found --timeout=120s
  run kubectl delete -f "${REPO_ROOT}/deploy/apps/ray-service.yaml" --ignore-not-found --timeout=120s
  run kubectl delete namespace dogbooth dogbooth-app --ignore-not-found --timeout=120s

  # 1b. Let Karpenter terminate the instances it launched (delete NodePools/NodeClaims).
  run kubectl delete nodeclaims --all --ignore-not-found --timeout=120s
  run kubectl delete nodepools  --all --ignore-not-found --timeout=120s
  run kubectl delete ec2nodeclasses --all --ignore-not-found --timeout=120s

  # 1c. Delete every LoadBalancer Service so the AWS LB Controller deletes the ELBs
  #     while it is still running (otherwise the ELBs leak).
  while read -r ns svc; do
    [[ -z "${svc:-}" ]] && continue
    run kubectl delete svc "$svc" -n "$ns" --ignore-not-found --timeout=120s
  done < <(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null)

  # 1d. Wait for the controllers to actually release the AWS resources.
  wait_gone "ELB load balancers"     lbs_for_cluster
  wait_gone "Karpenter EC2 instances" karpenter_nodes
else
  warn "Skipping in-cluster drain"
fi

# --------------------------------------------------------------------------- #
# PHASE 2 — terraform destroy (dependency order)
# --------------------------------------------------------------------------- #
phase "Phase 2: Terraform destroy"
if [[ "$SKIP_TERRAFORM" == "true" ]]; then
  warn "--skip-terraform set; skipping terraform destroy (sweep only)"
else
  pushd "$TF_DIR" >/dev/null
  # Init against the S3 remote state when configured (CI), else local state.
  if [ -n "${TF_STATE_BUCKET:-}" ]; then
    cat > backend_ci_override.tf <<'EOF'
terraform {
  backend "s3" {}
}
EOF
    run terraform init -upgrade -input=false \
      -backend-config="bucket=${TF_STATE_BUCKET}" \
      -backend-config="key=${TF_STATE_KEY:-jark-stack/terraform.tfstate}" \
      -backend-config="region=${TF_STATE_REGION:-$REGION}" \
      ${TF_LOCK_TABLE:+-backend-config=dynamodb_table=$TF_LOCK_TABLE}
  else
    run terraform init -upgrade -input=false
  fi
  for target in module.data_addons module.eks_blueprints_addons module.eks module.vpc; do
    log "destroying $target …"
    run terraform destroy -target="$target" -auto-approve -input=false
  done
  log "final sweep destroy (catch anything remaining in state) …"
  run terraform destroy -auto-approve -input=false
  popd >/dev/null
fi

# --------------------------------------------------------------------------- #
# PHASE 3 — resilient tag-based AWS sweep (works even with broken/empty state)
# --------------------------------------------------------------------------- #
phase "Phase 3: AWS sweep (leaked / untracked resources)"

log "Karpenter EC2 instances…"
for id in $(karpenter_nodes); do run aws ec2 terminate-instances --instance-ids "$id"; done

log "ELBv2 load balancers…"
for arn in $(lbs_for_cluster); do run aws elbv2 delete-load-balancer --load-balancer-arn "$arn"; done
wait_gone "ELB load balancers" lbs_for_cluster

log "Target groups…"
for arn in $(tgs_for_cluster); do run aws elbv2 delete-target-group --target-group-arn "$arn"; done

log "Available EBS volumes tagged for the cluster…"
for vol in $(aws_q ec2 describe-volumes --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" "Name=status,Values=available" --query 'Volumes[].VolumeId' --output text); do
  run aws ec2 delete-volume --volume-id "$vol"
done

log "Detaching/deleting leftover available ENIs in cluster security groups…"
SG_IDS="$(aws_q ec2 describe-security-groups --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" "Name=group-name,Values=*${CLUSTER_NAME}*" --query 'SecurityGroups[].GroupId' --output text)"
for eni in $(aws_q ec2 describe-network-interfaces --filters "Name=status,Values=available" "Name=group-id,Values=${SG_IDS// /,}" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text); do
  run aws ec2 delete-network-interface --network-interface-id "$eni"
done

log "Security groups (k8s/Karpenter managed)…"
sweep_sgs() { aws_q ec2 describe-security-groups --filters "$1" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text; }
SG_SWEEP="$(echo $(sweep_sgs "Name=tag:elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}") $(sweep_sgs "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}") | tr ' ' '\n' | sort -u)"
# Pass 1: revoke all ingress/egress rules so cross-referencing SGs can be deleted.
for sg in $SG_SWEEP; do
  ingress="$(aws_q ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissions' --output json)"
  egress="$(aws_q ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissionsEgress' --output json)"
  [[ "$ingress" != "[]" && -n "$ingress" ]] && run aws ec2 revoke-security-group-ingress --group-id "$sg" --ip-permissions "$ingress"
  [[ "$egress"  != "[]" && -n "$egress"  ]] && run aws ec2 revoke-security-group-egress  --group-id "$sg" --ip-permissions "$egress"
done
# Pass 2: delete the now-ruleless security groups.
for sg in $SG_SWEEP; do run aws ec2 delete-security-group --group-id "$sg"; done

log "EKS-managed KMS alias…"
if aws_q kms describe-key --key-id "alias/eks/${CLUSTER_NAME}" --query 'KeyMetadata.KeyId' --output text | grep -q .; then
  KEY_ID="$(aws_q kms describe-key --key-id "alias/eks/${CLUSTER_NAME}" --query 'KeyMetadata.KeyId' --output text)"
  run aws kms delete-alias --alias-name "alias/eks/${CLUSTER_NAME}"
  run aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7
fi

log "CloudWatch log groups…"
for lg in $(aws_q logs describe-log-groups --log-group-name-prefix "/aws/eks/${CLUSTER_NAME}" --query 'logGroups[].logGroupName' --output text); do
  run aws logs delete-log-group --log-group-name "$lg"
done

log "Route 53 app records for ${APP_DOMAIN} (ALB aliases + ACM validation + ExternalDNS; the hosted zone is kept)…"
ZID="$(aws_q route53 list-hosted-zones-by-name --dns-name "${APP_DOMAIN}." --query "HostedZones[?Name=='${APP_DOMAIN}.'].Id" --output text | sed 's#/hostedzone/##')"
if [ -n "$ZID" ]; then
  aws_q route53 list-resource-record-sets --hosted-zone-id "$ZID" --output json \
    | jq -c '.ResourceRecordSets[]
        | select(
            (.Type=="A" and .AliasTarget!=null)
            or (.Type=="CNAME" and (.Name|startswith("_")))
            or (.Type=="TXT" and ((.ResourceRecords // [])|map(.Value)|join(" ")|test("external-dns")))
          )' 2>/dev/null > /tmp/r53_app_records.jsonl || true
  while read -r rr; do
    [ -z "$rr" ] && continue
    echo "    deleting $(echo "$rr" | jq -r '.Type+" "+.Name')"
    jq -n --argjson r "$rr" '{Changes:[{Action:"DELETE",ResourceRecordSet:$r}]}' > /tmp/r53_del.json
    run aws route53 change-resource-record-sets --hosted-zone-id "$ZID" --change-batch file:///tmp/r53_del.json
  done < /tmp/r53_app_records.jsonl
fi

log "ACM certificate(s) for ${APP_DOMAIN} (deleted after the ALB is gone)…"
for arn in $(aws_q acm list-certificates --region "$REGION" --query "CertificateSummaryList[?DomainName=='${APP_DOMAIN}'].CertificateArn" --output text); do
  run aws acm delete-certificate --region "$REGION" --certificate-arn "$arn"
done

# --------------------------------------------------------------------------- #
# PHASE 4 — verification report
# --------------------------------------------------------------------------- #
phase "Phase 4: Verification"
remaining=0
report() { local n; n="$(echo "$1" | wc -w | tr -d ' ')"; [[ "$n" != "0" ]] && { warn "$2: $n remaining -> $1"; remaining=$((remaining+n)); } || ok "$2: clean"; }

report "$(cluster_exists && echo "$CLUSTER_NAME" || true)" "EKS cluster"
report "$(lbs_for_cluster)"  "Load balancers"
report "$(tgs_for_cluster)"  "Target groups"
report "$(karpenter_nodes)"  "Karpenter instances"
report "$(aws_q ec2 describe-security-groups --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" --query 'SecurityGroups[].GroupId' --output text)" "Cluster security groups"

# IAM roles are free but cannot be safely pattern-deleted automatically. Report
# any left behind (e.g. from interrupted applies) for manual review/deletion.
LEFTOVER_ROLES="$(aws_q iam list-roles --query "Roles[?starts_with(RoleName, '${CLUSTER_NAME}') || contains(RoleName, 'eks-node-group')].RoleName" --output text)"
[[ -n "$LEFTOVER_ROLES" ]] && warn "IAM roles to review manually: $LEFTOVER_ROLES" || ok "IAM roles: clean"

echo
if [[ "$remaining" == "0" ]]; then
  ok "Cleanup complete — no tracked resources remain."
else
  warn "Cleanup finished with ${remaining} resource(s) still reported."
  warn "These often clear on a second run once dependencies detach. Re-run: ./cleanup.sh --skip-terraform --yes"
fi
