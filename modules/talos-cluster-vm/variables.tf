# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

variable "cluster_name" {
  description = "Name of the Kubernetes cluster (also the OpenStack resource prefix)."
  type        = string
}

variable "control_plane_count" {
  description = "Number of control-plane VMs (odd number for etcd quorum; 3 recommended)."
  type        = number
  default     = 3

  validation {
    condition     = var.control_plane_count % 2 == 1 && var.control_plane_count >= 1
    error_message = "control_plane_count must be an odd number >= 1 (etcd quorum)."
  }
}

variable "worker_count" {
  description = "Number of worker VMs."
  type        = number
  default     = 0
}

variable "flavor_name" {
  description = "OpenStack flavor for cluster VMs (e.g. d2-4 = 2 vCPU / 4 GB — Talos CP recommended minimum)."
  type        = string
  default     = "d2-4"
}

variable "image_id" {
  description = "Glance image ID of a pre-uploaded Talos openstack qcow2 (from the Image Factory openstack schematic). The Factory ships raw.xz for openstack, so Glance web-download cannot build a bootable image directly — upload the converted qcow2 out-of-band (see scripts/upload-talos-image.sh) and pass its ID here."
  type        = string
}

variable "external_network_name" {
  description = "OVH Public Cloud external (public) network name."
  type        = string
  default     = "Ext-Net"
}

variable "talos_version" {
  description = "Talos version (e.g. v1.13.5) — must match the uploaded image."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the machine configuration (bare semver, e.g. 1.36.2)."
  type        = string
}

variable "pod_network_cidr" {
  description = "Pod network CIDR (Cilium)."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_network_cidr" {
  description = "Kubernetes service network CIDR."
  type        = string
  default     = "10.96.0.0/12"
}

variable "allowed_api_cidrs" {
  description = "CIDRs allowed to reach the Talos (50000) and Kubernetes (6443) APIs from outside the cluster (e.g. the operator/runner public IP /32). Node-to-node is always allowed within the cluster security group."
  type        = list(string)
  default     = []
}

variable "cilium_cli_image" {
  description = "Cilium CLI image (repo:tag@digest) for the install Job."
  type        = string
  default     = "quay.io/cilium/cilium-cli-ci:v0.18.2@sha256:503324c1fc7027e0daeb251ca2d4ad6b42d73c6be7a89cb8057cce8e59e50393"
}

variable "cilium_version" {
  description = "Cilium chart version installed by the install Job."
  type        = string
  default     = "1.17.0"
}
