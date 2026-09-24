variable "runpod_base_url" {
  description = "RunPod REST API v2 base URL used by the official provider."
  type        = string
  default     = "https://api.runpod.io/v2"
}

variable "machine_id" {
  description = "Secure Cloud machine ID selected for the B300 deployment. Discover/verify before apply."
  type        = string
}

variable "network_volume_id" {
  description = "Existing persistent Network Volume containing /workspace/huggingface and /workspace/vllm-cache."
  type        = string
}

variable "gpu_type_id" {
  description = "RunPod GPU type ID. Verify with current RunPod inventory before apply."
  type        = string
  default     = "NVIDIA B300 SXM6 AC"
}

variable "pod_name" {
  type    = string
  default = "glm-5.3-flash-b300"
}

variable "hf_secret_name" {
  type    = string
  default = "HF_TOKEN"
}

variable "vllm_secret_name" {
  type    = string
  default = "VLLM_API_KEY"
}
