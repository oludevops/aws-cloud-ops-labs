# Terraform Drift Lab: detect, handle and prevent drift

**Time:** about 75–90 minutes  **Cost:** effectively $0 (VPC, security group, empty log group, one SSM parameter, IAM roles, two small S3 buckets; nothing with an hourly charge)  **Region:** us-east-2 (Ohio)

## What you will practise

| Part | Skill | Real-world question it answers |
|---|---|---|
| 0 | Create a secure **remote state** bucket | "Where do you keep Terraform state, and how do you protect it?" |
| 1 | Deploy a baseline and confirm it is clean | "How do you know Terraform matches reality?" |
| 1b | Inspect remote state: **versioning and locking** | "What stops two people corrupting state at the same time?" |
| 2 | **Revert** an unauthorized change (SSH opened to the internet) | "What is drift and how do you handle it?" |
| 3 | Find **who** made the change with CloudTrail | "How do you investigate a manual change?" |
| 4 | **Codify** a valid emergency fix | "What if the manual change was correct?" |
| 5 | **Ignore** a setting the app changes on purpose | "How do you avoid false drift alarms?" |
| 6 | **Import** a resource someone created by hand | "How do you bring click-ops resources under Terraform?" |
| 7 | **Prevent** drift with read-only and guarded roles | "How do you stop people changing things in the console?" |
| 8 | **Automate** detection (cron and GitHub Actions) | "How would you detect drift continuously?" |

Each part follows the same pattern: **make a change outside Terraform → see what `terraform plan` says → decide the right response.** That decision is the real skill.

---

## Part 0: Set up (5 min)

Clone the repository on your Linux workstation, then:

```bash
cd drift-lab
chmod +x drift-check.sh

# 1. Confirm which identity and account the CLI is using
aws sts get-caller-identity

# 2. Make sure the CLI defaults to Ohio, the region in your console
export AWS_REGION=us-east-2
```

`get-caller-identity` should show your 12-digit account ID. Note the **profile** you are using (usually `default`); you will need its name in Part 7.

> Terraform 1.10 or later is required, for S3-native state locking. Check with `terraform version`.

### Why remote state?

Terraform's **state file** is its record of everything it created. By default it's a local file on whichever machine ran `apply`. That breaks down quickly in a team:

- **Nobody else can see it.** A teammate, the MSP or the CI/CD pipeline running elsewhere has no idea what exists.
- **It can be lost.** If the laptop or VM dies, Terraform forgets what it manages.
- **Two people can apply at once** and corrupt it.
- **It contains sensitive data** (resource IDs, sometimes secrets) sitting unencrypted on a disk.

Remote state in S3 fixes all four: it's shared, **versioned** (every change kept), **encrypted**, and **locked** during operations so only one apply runs at a time.

### The chicken-and-egg problem

Terraform needs a bucket to store state, but something has to create that bucket first. The `bootstrap/` folder solves this: a tiny Terraform configuration with **local** state whose only job is creating the state bucket. You run it once.

### 0a. Create the state bucket

```bash
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply      # type "yes"; creates 7 resources
```

`-chdir=bootstrap` runs Terraform inside the `bootstrap/` folder without you having to `cd` into it.

Open `bootstrap/main.tf` and notice the protections on the bucket: versioning, encryption, public access block, ACLs disabled, a policy refusing non-HTTPS requests, and a lifecycle rule expiring old state versions after 90 days. Together, they are the answer to "how do you protect Terraform state?"

### 0b. Point the lab at the bucket

```bash
terraform -chdir=bootstrap output -raw backend_config > backend.hcl
cat backend.hcl
```

You should see the bucket name and region. Why a separate file? Terraform's `backend` block (in `versions.tf`) **can't use variables**, so account-specific values are passed in at `init` time. This is called **partial configuration**, and it lets the same code use a different state bucket per environment.

