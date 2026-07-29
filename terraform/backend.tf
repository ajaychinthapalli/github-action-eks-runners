terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket         = "github-action-runners-tfstate"
    key            = "eks/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "github-action-runners-tf-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = "us-east-2"
}
