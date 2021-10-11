provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "demo_django_app"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  enable_vpn_gateway = false

  tags = {
    Terraform   = "true"
    Environment = "dev"
    project     = "demo_django_app"
  }
}

module "nlb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 6.0"

  name = "demo-django-app-nlb"

  load_balancer_type = "network"
  internal           = true

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  target_groups = [
    {
      name_prefix      = "pref-"
      backend_protocol = "TCP"
      backend_port     = 8000
      target_type      = "ip"
    }
  ]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "TCP"
      target_group_index = 0
    }
  ]

  tags = {
    Environment = "Test"
    Project     = "demo_django_app"
  }
}

module "nlb_sg" {
  source = "terraform-aws-modules/security-group/aws//modules/http-80"

  name                = "demo_django_app_nlb_sg"
  description         = "Security group for demo_django_app nlb with HTTP ports open to anyone"
  vpc_id              = module.vpc.vpc_id
  ingress_cidr_blocks = ["0.0.0.0/0"]
  tags = {
    Project = "demo_django_app"
  }
}

module "ecs_cluster" {
  source = "terraform-aws-modules/ecs/aws"

  name = "demo-django-app"

  container_insights = false

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy = [
    {
      capacity_provider = "FARGATE_SPOT"
    }
  ]

  tags = {
    Environment = "dev"
    Project     = "demo_django_app"
  }
}

module "api_gateway" {
  source = "terraform-aws-modules/apigateway-v2/aws"

  name          = "demo-http-vpc-links"
  description   = "HTTP API Gateway with VPC links"
  protocol_type = "HTTP"

  cors_configuration = {
    allow_headers = ["content-type", "x-amz-date", "authorization", "x-api-key", "x-amz-security-token", "x-amz-user-agent"]
    allow_methods = ["*"]
    allow_origins = ["*"]
  }

  create_api_domain_name = false

  integrations = {
    "ANY /{proxy+}" = {
      connection_type    = "VPC_LINK"
      vpc_link           = "my-vpc"
      integration_uri    = module.nlb.http_tcp_listener_arns[0]
      integration_type   = "HTTP_PROXY"
      integration_method = "ANY"
    }
  }

  vpc_links = {
    my-vpc = {
      name               = "example-v2"
      security_group_ids = [module.api_gateway_security_group.security_group_id]
      subnet_ids         = module.vpc.private_subnets
    }
  }

  tags = {
    Name = "private-api"
  }
}

module "api_gateway_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "api-gateway-sg-v2"
  description = "API Gateway group for example usage"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["http-80-tcp"]

  egress_rules = ["all-all"]
}

module "fargate_container_sg" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "demo_django_app_container_sg"
  description = "Security group for demo_django_app nlb with HTTP ports open to anyone"
  vpc_id      = module.vpc.vpc_id
  ingress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 8000
      protocol    = "tcp"
      description = "Ingress from external clients"
      cidr_blocks = "0.0.0.0/0"
  }]


  egress_rules = ["all-all"]
  tags = {
    Project = "demo_django_app"
  }
}

module "db" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 3.0"

  name           = "demo-django-app-db"
  engine         = "aurora-postgresql"
  engine_version = "13.3"
  instance_type  = "db.t4g.medium"
  database_name = "demo_django_app"

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  replica_count           = 1
  allowed_security_groups = [module.fargate_container_sg.security_group_id]
  allowed_cidr_blocks     = module.vpc.private_subnets_cidr_blocks

  storage_encrypted   = true
  apply_immediately   = true
  monitoring_interval = 10

  db_parameter_group_name         = "default.aurora-postgresql13"
  db_cluster_parameter_group_name = "default.aurora-postgresql13"

  enabled_cloudwatch_logs_exports = ["postgresql"]

  skip_final_snapshot = true

  tags = {
    Environment = "dev"
    Terraform   = "true"
    Project     = "demo_django_app"
  }
}

resource "aws_ecs_service" "demo_django_app" {
  name            = "demo_django_app"
  cluster         = module.ecs_cluster.ecs_cluster_id
  task_definition = aws_ecs_task_definition.service.arn
  desired_count   = 2

  //  enable_execute_command = true

  launch_type = "FARGATE"

  load_balancer {
    target_group_arn = module.nlb.target_group_arns[0]
    container_name   = "django"
    container_port   = 8000
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [module.fargate_container_sg.security_group_id]
    assign_public_ip = false
  }
}

resource "aws_ecs_task_definition" "service" {
  family                   = "demo_django_app"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  cpu                      = 256
  memory                   = 512
  container_definitions = jsonencode([
    {
      name  = "django"
      image = "${aws_ecr_repository.demo_app.repository_url}:latest"
      command : ["gunicorn", "-w", "3", "-b", ":8000", "demo_app.wsgi:application"],
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]
      healthcheck = {
        command     = ["true"]
        interval    = 5
        retries     = 10
        startPeriod = 5
        timeout     = 5
      }
      environment = [
        {
          "name": "RDS_DB_NAME",
          "value": module.db.this_rds_cluster_database_name
        },
        {
          "name": "RDS_USERNAME",
          "value": module.db.this_rds_cluster_master_username
        },
        {
          "name": "RDS_PASSWORD",
          "value": tostring(module.db.this_rds_cluster_master_password)
        },
        {
          "name": "RDS_HOSTNAME",
          "value": module.db.this_rds_cluster_endpoint
        },
        {
          "name": "RDS_PORT",
          "value": tostring(module.db.this_rds_cluster_port)
        }
      ],
      mountPoints = []
      volumesFrom = []
    }
  ])
  network_mode = "awsvpc"
  tags = {
    Project = "demo_django_app"
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "django_task_execution_role_policy"

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      },
    ]
  })

  inline_policy {
    name = "AmazonECSTaskExecutionRolePolicy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Action = [
            "ecr:GetAuthorizationToken",
            "ecr:BatchCheckLayerAvailability",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage",
            "logs:CreateLogStream",
            "logs:PugLogEvents"
          ]
          Effect   = "Allow"
          Resource = "*"
      }]
    })

  }

  tags = {
    Project = "demo_django_app"
  }
}

resource "aws_iam_role" "ecs_role" {
  name = "ecs_role_policy"
  path = "/"
  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ecs.amazonaws.com"
        }
      },
    ]
  })

  inline_policy {
    name = "AllowECSToManageResources"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Action = [
            "ec2:AttachNetworkInterface",
            "ec2:CreateNetworkInterface",
            "ec2:CreateNetworkInterfacePermission",
            "ec2:DeleteNetworkInterface",
            "ec2:DeleteNetworkInterfacePermission",
            "ec2:Describe*",
            "ec2:DetachNetworkInterface",
            "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
            "elasticloadbalancing:DeregisterTargets",
            "elasticloadbalancing:Describe*",
            "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
            "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
          ]
          Effect   = "Allow"
          Resource = "*"
      }]
    })

  }

  tags = {
    Project = "demo_django_app"
  }
}

resource "aws_ecr_repository" "demo_app" {
  name                 = "demo_django_app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "local_file" "update_service" {
  filename = "../src/update_service.sh"
  content  = <<EOF
#!/bin/bash

aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.us-east-1.amazonaws.com
docker build -t demo_django_app .
docker tag demo_django_app:latest ${aws_ecr_repository.demo_app.repository_url}:latest
docker push ${aws_ecr_repository.demo_app.repository_url}:latest

ecs-deploy -r us-east-1 -c demo-django-app -n demo_django_app -i ${aws_ecr_repository.demo_app.repository_url}:latest -t 600
EOF

}