> **Already have this lab deployed with local state?** Don't destroy anything. Run `terraform init -migrate-state -backend-config=backend.hcl` instead of the `init` in Part 1, and answer `yes` when Terraform asks to copy your existing state to S3. Then delete the local `terraform.tfstate*` files. Moving a project from local to remote state this way is a common real-world task.

---

## Part 1: Deploy the baseline (5 min)

```bash
terraform init -backend-config=backend.hcl   # connects to the S3 backend and downloads the AWS provider
terraform validate                           # catches syntax errors before touching AWS
terraform plan                               # preview: should create 13 resources
terraform apply                              # type "yes"
```

During `init` you should see **"Successfully configured the backend "s3"!"** Note that there is now **no** `terraform.tfstate` file in your folder.

Now confirm there is no drift:

```bash
./drift-check.sh
```

Expected: `OK: no drift.` (exit code 0). This is your clean baseline. Every exercise below breaks it in a different way.

**What just happened:** Terraform's state now lives in S3. Drift detection compares three things: your **code**, the **state**, and the **real AWS resources**. When all three agree, the plan is empty.

---

## Part 1b: Look inside remote state, versioning and locking (5 min)

### See the state file in S3

```bash
STATE_BUCKET=$(terraform -chdir=bootstrap output -raw state_bucket)

aws s3 ls "s3://$STATE_BUCKET/drift-lab/"
terraform state list          # reads the list of managed resources from S3
```

### See versioning at work

Every `apply` writes a new version of the state file. List them:

```bash
aws s3api list-object-versions --bucket "$STATE_BUCKET" \
  --prefix drift-lab/terraform.tfstate \
  --query 'Versions[].{modified:LastModified,id:VersionId,latest:IsLatest}' --output table
```

Right now there's probably just one or two versions. Come back after Part 6 and there will be several. If state were ever corrupted, you'd restore a previous version with `aws s3api copy-object` using its `VersionId`. That's how state recovery works.

### See locking at work

Locking stops two operations writing state at the same time. Prove it with two terminals in VS Code (Terminal → Split Terminal):

**Terminal 1:**

```bash
# -replace forces a planned change, so apply stops at the prompt instead of
# exiting with "No changes". Do NOT answer yet.
terraform apply -replace=aws_ssm_parameter.feature_flag
```

Why `-replace`? With nothing to change, a plain `terraform apply` prints "No changes" and exits immediately, so it never holds the lock long enough to test. Forcing a replacement gives it a plan to wait on. You'll answer `no`, so nothing is actually replaced.

