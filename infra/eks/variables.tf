variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "cluster_name" {
  type    = string
  default = "project3-eks"
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "node_instance_type" {
  type    = string
  default = "t3.small"
}

variable "node_desired_size" {
  type    = number
  default = 1
}

variable "alert_email" {
  description = "Email address for CloudWatch alarm notifications (leave empty to skip the subscription)"
  type        = string
  default     = ""
}
