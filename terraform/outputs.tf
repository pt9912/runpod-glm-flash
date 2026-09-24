output "pod_id" {
  value = runpod_pod.glm.id
}

output "pod_name" {
  value = runpod_pod.glm.name
}

output "machine_id" {
  value = runpod_pod.glm.machine_id
}

output "runpod_proxy_url" {
  description = "vLLM endpoint through the RunPod HTTP proxy."
  value       = "https://${runpod_pod.glm.id}-8000.proxy.runpod.net"
}