While Terraform waits for your answer, it holds the lock. In **Terminal 2** (run `export AWS_REGION=us-east-2` first if it's a new terminal):

```bash
aws s3 ls "s3://$STATE_BUCKET/drift-lab/"    # a terraform.tfstate.tflock file has appeared
terraform plan -lock-timeout=0s              # fails with "Error acquiring the state lock"
```

The error shows **who** holds the lock and since when. Now go back to **Terminal 1**, type `no`, and the lock file disappears. Run `terraform plan` in Terminal 2 again and it works.

**Lesson:** without locking, two engineers (or an engineer and the pipeline) could apply at the same time and corrupt state. If a lock is ever left behind, for example after a crashed CI job, `terraform force-unlock <LOCK_ID>` removes it. Use it only after confirming nothing is actually running.

---

## Part 2: Drift type 1, REVERT an unauthorized change (10 min)

**Scenario:** at 2 a.m. someone opened SSH to the whole internet on the web security group "to debug something" and never closed it. That is a security incident waiting to happen.

### 2a. Make the bad change (as your admin user)

In the **console**: EC2 → Security Groups → `drift-lab-web` → **Edit inbound rules** → **Add rule**: Type `SSH`, Source `Anywhere-IPv4 (0.0.0.0/0)` → Save.

Or with the CLI:

```bash
SG_ID=$(terraform output -raw security_group_id)
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0
```

### 2b. Detect it

```bash
./drift-check.sh
```

Expected: `DRIFT DETECTED` (exit code 2). Open the saved report and look for two things:

1. A section headed **"Objects have changed outside of Terraform"** showing the new port 22 rule on `aws_security_group.web`. This is Terraform telling you reality changed.
2. A planned **update in-place** to `aws_security_group.web` that **removes** the port 22 rule. This is what Terraform will do on the next apply.

**Why Terraform noticed:** the rules are written *inline* inside `aws_security_group.web`, so Terraform owns the full rule list. Any extra rule is drift. If the rules were separate `aws_vpc_security_group_ingress_rule` resources, Terraform would only track the rules it created, and this hand-added rule would be invisible. That's the "one resource, one owner" rule from the prep doc in practice.

### 2c. Decide and act

Opening SSH to the world was not authorized, so you **revert** it:

```bash
terraform apply       # removes the SSH rule; type "yes"
./drift-check.sh      # back to OK
```

Check the console: the SSH rule is gone.

**Lesson:** for unauthorized or risky changes, the code is the truth, and `apply` puts reality back.

---

## Part 3: Find out WHO made the change (5 min)

"Revert it" is only half the answer. You also need to find out who did it and why, so it doesn't happen again.

CloudTrail **Event history** records management API calls for 90 days at no cost, even without a trail. Events can take 5–15 minutes to appear, so if this comes back empty, wait and retry.

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AuthorizeSecurityGroupIngress \
  --max-results 5 \
  --query 'Events[].{time:EventTime,who:Username,event:EventName}' \
  --output table
```

You should see your own username and the time you added the rule. In the console: **CloudTrail → Event history**, filter by Event name `AuthorizeSecurityGroupIngress`. Open the event to see the full details, including the source IP and whether the call came from the console or the CLI.

**Lesson:** detect with Terraform, investigate with CloudTrail. In real life you'd now talk to the person and fix the process, for example give them a safe way to debug through SSM Session Manager instead of opening port 22.

---

## Part 4: Drift type 2, CODIFY a valid emergency fix (5 min)

**Scenario:** during an incident, an engineer couldn't investigate because logs were deleted after 7 days. They raised log retention to 30 days by hand. That was the **right** call. If you blindly run `apply`, you'd put it back to 7 days and undo a good fix.

### 4a. Make the change

```bash
aws logs put-retention-policy --log-group-name /drift-lab/app --retention-in-days 30
```

(Console alternative: CloudWatch → Log groups → `/drift-lab/app` → Actions → Edit retention setting → 1 month.)

### 4b. Detect it

```bash
./drift-check.sh
```

The plan shows `retention_in_days` changing from **30 back to 7**. Stop here: **don't apply.** Applying would undo the fix.

### 4c. Decide and act: make the code match reality

Edit `main.tf`, in `aws_cloudwatch_log_group.app`:

```hcl
retention_in_days = 30
```

Then:

```bash
terraform plan        # should now show: No changes
./drift-check.sh      # OK
```

In a team, this edit goes through a **pull request** with a link to the incident ticket, so the reason is recorded in Git history.

**Lesson:** when the manual change was correct, update the code, not the infrastructure. "Emergency changes get codified within a day" is the rule that makes this happen.

---

## Part 5: Drift type 3, IGNORE a setting that's meant to change (5 min)

**Scenario:** the application turns a feature flag on and off at runtime by writing to SSM Parameter Store. Terraform created the parameter, but the **value** belongs to the app. Without special handling, every plan reports drift and every apply resets the flag, which would break the app.

### 5a. The app changes the value

```bash
aws ssm put-parameter --name /drift-lab/feature-flag --value on --overwrite
```

### 5b. Detect it

```bash
./drift-check.sh
```

The plan wants to change the value from `on` back to `off`. This is a **false alarm**: nothing is wrong, but the alert would wake someone up. False alarms train people to ignore drift alerts, which is dangerous.

### 5c. Decide and act: tell Terraform to ignore the value

In `main.tf`, uncomment the lifecycle block in `aws_ssm_parameter.feature_flag`:

```hcl
  lifecycle {
    ignore_changes = [value]
  }
```

Then:

```bash
terraform plan        # No changes
./drift-check.sh      # OK
aws ssm get-parameter --name /drift-lab/feature-flag --query Parameter.Value
# still "on": Terraform left the app's value alone
```

Terraform still manages everything else about the parameter (its name, type and tags); it just doesn't fight the app over the value.

**Lesson:** the same pattern applies to an Auto Scaling group's `desired_capacity` or an ECS service's `desired_count`, which change constantly through autoscaling. Use `ignore_changes` sparingly and only for attributes that are *meant* to change outside Terraform. Ignoring too much hides real drift.

---

## Part 6: Drift type 4, IMPORT a resource created by hand (10 min)

**Scenario:** a team created an S3 bucket in the console for a quick project. It works, people depend on it, and Terraform doesn't know it exists. No tags, no standard settings, no record.

Note: a scheduled `terraform plan` **cannot** see this kind of drift, because Terraform only checks resources it already manages. You find these through AWS Config, Resource Explorer, tag audits (anything missing `ManagedBy`), or Cost Explorer showing untagged spend. Plan-based detection and inventory-based detection complement each other.

### 6a. Create the bucket by hand

```bash
BUCKET=$(terraform output -raw manual_bucket_name)
aws s3api create-bucket --bucket "$BUCKET" --region us-east-2 \
  --create-bucket-configuration LocationConstraint=us-east-2
aws s3api get-bucket-tagging --bucket "$BUCKET"   # error: no tags at all
```

### 6b. Write an import block and the matching resource

Create a new file `import.tf`:

```hcl
# Tells Terraform: this bucket already exists in AWS, adopt it into state.
import {
  to = aws_s3_bucket.manual
  id = "drift-lab-manual-${local.account_id}"
}

resource "aws_s3_bucket" "manual" {
  bucket        = "drift-lab-manual-${local.account_id}"
  force_destroy = true # lab only: lets terraform destroy remove it even if it has objects
}
```

### 6c. Plan and apply

```bash
terraform plan
```

Read the plan carefully. It should say the bucket **will be imported**, and also **updated in-place**, because the provider's `default_tags` will add `ManagedBy` and `Project` tags that the hand-made bucket doesn't have. That's the import bringing the bucket up to your standards. (`force_destroy` may also appear as a change; it's a Terraform-only setting, not an AWS one.)

```bash
terraform apply
aws s3api get-bucket-tagging --bucket "$BUCKET"   # now shows ManagedBy=terraform
./drift-check.sh                                    # OK
```

Once the import has been applied, you can delete the `import { }` block. It has done its job, and the `resource` block is what stays.

> **Shortcut for bigger imports:** instead of writing the resource block by hand, keep only the `import` block and run `terraform plan -generate-config-out=generated.tf`. Terraform writes a starting resource block for you, which you then clean up. Useful when adopting many resources at once.

**Lesson:** import brings click-ops resources under control, tags them, and makes them reproducible.

---

## Part 7: PREVENT drift with roles and a guardrail (15 min)

Detection catches drift after it happens. Now block it from happening. `iam.tf` already created three roles:

| Role | Represents | Can view | Can change Terraform-managed resources |
|---|---|---|---|
| `drift-lab-readonly` | Engineers, MSP staff | Yes | No: no write permissions at all |
| `drift-lab-operator` | Powerful day-to-day role | Yes | **No**: PowerUserAccess, but a Deny guardrail blocks anything tagged `ManagedBy=terraform` |
| `drift-lab-deployer` | The CI/CD pipeline | Yes | **Yes**: the only role exempt from the guardrail |

### 7a. Add CLI profiles for the three roles

Append to `~/.aws/config`, replacing `ACCOUNT_ID` with your account number, and `default` with your profile name from Part 0 if it differs:

```ini
[profile drift-readonly]
role_arn       = arn:aws:iam::ACCOUNT_ID:role/drift-lab-readonly
source_profile = default
region         = us-east-2

[profile drift-operator]
role_arn       = arn:aws:iam::ACCOUNT_ID:role/drift-lab-operator
source_profile = default
region         = us-east-2

[profile drift-deployer]
role_arn       = arn:aws:iam::ACCOUNT_ID:role/drift-lab-deployer
source_profile = default
region         = us-east-2
```

Confirm each one works (IAM changes can take up to a minute to take effect):

```bash
aws sts get-caller-identity --profile drift-readonly
aws sts get-caller-identity --profile drift-operator
aws sts get-caller-identity --profile drift-deployer
```

Each should show an `assumed-role/...` ARN.

### 7b. Read-only: can look, can't touch

```bash
SG_ID=$(terraform output -raw security_group_id)

# Viewing works
aws ec2 describe-security-groups --group-ids "$SG_ID" --profile drift-readonly \
  --query 'SecurityGroups[0].IpPermissions'

# Changing fails with AccessDenied / UnauthorizedOperation
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr 0.0.0.0/0 --profile drift-readonly
```

### 7c. Operator: powerful, but blocked from Terraform-managed resources

```bash
# Try the same 2 a.m. "quick fix": denied by the guardrail
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr 0.0.0.0/0 --profile drift-operator

# Try the classic workaround: remove the ManagedBy tag first, then edit. Also denied
aws ec2 delete-tags --resources "$SG_ID" --tags Key=ManagedBy --profile drift-operator
```

Both fail with an **explicit deny**. An explicit Deny always wins over an Allow, so PowerUserAccess can't override it. And because PowerUserAccess excludes IAM, the operator can't detach the guardrail from itself either.

Now show that the guardrail is **scoped**, not a blanket ban. The operator can still work on things Terraform doesn't manage:

```bash
VPC_ID=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --query 'SecurityGroups[0].VpcId' --output text)

