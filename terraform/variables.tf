variable "runpod_base_url" {
  description = "RunPod REST API v2 base URL used by the official provider."
  type        = string
  default     = "https://api.runpod.io/v2"
}

variable "machine_id" {
  description = "Secure Cloud machine ID selected for the B300 deployment. Must be in the same datacenter as the Network Volume. Discover/verify before apply."
  type        = string
}

variable "network_volume_id" {
  description = "Existing persistent Network Volume containing /workspace/huggingface and /workspace/vllm-cache. Volumes are bound to one datacenter; machine_id must be located there."
  type        = string
}

variable "offline_mode" {
  description = "true: HF_HUB_OFFLINE=1, the checkpoint must already be on the volume and no HF token is sent. false: downloads are allowed and the HF_TOKEN secret is injected (use for a fresh setup)."
  type        = bool
  default     = true
}

variable "gpu_type_id" {
  description = "RunPod GPU type ID. Verify with current RunPod inventory before apply."
  type        = string
  default     = "NVIDIA B300 SXM6 AC"
}

variable "container_disk_in_gb" {
  description = "Container disk size in GB. The model and caches live on the Network Volume, not here."
  type        = number
  default     = 50
}

variable "pod_name" {
  description = "Name of the RunPod Pod."
  type        = string
  default     = "glm-5.3-flash-b300"
}

variable "hf_secret_name" {
  description = "Name of the RunPod Secret holding the Hugging Face token (created in the console; case-sensitive). Only used when offline_mode = false."
  type        = string
  default     = "HF_TOKEN"
}

variable "vllm_secret_name" {
  description = "Name of the RunPod Secret holding the vLLM API key (created in the console; case-sensitive)."
  type        = string
  default     = "VLLM_API_KEY"
}
