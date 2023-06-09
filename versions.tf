terraform {
  # required_version = "~> 0.12.24"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "5.1.0"
    }
    template = "~> 2.1.2"
  }
}