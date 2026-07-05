terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket         = "project3-eks-tfstate-990957157371"
    key            = "eks/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "project3-eks-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
}
