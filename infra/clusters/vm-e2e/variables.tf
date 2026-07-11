# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

variable "cluster_name" {
  type    = string
  default = "talos-vm-e2e"
}
variable "control_plane_count" {
  type    = number
  default = 3
}
variable "worker_count" {
  type    = number
  default = 0
}
variable "flavor_name" {
  type    = string
  default = "d2-4"
}
variable "image_id" {
  type = string
}
variable "talos_version" {
  type    = string
  default = "v1.13.5"
}
variable "kubernetes_version" {
  type    = string
  default = "1.36.2"
}
variable "allowed_api_cidrs" {
  type    = list(string)
  default = []
}
