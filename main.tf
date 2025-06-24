terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
    tfmigrate = {
      source  = "hashicorp/tfmigrate"
      version = "~> 1.1"
    }
  }
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region = "ap-south-1" # Mumbai region
}

provider "tfmigrate" {
  hostname = "app.terraform.io"

}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "tls_private_key" "tfe_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ⚠️ Removed local_file block — Terraform Cloud cannot write to your local system

resource "aws_key_pair" "tfe_key" {
  key_name   = "tfe_key_${random_id.suffix.hex}"
  public_key = tls_private_key.tfe_key.public_key_openssh
}

resource "aws_security_group" "tfe_sg" {
  name        = "tfe_security_group_${random_id.suffix.hex}"
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

resource "aws_instance" "ubuntu_openssl_4_tfe" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.medium"
  key_name               = aws_key_pair.tfe_key.key_name
  associate_public_ip_address = true
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

              sudo systemctl enable docker
              sudo systemctl start docker
              sudo usermod -aG docker ubuntu

              sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              sudo chmod +x /usr/local/bin/docker-compose
              docker-compose --version >> /home/ubuntu/docker_compose_version.txt
              EOF

  tags = {
    Name = "ubuntu_openssl_4_tfe"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
}

output "instance_public_id" {
  value = aws_instance.ubuntu_openssl_4_tfe.public_ip
}
