# outputs.tf
# What Terraform prints when it finishes. These values feed the next steps.

output "nifi_url" {
  description = "Open this in your browser"
  value       = "https://${local.nifi_fqdn}"
}

output "nifi_instance_id" {
  description = "Use this to open an SSM session: aws ssm start-session --target <this>"
  value       = aws_instance.nifi.id
}

output "kafka_instance_id" {
  description = "Use this to open an SSM session: aws ssm start-session --target <this>"
  value       = aws_instance.kafka.id
}

output "nifi_private_ip" {
  value = aws_instance.nifi.private_ip
}

output "kafka_private_ip" {
  value = aws_instance.kafka.private_ip
}

output "kafka_bootstrap_server" {
  description = "Paste this into the Python consumer"
  value       = "${aws_instance.kafka.private_ip}:9092"
}

output "s3_bucket_name" {
  description = "Drop your .txt files here"
  value       = aws_s3_bucket.nifi_data.id
}

output "ssm_transfer_bucket" {
  description = "REQUIRED by Ansible's aws_ssm connection plugin. Goes in ansible.cfg."
  value       = aws_s3_bucket.ssm_transfer.id
}

output "nifi_trigger_endpoint" {
  description = "The Python app POSTs here"
  value       = "http://${aws_instance.nifi.private_ip}:${var.nifi_http_listener_port}/trigger"
}

output "ssm_session_commands" {
  description = "How to get a shell -- no SSH, no keys, no open ports"
  value = {
    nifi  = "aws ssm start-session --target ${aws_instance.nifi.id}"
    kafka = "aws ssm start-session --target ${aws_instance.kafka.id}"
  }
}

output "next_steps" {
  value = <<-EOT

    ============================================================
      INFRASTRUCTURE IS UP.  ZERO SSH PORTS ARE OPEN.
    ============================================================

    0. Confirm both hosts registered with SSM (wait ~2 min after apply):

         aws ssm describe-instance-information \
           --query 'InstanceInformationList[].{ID:InstanceId,Ping:PingStatus}' \
           --output table

       BOTH must show PingStatus=Online before Ansible will work.
       If they don't, see docs/SSM-ONLY.md -> "Instance not showing up".

    1. Point Ansible at the transfer bucket:

         export ANSIBLE_AWS_SSM_BUCKET=${aws_s3_bucket.ssm_transfer.id}

    2. Configure the servers (over SSM -- no SSH):

         cd ansible && ansible-playbook site.yml

    3. Upload a test file:

         echo "hello from s3" > test.txt
         aws s3 cp test.txt s3://${aws_s3_bucket.nifi_data.id}/incoming/

    4. Open NiFi:  https://${local.nifi_fqdn}

    5. Trigger + consume:

         cd python-app
         python consumer.py --from-beginning &
         python trigger_nifi.py

    ------------------------------------------------------------
    Need a shell on a box?  There is no SSH. Use:

         aws ssm start-session --target ${aws_instance.nifi.id}
         aws ssm start-session --target ${aws_instance.kafka.id}
    ------------------------------------------------------------
  EOT
}
