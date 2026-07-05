data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true # cost saving for a demo cluster

  # required for EKS to discover subnets for load balancers
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = {
    Project = "project-3-eks"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      min_size       = 1
      max_size       = 2
      desired_size   = var.node_desired_size
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"
    }
  }

  # demo cluster — the applying user administers it directly
  enable_cluster_creator_admin_permissions = true

  tags = {
    Project = "project-3-eks"
  }
}

# -------------------------------------------------------------------
# RDS PostgreSQL — replaces the in-cluster Postgres StatefulSet with a
# managed database, matching how a production setup would run this.
# -------------------------------------------------------------------

resource "random_password" "db" {
  length  = 20
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.cluster_name}-db"
  subnet_ids = module.vpc.private_subnets

  tags = {
    Project = "project-3-eks"
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.cluster_name}-rds-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Postgres from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project = "project-3-eks"
  }
}

resource "aws_db_instance" "postgres" {
  identifier     = "${var.cluster_name}-db"
  engine         = "postgres"
  engine_version = "16.9"
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = "gitopsdemo"
  username = "gitopsdemo"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az                = false # single-AZ for demo cost; set true for real prod HA
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = {
    Project = "project-3-eks"
  }
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.address
}
