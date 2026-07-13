To perform exactly these actions, run the following command to apply:
    terraform apply "tfplan.destroy"
Review the destroy plan above. Type DESTROY to continue:
DESTROY
```
aws_route_table_association.private[1]: Destroying... [id=rtbassoc-0b18566d3e7ce4f90]
aws_lb_target_group_attachment.web: Destroying... [id=arn:aws:elasticloadbalancing:us-east-1:406207085797:targetgroup/cloud-team-playbook-dev-tg/e879c1b0dc4419a9,i-070d99430f28a9272,80]
aws_vpc_security_group_ingress_rule.alb_7777: Destroying... [id=sgr-063bb73f40253ad57]
aws_vpc_security_group_ingress_rule.web_from_alb: Destroying... [id=sgr-075021d69772ba45b]
aws_route_table_association.private[0]: Destroying... [id=rtbassoc-02c547a56398b2a3b]
aws_vpc_security_group_egress_rule.web_all_out: Destroying... [id=sgr-0300447ddc8642ed9]
aws_s3_bucket_versioning.site_assets: Destroying... [id=cloud-team-playbook-dev-site-assets-406207085797-cd9d7a2f]
aws_s3_bucket_public_access_block.site_assets: Destroying... [id=cloud-team-playbook-dev-site-assets-406207085797-cd9d7a2f]
aws_s3_bucket_server_side_encryption_configuration.site_assets: Destroying... [id=cloud-team-playbook-dev-site-assets-406207085797-cd9d7a2f]
aws_lb_listener.app_7777: Destroying... [id=arn:aws:elasticloadbalancing:us-east-1:406207085797:listener/app/cloud-team-playbook-dev-alb/7dc05c1fc33e3524/da278b72b574196a]
aws_lb_target_group_attachment.web: Destruction complete after 0s
aws_route_table_association.public[1]: Destroying... [id=rtbassoc-0c973a2615a4d1993]
aws_lb_listener.app_7777: Destruction complete after 0s
aws_instance.command: Destroying... [id=i-00b5797eff732e22c]
aws_s3_bucket_server_side_encryption_configuration.site_assets: Destruction complete after 0s
aws_route.public_default: Destroying... [id=r-rtb-0b6b51a6da6a3d8a01080289494]
aws_s3_bucket_public_access_block.site_assets: Destruction complete after 0s
aws_route.private_default: Destroying... [id=r-rtb-01a66cf9f2f46dc651080289494]
aws_vpc_security_group_ingress_rule.alb_7777: Destruction complete after 0s
aws_route_table_association.private[0]: Destruction complete after 0s
aws_vpc_security_group_egress_rule.command_all_out: Destroying... [id=sgr-0f413763745d82c84]
aws_vpc_security_group_egress_rule.alb_all_out: Destroying... [id=sgr-0f56403a36b9abfd6]
aws_vpc_security_group_egress_rule.web_all_out: Destruction complete after 0s
aws_route_table_association.public[0]: Destroying... [id=rtbassoc-0e5b1f5c879263c68]
aws_route_table_association.private[1]: Destruction complete after 0s
aws_instance.web: Destroying... [id=i-070d99430f28a9272]
aws_vpc_security_group_ingress_rule.web_from_alb: Destruction complete after 0s
aws_lb_target_group.web: Destroying... [id=arn:aws:elasticloadbalancing:us-east-1:406207085797:targetgroup/cloud-team-playbook-dev-tg/e879c1b0dc4419a9]
aws_lb_target_group.web: Destruction complete after 1s
aws_lb.app: Destroying... [id=arn:aws:elasticloadbalancing:us-east-1:406207085797:loadbalancer/app/cloud-team-playbook-dev-alb/7dc05c1fc33e3524]
aws_route_table_association.public[1]: Destruction complete after 1s
aws_s3_bucket_versioning.site_assets: Destruction complete after 1s
aws_vpc_security_group_egress_rule.command_all_out: Destruction complete after 1s
aws_route_table_association.public[0]: Destruction complete after 1s
aws_route.public_default: Destruction complete after 1s
aws_route_table.public: Destroying... [id=rtb-0b6b51a6da6a3d8a0]
aws_vpc_security_group_egress_rule.alb_all_out: Destruction complete after 1s
aws_route.private_default: Destruction complete after 1s
aws_nat_gateway.main: Destroying... [id=nat-0bcdea104da0eba05]
aws_route_table.private: Destroying... [id=rtb-01a66cf9f2f46dc65]
aws_route_table.public: Destruction complete after 0s
aws_route_table.private: Destruction complete after 0s
aws_instance.command: Still destroying... [id=i-00b5797eff732e22c, 00m10s elapsed]
aws_instance.web: Still destroying... [id=i-070d99430f28a9272, 00m10s elapsed]
aws_lb.app: Still destroying... [id=arn:aws:elasticloadbalancing:us-east-1:...team-playbook-dev-alb/7dc05c1fc33e3524, 00m10s elapsed]
aws_nat_gateway.main: Still destroying... [id=nat-0bcdea104da0eba05, 00m10s elapsed]
aws_lb.app: Destruction complete after 16s
aws_security_group.alb: Destroying... [id=sg-0b7cfe4c6821ff8f4]
aws_instance.command: Still destroying... [id=i-00b5797eff732e22c, 00m20s elapsed]
aws_instance.web: Still destroying... [id=i-070d99430f28a9272, 00m20s elapsed]
aws_nat_gateway.main: Still destroying... [id=nat-0bcdea104da0eba05, 00m20s elapsed]
aws_security_group.alb: Destruction complete after 5s
aws_instance.command: Still destroying... [id=i-00b5797eff732e22c, 00m30s elapsed]
aws_instance.web: Still destroying... [id=i-070d99430f28a9272, 00m30s elapsed]
aws_nat_gateway.main: Still destroying... [id=nat-0bcdea104da0eba05, 00m30s elapsed]
aws_instance.command: Still destroying... [id=i-00b5797eff732e22c, 00m40s elapsed]
aws_instance.web: Still destroying... [id=i-070d99430f28a9272, 00m40s elapsed]
aws_instance.command: Destruction complete after 40s
aws_security_group.command: Destroying... [id=sg-068506d0715182478]
aws_instance.web: Destruction complete after 41s
aws_iam_role_policy_attachment.ssm_core: Destroying... [id=cloud-team-playbook-dev-ec2-ssm-s3-role/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore]
aws_iam_role_policy_attachment.site_assets_read: Destroying... [id=cloud-team-playbook-dev-ec2-ssm-s3-role/arn:aws:iam::406207085797:policy/cloud-team-playbook-dev-site-assets-read]
aws_iam_instance_profile.ec2: Destroying... [id=cloud-team-playbook-dev-ec2-profile]
aws_subnet.private[0]: Destroying... [id=subnet-072b6941d1f489fe4]
aws_subnet.private[1]: Destroying... [id=subnet-0ad099319ec5001a1]
aws_s3_object.tailwind_css: Destroying... [id=cloud-team-playbook-dev-site-assets-406207085797-cd9d7a2f/assets/tailwind-local.css]
aws_security_group.web: Destroying... [id=sg-0c498c5a0c90fb6d4]
aws_s3_object.index_html: Destroying... [id=cloud-team-playbook-dev-site-assets-406207085797-cd9d7a2f/index.html]
aws_iam_role_policy_attachment.site_assets_read: Destruction complete after 0s
aws_iam_policy.site_assets_read: Destroying... [id=arn:aws:iam::406207085797:policy/cloud-team-playbook-dev-site-assets-read]
aws_nat_gateway.main: Still destroying... [id=nat-0bcdea104da0eba05, 00m40s elapsed]
aws_iam_role_policy_attachment.ssm_core: Destruction complete after 0s
aws_s3_object.tailwind_css: Destruction complete after 0s
aws_s3_object.index_html: Destruction complete after 0s
aws_iam_instance_profile.ec2: Destruction complete after 0s
aws_iam_role.ec2_ssm_s3: Destroying... [id=cloud-team-playbook-dev-ec2-ssm-s3-role]
aws_iam_policy.site_assets_read: Destruction complete after 0s
aws_s3_bucket.site_assets: Destroying... [id=cloud-team-playbook-dev-site-assets-406207085797-cd9d7a2f]
aws_security_group.command: Destruction complete after 1s
aws_iam_role.ec2_ssm_s3: Destruction complete after 0s
aws_subnet.private[0]: Destruction complete after 0s
aws_s3_bucket.site_assets: Destruction complete after 0s
random_id.suffix: Destroying... [id=zZ16Lw]
random_id.suffix: Destruction complete after 0s
aws_subnet.private[1]: Destruction complete after 0s
aws_security_group.web: Destruction complete after 0s
aws_nat_gateway.main: Still destroying... [id=nat-0bcdea104da0eba05, 00m50s elapsed]
aws_nat_gateway.main: Still destroying... [id=nat-0bcdea104da0eba05, 01m00s elapsed]
aws_nat_gateway.main: Destruction complete after 1m1s
aws_internet_gateway.main: Destroying... [id=igw-0ddcbb065298c43ac]
aws_eip.nat: Destroying... [id=eipalloc-0bdbe1bb9e5df33de]
aws_subnet.public[1]: Destroying... [id=subnet-0c737df40bd7e9954]
aws_subnet.public[0]: Destroying... [id=subnet-093e9c98eb970719b]
aws_internet_gateway.main: Destruction complete after 0s
aws_subnet.public[1]: Destruction complete after 0s
aws_subnet.public[0]: Destruction complete after 1s
aws_vpc.main: Destroying... [id=vpc-0a9ce9f71e7d9c732]
aws_eip.nat: Destruction complete after 1s
aws_vpc.main: Destruction complete after 0s

Apply complete! Resources: 0 added, 0 changed, 42 destroyed.
```