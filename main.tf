resource "aws_vpc" "main" {
    cidr_block = var.vpc_cidr_block
    enable_dns_support = true
    enable_dns_hostname = true

    tags = {
        Name = "terraform-course-vpc"
        Managed_by = "Terraform"
    }

}


resource "aws_instance" "main" {
  ami           = var.ami_id
  instance_type = "t3.micro"

  subnet_id = aws_subnet.main.id

  tags = {
    Name       = "terraform-course-ec2"
    Managed_by = "Terraform"
  }
}
