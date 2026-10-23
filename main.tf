resorce "aws_vpc" "main" {
    cidr_block = "192.168.0.0/16
    enable_dns_support = true
    enable_dns_hostname = true

    tags = {
        Name = "terraform-course"
        Managed_by = "Terraform"
    }

}