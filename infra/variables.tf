variable "aws_region" {
  description = "AWS region where the temporary environment will run."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project name. Use lowercase letters, numbers, and hyphens."
  type        = string
}

variable "environment" {
  description = "Environment name, for example uat-1234567890."
  type        = string
}

variable "image_uri" {
  description = "Full ECR image URI to deploy."
  type        = string
}

variable "container_port" {
  description = "Port your container listens on."
  type        = number
  default     = 8080
}

variable "desired_count" {
  description = "Number of running tasks."
  type        = number
  default     = 1
}

variable "task_cpu" {
  description = "Fargate CPU units. 256 is 0.25 vCPU."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate memory in MiB."
  type        = number
  default     = 512
}

variable "health_check_path" {
  description = "HTTP path used by the load balancer health check."
  type        = string
  default     = "/"
}

variable "app_environment_variables" {
  description = "Plain environment variables passed to the container. Do not put secrets here."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Extra tags for AWS resources."
  type        = map(string)
  default     = {}
}

