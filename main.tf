
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "main-vpc"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  # No public IPs - this instance never needs to be reached from, or reach, the internet.
  map_public_ip_on_launch = false

  tags = {
    Name = "private-subnet"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "private-rt"
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.${var.aws_region}.s3"
  route_table_ids = [aws_route_table.private.id]

  tags = {
    Name = "s3-gateway-endpoint"
  }
}


resource "aws_security_group" "ec2" {
  name        = "ec2-vpc-only-sg"
  description = "Allow inbound traffic only from within the VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "All traffic from within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ec2-vpc-only-sg"
  }
}


resource "aws_iam_role" "ec2" {
  name = "ec2-s3-writer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ec2_s3_write" {
  name = "ec2-s3-write-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject"]
      Resource = "${aws_s3_bucket.logs.arn}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "ec2-s3-writer-profile"
  role = aws_iam_role.ec2.name
}


resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "logs" {
  bucket = "ec2-time-logs-${random_id.bucket_suffix.hex}"
}

data "aws_iam_policy_document" "logs_bucket_policy" {
  statement {
    sid     = "DenyAccessNotFromVpcEndpoint"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.logs.arn,
      "${aws_s3_bucket.logs.arn}/*",
    ]

    condition {
      test     = "StringNotEquals"
      variable = "aws:sourceVpce"
      values   = [aws_vpc_endpoint.s3.id]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs_bucket_policy.json
}


data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  user_data = <<-EOF
    #!/bin/bash
    set -eux

    cat > /usr/local/bin/save_time.sh << 'SCRIPT'
    #!/bin/bash
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    echo "Saved at $${TIMESTAMP}" > /tmp/saved_at.txt
    aws s3 cp /tmp/saved_at.txt s3://${aws_s3_bucket.logs.bucket}/saved_at.txt --region ${var.aws_region}
    SCRIPT

    chmod +x /usr/local/bin/save_time.sh

    echo "* * * * * root /usr/local/bin/save_time.sh" > /etc/cron.d/save_time
    chmod 644 /etc/cron.d/save_time

    /usr/local/bin/save_time.sh
  EOF
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  associate_public_ip_address = false

  user_data = local.user_data

  tags = {
    Name = "ec2-vpc-only"
  }

  depends_on = [aws_vpc_endpoint.s3]
}


output "instance_id" {
  value = aws_instance.app.id
}

output "instance_private_ip" {
  value = aws_instance.app.private_ip
}

output "bucket_name" {
  value = aws_s3_bucket.logs.bucket
}

output "vpc_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}
