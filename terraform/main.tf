provider "runpod" {
  # Authentication comes from RUNPOD_API_KEY; do not put it in HCL/state.
  base_url = var.runpod_base_url
}

locals {
  hf_token_ref     = "{{ RUNPOD_SECRET_${var.hf_secret_name} }}"
  vllm_api_key_ref = "{{ RUNPOD_SECRET_${var.vllm_secret_name} }}"

  # The official vLLM image already supplies the `vllm serve` entrypoint.
  vllm_args = join(" ", [
    "nota-ai/GLM-5.3-Flash-Nota-NVFP4",
    "--served-model-name glm-5.3-flash",
    "--host 0.0.0.0",
    "--port 8000",
    "--tensor-parallel-size 1",
    "--max-model-len 1048576",
    "--kv-cache-dtype fp8",
    "--enable-chunked-prefill",
    "--max-num-batched-tokens 8192",
    "--max-num-seqs 4",
    "--tool-call-parser glm47",
    "--reasoning-parser glm45",
    "--enable-auto-tool-choice",
    "--safetensors-load-strategy prefetch",
    "--gpu-memory-utilization 0.96",
    "--speculative-config '{\"method\":\"mtp\",\"num_speculative_tokens\":5}'"
  ])
}

resource "runpod_pod" "glm" {
  name        = var.pod_name
  machine_id  = var.machine_id
  image_name  = "vllm/vllm-openai:glm53-flash"
  gpu_count   = 1
  gpu_type_id = var.gpu_type_id
  cloud_type  = "SECURE"

  container_disk_in_gb = 50
  network_volume_id    = var.network_volume_id
  volume_mount_path    = "/workspace"

  ports     = "8000/http,22/tcp"
  start_ssh = true

  env = {
    HF_HOME                     = "/workspace/huggingface"
    HF_HUB_CACHE                = "/workspace/huggingface/hub"
    HF_HUB_OFFLINE              = "1"
    HF_XET_HIGH_PERFORMANCE     = "1"
    CUDA_VISIBLE_DEVICES        = "0"
    VLLM_ENGINE_READY_TIMEOUT_S = "3600"
    VLLM_CACHE_ROOT             = "/workspace/vllm-cache"
    HF_TOKEN                    = local.hf_token_ref
    VLLM_API_KEY                = local.vllm_api_key_ref
  }

  docker_args = local.vllm_args
}
