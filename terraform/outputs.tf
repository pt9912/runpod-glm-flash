output "pod_id" {
  value = runpod_pod.glm.id
}

output "pod_name" {
  value = runpod_pod.glm.name
}

output "runpod_proxy_url" {
  description = "vLLM endpoint through the RunPod HTTP proxy."
  value       = "https://${runpod_pod.glm.id}-${local.vllm_port}.proxy.runpod.net"
}
