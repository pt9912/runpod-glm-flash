variable "runpod_base_url" {
  description = "RunPod REST API v2 base URL used by the official provider."
  type        = string
  default     = "https://api.runpod.io/v2"
}

variable "machine_id" {
  description = "Optional Secure Cloud machine ID. null lets RunPod pick a machine with a free GPU of gpu_type_id (in the Network Volume's datacenter). Pinning a machine makes the apply fail whenever that machine is occupied."
  type        = string
  default     = null

  validation {
    condition     = var.machine_id == null || !startswith(coalesce(var.machine_id, ""), "REPLACE_WITH")
    error_message = "machine_id still contains the template placeholder. Set a real ID or leave it unset (null)."
  }
}

variable "network_volume_id" {
  description = "Existing persistent Network Volume containing /workspace/huggingface and /workspace/vllm-cache. Volumes are bound to one datacenter; machine_id must be located there."
  type        = string

  validation {
    condition     = length(trimspace(var.network_volume_id)) > 0 && !startswith(var.network_volume_id, "REPLACE_WITH")
    error_message = "network_volume_id must be the real ID of the existing Network Volume, not the template placeholder."
  }
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
