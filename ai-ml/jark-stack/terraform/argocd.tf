#---------------------------------------------------------------
# Argo CD Application (GitOps) — syncs the dogbooth apps from the repo.
# Argo CD itself is installed by module.eks_blueprints_addons (see addons.tf).
#---------------------------------------------------------------
resource "kubectl_manifest" "dogbooth_application" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "dogbooth"
      namespace = "argocd"
      finalizers = [
        "resources-finalizer.argocd.argoproj.io"
      ]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_target_revision
        path           = var.gitops_path
      }
      destination = {
        server = "https://kubernetes.default.svc"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true"
        ]
      }
    }
  })

  # Argo CD (and its Application CRD) must exist first.
  depends_on = [module.eks_blueprints_addons]
}
