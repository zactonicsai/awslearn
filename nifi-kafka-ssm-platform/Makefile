# Convenience targets. Everything runs over SSM -- no SSH anywhere.

TF      := terraform -chdir=terraform
BUCKET   = $(shell $(TF) output -raw ssm_transfer_bucket 2>/dev/null)
NIFI_URL = $(shell $(TF) output -raw nifi_url 2>/dev/null)

.PHONY: help init plan apply ansible deploy verify ssm-list outputs fmt destroy

help:
	@echo "make init      - terraform init"
	@echo "make plan      - terraform plan (READ THE OUTPUT)"
	@echo "make apply     - terraform apply"
	@echo "make ansible   - configure the servers, over SSM"
	@echo "make deploy    - apply + ansible + verify, end to end"
	@echo "make verify    - PROVE no SSH ports exist"
	@echo "make ssm-list  - which hosts are Online in SSM?"
	@echo "make outputs   - show terraform outputs"
	@echo "make destroy   - tear it all down"

init:
	$(TF) init

fmt:
	$(TF) fmt -recursive
	$(TF) validate

plan: fmt
	$(TF) plan -out=tfplan

apply:
	$(TF) apply tfplan

ansible:
	@test -n "$(BUCKET)" || (echo "No ssm_transfer_bucket output. Run terraform apply first."; exit 1)
	cd ansible && ANSIBLE_AWS_SSM_BUCKET=$(BUCKET) \
		NIFI_FQDN=$(shell echo $(NIFI_URL) | sed 's|https://||') \
		ansible-playbook site.yml

deploy:
	bash scripts/deploy.sh

verify:
	bash scripts/verify-security.sh

ssm-list:
	aws ssm describe-instance-information \
	  --query 'InstanceInformationList[].{Instance:InstanceId,Ping:PingStatus,Agent:AgentVersion}' \
	  --output table

outputs:
	$(TF) output

destroy:
	bash scripts/destroy.sh
