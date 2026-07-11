# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# etcd backup storage (ADR-0018 decisions 1 & 3, #316).
#
# A dedicated S3 bucket with versioning + object-lock (WORM) + lifecycle
# expiration, written by a dedicated cloud user whose S3 policy deliberately
# has NO s3:DeleteObject — a compromised backup credential can add history
# but never erase it. Deletion happens only via the lifecycle policy.
#
# Object-lock gotchas (verified against provider docs):
#   - must be enabled at bucket CREATION; cannot be added or removed later
#   - changing/removing the object_lock block forces bucket REPLACEMENT
#     (destroys all objects) — never touch it casually
#   - per-region availability is not documented by OVH; this apply is the
#     empirical verification (same approach as state locking in #278)
#
# Retention model: object-lock governance P7D (no deletion/overwrite for
# 7 days, covering the compromised-credential window) + lifecycle expiration
# at 14 days (~56 snapshots at the 6h cadence, a few GB at most). The
# off-provider GFS copy (#317) carries the long retention.

resource "ovh_cloud_project_storage" "talos_backup" {
  count = var.talos_backup_enabled ? 1 : 0

  service_name = var.ovh_cloud_project_id
  region_name  = upper(var.talos_backup_s3_region)
  name         = var.talos_backup_s3_bucket

  versioning = {
    status = "enabled" # required by object-lock
  }

  encryption = {
    sse_algorithm = "AES256"
  }

  object_lock = {
    status = "enabled"
    rule = {
      mode   = "governance"
      period = "P7D"
    }
  }
}

resource "ovh_cloud_project_storage_object_bucket_lifecycle_configuration" "talos_backup" {
  count = var.talos_backup_enabled ? 1 : 0

  service_name   = var.ovh_cloud_project_id
  region_name    = upper(var.talos_backup_s3_region)
  container_name = ovh_cloud_project_storage.talos_backup[0].name

  rules = [
    {
      id     = "expire-etcd-snapshots"
      status = "enabled"
      filter = {
        prefix = ""
      }
      expiration = {
        # After the P7D object-lock window lapses. NOTE: with versioning on,
        # expiration creates delete markers; noncurrent versions accumulate
        # slowly (MB-scale objects) — revisit alongside #317's GFS work.
        days = 14
      }
    }
  ]
}

# Dedicated write identity: its S3 policy is the entire S3-API grant, and it
# omits s3:DeleteObject (and every bucket-management action) on purpose.
# GetObject/List are included so the in-cluster verify CronJob can read the
# latest snapshot with the same credential.
resource "ovh_cloud_project_user" "talos_backup" {
  count = var.talos_backup_enabled ? 1 : 0

  service_name = var.ovh_cloud_project_id
  description  = "talos-backup-writer"
  role_name    = "objectstore_operator"
}

resource "ovh_cloud_project_user_s3_policy" "talos_backup" {
  count = var.talos_backup_enabled ? 1 : 0

  service_name = var.ovh_cloud_project_id
  user_id      = ovh_cloud_project_user.talos_backup[0].id

  policy = jsonencode({
    Statement = [
      {
        Sid    = "TalosBackupWriteNoDelete"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListMultipartUploadParts",
          "s3:ListBucketMultipartUploads",
          "s3:AbortMultipartUpload",
        ]
        Resource = [
          "arn:aws:s3:::${var.talos_backup_s3_bucket}",
          "arn:aws:s3:::${var.talos_backup_s3_bucket}/*",
        ]
      }
    ]
  })
}

resource "ovh_cloud_project_user_s3_credential" "talos_backup" {
  count = var.talos_backup_enabled ? 1 : 0

  service_name = var.ovh_cloud_project_id
  user_id      = ovh_cloud_project_user.talos_backup[0].id
}