TEST_SG=$(aws ec2 create-security-group --group-name drift-lab-scratch \
  --description "Untagged scratch group" --vpc-id "$VPC_ID" \
  --profile drift-operator --query GroupId --output text)

aws ec2 authorize-security-group-ingress --group-id "$TEST_SG" \
  --protocol tcp --port 8080 --cidr 10.0.0.0/8 --profile drift-operator   # succeeds

# Clean it up now, otherwise terraform destroy can't delete the VPC later
aws ec2 delete-security-group --group-id "$TEST_SG" --profile drift-operator
```

### 7d. Deployer: the pipeline is allowed

```bash
AWS_PROFILE=drift-deployer terraform plan    # works: this is the "pipeline"
```

This works because the deployer can read and write the state bucket (PowerUserAccess includes S3) and take the lock. With remote state, **access to the state bucket is itself a control**: whoever can write state can change what Terraform believes exists. In a real setup you'd restrict the state bucket to the pipeline role and a few admins.

Any change goes through code, a review, and this role. In a real setup, this role trusts **GitHub Actions through OIDC** (only the `main` branch of one repo) instead of your account, so no human can use it directly.

> Note: the deployer has PowerUserAccess plus **read-only** IAM, so it can plan everything and apply the network, logging and parameter changes, but an apply that changes IAM roles would fail. That's realistic: in many companies IAM changes go through a separate, more tightly controlled pipeline.

### 7e. See it in the console

```bash
terraform output -raw console_switch_role_readonly
terraform output -raw console_switch_role_operator
```

Open each link in the browser where you're signed in as your admin user and click **Switch Role**. Then:
- As **drift-readonly**: open the security group and try **Edit inbound rules**. Saving fails.
- As **drift-operator**: try the same. Saving fails with an explicit deny, even though this role can do almost anything else.

Switch back to your admin user from the account menu at the top right when you're done.

### 7f. From IAM policy to SCP

In this lab the guardrail is an **IAM policy attached to one role**, because SCPs require AWS Organizations. Open `scp-example.json`: it's the same logic written as a **Service Control Policy**. The difference:

- An IAM policy protects only the roles it's attached to.
- An SCP applies to **every** user and role in every account under it, even admins. Nobody can bypass it from inside the account.

It also adds a second rule protecting CloudTrail, so nobody can turn off the audit trail. If your account is an Organizations management account, you can try it under **AWS Organizations → Policies → Service control policies**. Otherwise, understanding how it differs from the IAM version is the key point.

---

## Part 8: AUTOMATE detection (5 min)

### Option A: cron on your workstation

```bash
crontab -e
```

Add (runs every night at 06:17 and appends results to a log):

```
17 6 * * * cd $HOME/aws-cloud-ops-labs/drift-lab && AWS_REGION=us-east-2 ./drift-check.sh >> drift-cron.log 2>&1
```

Cron runs with a minimal environment, so if credentials don't load, add `AWS_PROFILE=<your profile>` to the line.

### Option B: GitHub Actions (how a team would do it)

Read `.github/workflows/drift-detection.yml`. Points to notice:

- It authenticates with **OIDC**: no AWS keys stored in GitHub.
- It runs `terraform plan -detailed-exitcode` on a schedule.
- Exit code **2** opens a GitHub issue with the summary; exit code **1** fails the job so errors don't go unnoticed.
- It only needs a **read-only** role, because a plan never changes anything.

This only works **because state is now remote**: a GitHub runner starts on a fresh machine every time and could never see a local state file on your workstation. With S3 state, the runner, your VM and any teammate all read the same state. To wire it up for real, push this folder to a GitHub repo, commit `backend.hcl`, create an IAM OIDC provider and a read-only role that can also read the state bucket, and set its ARN as the repository variable `AWS_DRIFT_ROLE_ARN`.

---

## Part 9: Clean up (5 min)

Order matters: destroy the lab **first**, then the state bucket. If you delete the state bucket first, Terraform loses its record of the lab resources and you'd have to delete them by hand.

```bash
# 1. Destroy the lab (its state lives in S3)
terraform destroy                     # type "yes"; removes everything, including the imported bucket
aws s3api head-bucket --bucket "$BUCKET" 2>&1 | head -1   # should say Not Found

