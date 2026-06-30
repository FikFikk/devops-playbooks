output "argocd_server_url" {
  description = "Argo CD server URL"
  value       = "http://${helm_release.argocd.status[0].load_balancer[0].ingress[0].ip}"
}

output "argocd_admin_password" {
  description = "Argo CD admin password (stored in secret)"
  value       = "kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
  sensitive   = true
}

output "cleanup_cronjob_schedule" {
  description = "Cleanup CronJob schedule"
  value       = kubernetes_cron_job_v1.cleanup_reaper.spec[0].schedule
}
