terraform {
  backend "local" {
    path = "terraform.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1" # Mumbai region
}

# Generate a random subdomain name
resource "random_pet" "subdomain" {
  length    = 1
  separator = "-"
}

# Retrieve the Hosted Zone ID
data "aws_route53_zone" "selected" {
  name = "harshit-chaudhary.sbx.hashidemos.io"
}

# Generate and save the PEM file
resource "tls_private_key" "tf_migrate_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key" {
  content         = tls_private_key.tf_migrate_key.private_key_pem
  filename        = "${path.module}/tfe_key.pem"
  file_permission = "0400"
}

# Create an AWS Key Pair
resource "aws_key_pair" "tf_migrate_key" {
  key_name   = "tf_migrate_key"
  public_key = tls_private_key.tf_migrate_key.public_key_openssh
}

# Create a Security Group
resource "aws_security_group" "tfe_sg" {
  name        = "tf_migrate_security_group"
  description = "Allow SSH, HTTP, and HTTPS access"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Allocate an Elastic IP
resource "aws_eip" "tf_migrate_eip" {
  vpc = true
}

# Create an EC2 Instance
resource "aws_instance" "ubuntu_openssl_4_tfe" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.medium"
  key_name               = aws_key_pair.tf_migrate_key.key_name
  vpc_security_group_ids = [aws_security_group.tfe_sg.id]

  root_block_device {
    volume_size = 24
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              sudo apt-get update -y
              sudo apt-get install -y openssl
              openssl version >> /home/ubuntu/openssl_version.txt

              # Install Docker
              sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
              curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
              echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu focal stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
              sudo apt-get update -y
              sudo apt-get install -y docker-ce docker-ce-cli containerd.io

              # Enable Docker service
              sudo systemctl enable docker
              sudo systemctl start docker

              # Add ubuntu user to docker group
              sudo usermod -aG docker ubuntu

              # Install Docker Compose
              sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              sudo chmod +x /usr/local/bin/docker-compose
              docker-compose --version >> /home/ubuntu/docker_compose_version.txt
              EOF

  tags = {
    Name = "ubuntu_openssl_4_tfe"
  }
}

# Associate the Elastic IP with the EC2 Instance
resource "aws_eip_association" "tf_migrate_eip_assoc" {
  instance_id   = aws_instance.ubuntu_openssl_4_tfe.id
  allocation_id = aws_eip.tf_migrate_eip.id
}

# Create a Route 53 A Record
resource "aws_route53_record" "tf_migrate_record" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = "${random_pet.subdomain.id}.harshit-chaudhary.sbx.hashidemos.io"
  type    = "A"
  ttl     = 300
  records = [aws_eip.tf_migrate_eip.public_ip]
}

# Retrieve the latest Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
}

# Output the instance's public IP and DNS name
output "instance_public_ip" {
  value = aws_eip.tf_migrate_eip.public_ip
}

output "instance_dns_name" {
  value = aws_route53_record.tf_migrate_record.fqdn
}