# 2. Destroy the state bucket (bootstrap uses local state)
terraform -chdir=bootstrap destroy    # type "yes"; force_destroy removes all state versions too
```

Then remove the three `[profile drift-*]` blocks from `~/.aws/config`, and the cron line if you added one.

If `destroy` fails on the VPC with a "has dependencies" error, a resource created outside Terraform is still inside it, most likely the scratch security group from 7c. Delete it, then run `destroy` again. That itself is a small lesson in what unmanaged resources cost you.

> In real life, a state bucket is **never** set to `force_destroy`. It gets `lifecycle { prevent_destroy = true }` instead, so Terraform refuses to delete it. The setting here is only to make lab cleanup easy.

---

## Summary: the approach in a nutshell

> "I keep Terraform state remote in S3, created by a small bootstrap configuration. The bucket is versioned so I can restore a previous state, encrypted, blocked from public access, HTTPS-only, and limited to the pipeline and a few admins. I use S3-native locking, so two applies can never run at once, and partial backend configuration so each environment points at its own state.
>
> Drift is when real infrastructure no longer matches the Terraform code and state. I detect it with a scheduled `terraform plan -detailed-exitcode`, which returns 2 when anything differs, and I use CloudTrail to find who changed what. I handle each case on its merits: **revert** unauthorized changes like an SSH rule opened to the internet; **codify** valid emergency fixes, like a log-retention increase, through a pull request; **ignore** attributes that are meant to change at runtime, like autoscaling counts or app-managed flags; and **import** resources created by hand, which also brings them up to our tagging standards.
>
> To prevent drift, I separate viewing from changing. People and the MSP get read-only or guarded roles; only the pipeline role can change Terraform-managed resources; and an SCP enforces that across accounts, including blocking tag removal so it can't be bypassed. I also keep each resource under one owner, inline security group rules or separate rule resources, never both, so Terraform sees every change. Plan-based detection can't see resources Terraform never knew about, so I pair it with AWS Config and tag audits for unmanaged resources."
