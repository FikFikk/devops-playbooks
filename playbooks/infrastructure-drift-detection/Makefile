# Makefile untuk Infrastructure Drift Detection

.PHONY: help init check report remediate install-tools clean

# Default environment
ENV ?= production
TERRAFORM_DIR ?= terraform/$(ENV)

help:
	@echo "Infrastructure Drift Detection Commands"
	@echo ""
	@echo "Usage: make [target] ENV=<environment>"
	@echo ""
	@echo "Targets:"
	@echo "  check           - Run drift detection for specified environment"
	@echo "  report          - Generate detailed drift report"
	@echo "  remediate       - Run auto-remediation (DRY_RUN=false to execute)"
	@echo "  check-all       - Check drift for all environments"
	@echo "  install-tools   - Install required tools (terraform, jq, conftest)"
	@echo "  clean           - Clean up temporary files"
	@echo ""
	@echo "Examples:"
	@echo "  make check ENV=production"
	@echo "  make report ENV=staging"
	@echo "  make remediate ENV=production DRY_RUN=false"

init:
	@echo "Initializing Terraform for $(ENV)..."
	@cd $(TERRAFORM_DIR) && terraform init

check: init
	@echo "Running drift detection for $(ENV)..."
	@./scripts/detect-drift.sh $(ENV) $(TERRAFORM_DIR)

report: init
	@echo "Generating drift report for $(ENV)..."
	@./scripts/drift-report.sh $(ENV) $(TERRAFORM_DIR) drift-metrics-$(ENV).json

remediate: init
	@echo "Running auto-remediation for $(ENV)..."
	@DRY_RUN=$(DRY_RUN) ./scripts/auto-remediate.sh $(ENV) $(TERRAFORM_DIR)

check-all:
	@for env in production staging development; do \
		echo ""; \
		echo "=== Checking $$env ==="; \
		$(MAKE) check ENV=$$env || true; \
	done

install-tools:
	@echo "Installing required tools..."
	@command -v terraform >/dev/null 2>&1 || { \
		echo "Installing Terraform..."; \
		wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg; \
		echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $$(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list; \
		sudo apt update && sudo apt install terraform; \
	}
	@command -v jq >/dev/null 2>&1 || { \
		echo "Installing jq..."; \
		sudo apt-get update && sudo apt-get install -y jq; \
	}
	@command -v conftest >/dev/null 2>&1 || { \
		echo "Installing conftest..."; \
		wget https://github.com/open-policy-agent/conftest/releases/download/v0.49.1/conftest_0.49.1_Linux_x86_64.tar.gz; \
		tar xzf conftest_0.49.1_Linux_x86_64.tar.gz; \
		sudo mv conftest /usr/local/bin/; \
		rm conftest_0.49.1_Linux_x86_64.tar.gz; \
	}
	@echo "✅ All tools installed"

test-policy:
	@echo "Testing OPA policies..."
	@cd terraform && terraform plan -out=test.tfplan
	@terraform show -json terraform/test.tfplan | conftest test -p policies/ -
	@rm -f terraform/test.tfplan

clean:
	@echo "Cleaning up temporary files..."
	@rm -rf drift-reports/
	@rm -f drift-metrics-*.json
	@rm -f terraform/**/.terraform.lock.hcl
	@find . -name "*.tfplan" -delete
	@find . -name ".terraform" -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "✅ Cleanup complete"

.DEFAULT_GOAL := help
