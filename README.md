# AWS Cloud Operations Labs

Hands-on labs covering day-to-day AWS cloud administration: Infrastructure as Code with Terraform, preventing and handling configuration drift, access guardrails, and Windows Server / IIS operations managed entirely through AWS Systems Manager.

Each lab is self-contained, deploys with Terraform, and includes a step-by-step guide explaining **what** each step does and **why**. Everything is designed to cost cents, not dollars, and is torn down with `terraform destroy` at the end.

## Labs

| Lab | What it covers | Key AWS and tooling |
|---|---|---|
| [**drift-lab**](drift-lab/) | Detecting, investigating, handling and preventing Terraform drift. Covers remote state with locking, four drift responses (revert, codify, ignore, import), and IAM guardrails that stop manual changes to Terraform-managed resources. | Terraform, S3 remote state with native locking, IAM, Service Control Policies, CloudTrail, GitHub Actions with OIDC |
| [**iis-lab**](iis-lab/) | Running and troubleshooting IIS on Windows Server with **no inbound ports**. Covers installing IIS fleet-wide with Run Command, and diagnosing five realistic failures: stopped app pool, crash loop, rotated service-account password, binding conflict and broken `web.config`. | EC2 Windows Server 2022, Systems Manager (Session Manager, Run Command, Fleet Manager, Patch Manager), custom SSM documents, PowerShell |

## Design principles across the labs

- **Everything as code.** Infrastructure is Terraform; server configuration is versioned SSM documents.
- **Remote state, shared safely.** State lives in an encrypted, versioned, HTTPS-only S3 bucket with locking. Each lab uses its own state file.
- **Least privilege and no open doors.** Read-only and guarded roles for people; changes only through the pipeline role; servers reached through Systems Manager, not SSH or RDP.
- **Explain the why.** Each guide links every step to the operational problem it solves, and ends with a short summary of the approach.

## Prerequisites

- An AWS account and the AWS CLI v2 configured with an admin profile
- Terraform 1.10 or later (for S3-native state locking)
- Optional: the Session Manager plugin for the AWS CLI (used in the IIS lab)

Start with **drift-lab**: its `bootstrap/` folder creates the S3 state bucket that both labs use.

## Safety notes

- No state files, private keys, saved plans or account-specific backend settings are committed; see `.gitignore`.
- Run the labs in a sandbox account, and run `terraform destroy` when you finish each one.
