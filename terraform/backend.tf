terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
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
  region = var.region
}
provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_auth.cluster.token
}
data "aws_eks_auth" "cluster" {
  name = aws_eks_cluster.this.name
}
