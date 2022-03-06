locals {
  instance_tag = "by-terraform"
}

terraform {
  backend "s3" {
    bucket         = "assignment-bucket-ttn"
    key            = "terraform.tfstate"
    region         = "ap-south-1" 
    dynamodb_table = "terraform-state-lock-dynamo"
  }
}

data "aws_vpc" "default" {
  filter {
    name   = "isDefault"
    values = ["true"]
  }
}

data "aws_subnets" "subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}


// Creating Key
resource "tls_private_key" "tls_key" {
  algorithm = "RSA"
}

// Generating Key-Value Pair
resource "aws_key_pair" "generated_key" {
  key_name   = "web-key"
  public_key = tls_private_key.tls_key.public_key_openssh

  tags = {
    Environment = "${local.instance_tag}-test"
  }

  depends_on = [
    tls_private_key.tls_key
  ]
}

### Private Key PEM File ###
resource "local_file" "key_file" {
  content  = tls_private_key.tls_key.private_key_pem
  filename = "web-key.pem"

  depends_on = [
    tls_private_key.tls_key
  ]
}

#### Security Group for Loadbalancer #####
resource "aws_security_group" "lb_sg" {
  name        = "loadbalancer-sg"
  description = "Security Group for Loadbalancer"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = "${local.instance_tag}-test"
  }
}

##### Security Group for Instances #####
resource "aws_security_group" "instance_sg" {
  name        = "instance-sg"
  description = "Security Group for Backed Instances"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.lb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = "${local.instance_tag}-test"
  }
}

##### Loadbalancer target group ####
resource "aws_lb_target_group" "web_tg" {
  name     = "web-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  tags = {
    Environment = "${local.instance_tag}-test"
  }
}

#### Creating Application Loadbalancer ####
resource "aws_lb" "application_lb" {
  name            = "web-loadbalancer"
  security_groups = [aws_security_group.lb_sg.id]
  subnets         = data.aws_subnets.subnets.ids

  tags = {
    Environment = "${local.instance_tag}-test"
  }
}

#### Listener for Loadbalancer ####
resource "aws_lb_listener" "lb_listener" {
  load_balancer_arn = aws_lb.application_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.web_tg.arn
    type             = "forward"
  }

  tags = {
    Environment = "${local.instance_tag}-test"
  }
}


resource "aws_instance" "custom_ec2" {
	ami  = var.ami_ec2
 	instance_type = var.instance_type_ec2
	key_name = aws_key_pair.generated_key.key_name
	user_data = <<EOF
		#!/bin/bash
 		sudo apt update
  		sudo apt install nginx
  		sudo ufw app list
 		sudo ufw allow 'Nginx HTTP'
 		sudo systemctl start nginx
  	EOF
   	tags = {
      Environment = "${local.instance_tag}-test"
    }
}

resource  "aws_ami_from_instance" "custom_ami" {
    name               = "nginx"
    source_instance_id = "${aws_instance.custom_ec2.id}"

  depends_on = [
      aws_instance.custom_ec2,
      ]
  tags = {
      Environment = "${local.instance_tag}-test"
    }
}

variable "ami_ec2" {
	type = string
        default = "ami-0851b76e8b1bce90b"
        description = "ami for ec2 instance from which custom ami has to be generated"
}

variable "instance_type_ec2" {
	type = string
        default = "t2.micro"
        description = "Instance type for the instance to build custom ami"
}

resource "aws_instance" "lb_backend" {
  ami             = aws_ami_from_instance.custom_ami.id
  instance_type   = "t2.micro"
  key_name        = aws_key_pair.generated_key.key_name
  security_groups = [aws_security_group.instance_sg.name]
  depends_on = [
      aws_ami_from_instance.custom_ami,
      ]
  tags = {
    Environment = "${local.instance_tag}-test"
  }
}

// Attach instance to target group
resource "aws_lb_target_group_attachment" "tg_instance_attach" {
  target_group_arn = aws_lb_target_group.web_tg.arn
  target_id        = aws_instance.lb_backend.id
  port             = 80
}


