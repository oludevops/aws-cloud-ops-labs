# Windows Server and IIS break/fix, managed entirely through Systems Manager

**Time:** about 2½ hours, including reading  **Cost:** about 7 cents an hour while the server runs (Windows t3.medium, a 50 GB disk and a public IP). Destroy it at the end and the whole lab costs well under a dollar.  **Region:** us-east-2 (Ohio)

**No IIS experience needed.** Part A explains IIS in plain English, comparing each piece to Kubernetes, which you already know. Every command in the lab says what it does and why you're running it. Read Part A before touching anything: the break/fix scenarios only make sense once you know how a request travels through IIS.

## What you will practise

| Part | Skill | Real-world question it answers |
|---|---|---|
| A | How IIS works, in plain English | "What actually happens when a request reaches IIS?" |
| B | Just enough PowerShell to read and run the commands | (supports everything else) |
| 1 | Deploy Windows Server 2022 with **no inbound ports** | "How do you give admins access to servers securely?" |
| 2 | Install IIS on a fleet with **Run Command** and a custom SSM document | "How do you automate Windows configuration?" |
| 3 | Connect with **Session Manager**, port forwarding and Fleet Manager RDP | "Do you need RDP or a bastion host?" |
| 4 | Learn the IIS **troubleshooting toolkit** | "Where do you look when an IIS site fails?" |
| 5 | Fix five realistic faults | "An IIS site returns 503. What do you check?" |
| 6 | Scan for missing patches with **Patch Manager** | "How do you patch Windows at scale?" |

---

## Part A: IIS in plain English (15 min read)

### What IIS is

**IIS (Internet Information Services)** is Microsoft's web server, built into Windows Server: the program that receives web requests and sends back pages. It's especially common for **.NET applications** written in C#, which is why many companies with Windows-based business apps run it.

### The pieces, compared with Kubernetes

You don't need to know any other web server. IIS's pieces line up surprisingly well with **Kubernetes**, which you already know: something receives traffic and routes it to the right app, the app runs as processes that get restarted when they crash, and those processes run under an identity with their own configuration.

| IIS piece | What it is | Closest Kubernetes equivalent |
|---|---|---|
| **HTTP.sys** | A Windows *kernel driver* that receives every web request first and routes it to the right site. If nothing is running to take the request, it answers **503** itself. | The **Ingress controller**, which returns 503 when a Service has no ready pods |
| **Site** | One website: a name, a folder of files, and the address it answers on | An **Ingress rule** for one app |
| **Binding** | The IP address + port + host name a site answers on, e.g. `*:8080:` (any IP, port 8080, any host name). Only one running site can own a given binding. | The **host and port** an Ingress rule matches |
| **Application pool** ("app pool") | Runs a site's code in its own processes, isolated from other sites, so one crashing app doesn't take down the others | A **Deployment** |
| **w3wp.exe** ("worker process") | The actual process running the application code | The **container process** in a pod |
| **WAS** (Windows Process Activation Service) | Starts worker processes when needed, restarts them when they die, and gives up if they keep crashing | The **kubelet** restarting containers |
| **Rapid-fail protection** | If the worker process crashes 5 times in 5 minutes, WAS **stops the app pool completely**, and it stays stopped until someone starts it | **CrashLoopBackOff**, except Kubernetes keeps retrying with longer waits, while IIS gives up entirely |
| **App pool identity** | The Windows account the worker process runs as, with IIS storing its password | The pod's **ServiceAccount** / `runAsUser` |
| **web.config** | An XML settings file in the site's folder. IIS reloads it automatically when it changes. | A **ConfigMap** mounted into the pod |
| **ASP.NET** / `.aspx` pages | Microsoft's framework for web pages that run C# code on the server | The app's framework, like Spring Boot or Express |
| **Event Viewer: System log** | Platform events: WAS starting, stopping or giving up on app pools | **`kubectl get events`** / `kubectl describe pod` |
| **Event Viewer: Application log** | The application's own errors and crashes | **`kubectl logs`** |
| **HTTPERR log** | HTTP.sys's record of requests it **rejected** before they reached IIS, with the reason | The Ingress controller's log of 503s for "no endpoints" |
| **IIS logs** (`W3SVC` folders) | One line per request IIS handled, with its status code | The Ingress controller's **access log** |

The one big difference: Kubernetes usually runs **many copies** of an app across many machines, so one crashing pod is often invisible to users. A typical IIS server runs **one** worker process per app pool on one server, so when it stops, the site is down. That's why IIS troubleshooting is so focused on the app pool.

### How a request travels through IIS

This is the most important thing in the lab. Every fault you'll fix breaks a different step:

```
  Browser asks for http://server:8080/
        │
        ▼
  ① HTTP.sys (kernel) receives it on port 8080
        │   Looks up which SITE owns the binding *:8080
        │   No running site or app pool to hand it to?  → HTTP.sys answers 503 itself
        ▼
  ② Site "Alerts" → uses application pool "AlertsPool"
        │
        ▼
  ③ WAS makes sure a worker process is running for AlertsPool
        │   Starts w3wp.exe, logged in as the pool's identity (svc_alerts)
        │   Wrong password?             → can't start  → app pool disabled → 503
        │   Keeps crashing (5 in 5 min)? → rapid-fail   → app pool disabled → 503
        ▼
  ④ w3wp.exe reads web.config, then runs default.aspx
        │   web.config isn't valid XML?  → HTTP 500.19 (configuration error)
        │   Code crashes the process?    → back to step ③
        ▼
  ⑤ HTML page goes back to the browser  → HTTP 200 OK
```

**Two rules of thumb fall out of this diagram:**
- A **503** means the request never reached your code. HTTP.sys had nowhere to send it, almost always because the **app pool isn't running**. The question is then *why*.
- A **500** means the request **did** reach IIS, but something inside failed: configuration (500.19) or the application itself.

### The lab's site

Setup builds one site so you have something realistic to break:
- **Site:** `Alerts`, bound to port **8080**, files in `C:\inetpub\alerts`
- **App pool:** `AlertsPool`, running **.NET 4.x**
- **Identity:** a local account `svc_alerts`. Real business apps often run as a dedicated service account so they can reach file shares or SQL Server, and that's what makes password changes a classic outage (Scenario 3).
- **Page:** `default.aspx`, which shows "release v1", the time, and **which account it's running as**
- A copy of release v1 kept in `C:\lab\releases\v1`, the way a deployment process keeps the previous release for recovery

---

## Part B: Just enough PowerShell (5 min read)

You'll type PowerShell commands on the Windows server. A few ideas make them readable:

- **Commands are `Verb-Noun`**: `Get-Website` (list sites), `Start-WebAppPool` (start an app pool), `Get-Content` (read a file, like `cat`). You can usually guess them. `Get-Command *AppPool*` lists every command with "AppPool" in its name, and `Get-Help Start-WebAppPool -Examples` shows examples.
- **Output is objects, not text.** On Linux you'd `grep` and `awk` text. In PowerShell, `|` passes *objects* with named properties, and you pick the ones to show:
  - `Format-Table Name, State` shows chosen properties as columns.
  - `Format-List` shows each property on its own line, good for long messages.
  - `Select-Object -Last 1` keeps the last item, like `tail -1`.
- **`$name` is a variable.** `$id = 5` stores a value.
- **`@{ key = value; key2 = value2 }`** is a *hashtable*, a set of named settings, like a small dictionary or JSON object.
- **A backtick `` ` `` at the end of a line** continues the command on the next line, like `\` in bash.
- **`Import-Module WebAdministration`** loads the IIS commands. It also creates an **`IIS:\` drive** you can browse like a folder: `IIS:\Sites` lists sites and `IIS:\AppPools` lists app pools.

---

## Part 0: Set up (5 min)

From the repository root:

```bash
cd iis-lab
chmod +x ssm-run.sh          # makes the helper script executable
export AWS_REGION=us-east-2

# Reuse the remote state bucket from the drift lab.
cp ../drift-lab/backend.hcl .
cat backend.hcl
```

This lab stores its Terraform state in the same S3 bucket as the drift lab, under a different file name (`iis-lab/terraform.tfstate`, set in `versions.tf`). One state bucket, a separate state file per project, is the normal pattern.

> If you've already destroyed the drift lab's state bucket, recreate it with `terraform -chdir=../drift-lab/bootstrap apply` first.

**Optional but recommended: install the Session Manager plugin** on your workstation. The AWS CLI needs this small extra program to open interactive sessions and port forwarding from your terminal. Without it, you can still do everything from the AWS console.

```bash
curl -sSo /tmp/session-manager-plugin.deb \
  "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb"
sudo dpkg -i /tmp/session-manager-plugin.deb
session-manager-plugin --version
```

---

## Part 1: Deploy the server (10 min, mostly waiting)

```bash
terraform init -backend-config=backend.hcl   # connect to the S3 state bucket, download providers
terraform plan -out=tfplan                   # expect: Plan: 15 to add
terraform apply tfplan
```

**What Terraform builds, and why:**

- **A small VPC with one public subnet** (`network.tf`). The server needs a way to reach Systems Manager's endpoints on the internet.
- **A security group with no inbound rules** (`network.tf`). This is the key idea of the lab. On a traditional setup you'd open port 3389 for RDP, which is a constant target for attackers. Here, the **SSM Agent** (preinstalled on AWS Windows images) makes an *outbound* HTTPS connection to Systems Manager, and your sessions travel back through that connection. Nothing on the server listens to the internet.
- **An IAM role with `AmazonSSMManagedInstanceCore`** (`compute.tf`). This one AWS-managed policy lets the agent register with Systems Manager and use Session Manager, Run Command, Fleet Manager and Patch Manager.
- **The Windows Server 2022 instance** (`compute.tf`):
  - Its image (AMI) ID is read from a public SSM parameter, `/aws/service/ami-windows-latest/...`. AWS keeps it pointed at the latest patched image, so you never hard-code an AMI ID.
  - `ignore_changes = [ami]` stops Terraform from replacing the server every month when AWS publishes a new image. That's the drift lab's "ignore" pattern: new images are rolled out deliberately, not as a side effect of an unrelated apply.
  - **IMDSv2 required** and an **encrypted gp3 disk**: two baseline security settings auditors check.
- **A key pair**, used only to unlock the Administrator password for Fleet Manager's remote desktop in Part 3c. No RDP port is opened.
- **Two SSM documents**, `IISLab-Setup` and `IISLab-Break` (`ssm-documents.tf`): PowerShell scripts stored in Systems Manager so they can be run on any server by tag. Their code is in the `scripts/` folder if you're curious.

**Wait for the server to register with Systems Manager.** Windows takes 3–5 minutes to boot. This command lists instances tagged `Role=iis-lab` that the agent has registered:

```bash
aws ssm describe-instance-information \
  --filters "Key=tag:Role,Values=iis-lab" \
  --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,OS:PlatformName,Agent:AgentVersion}' \
  --output table
```

Repeat until **`Ping` shows `Online`**. That means the agent is connected and the server can take commands. If it's still empty after 10 minutes, check the usual three causes: the agent isn't running, the IAM role isn't attached, or there's no network path to the SSM endpoints.

---

## Part 2: Install IIS with Run Command (10 min)

```bash
./ssm-run.sh setup
```

**What this does:** `ssm-run.sh` sends the `IISLab-Setup` document to **every instance tagged `Role=iis-lab`**, waits, and prints the output. Today that's one server; the same command would configure 200, which is the point of Run Command.

**What the setup script does on the server, step by step** (the output shows each step as it runs):

1. **Installs IIS and ASP.NET 4.8** using `Install-WindowsFeature`, Windows' equivalent of `apt install`. It also installs IIS Manager (the GUI) and logging features. First run takes 3–5 minutes.
2. **Removes any previous lab objects**, so running setup again always gives you a clean, working lab.
3. **Creates the `svc_alerts` account** with a random password, and adds it to the `IIS_IUSRS` group, the built-in group with the minimum rights a worker process needs.
4. **Deploys release v1**: writes `default.aspx` (the page) and `web.config` (its settings) to `C:\inetpub\alerts`, saves a copy in `C:\lab\releases\v1`, and gives `svc_alerts` permission to read the folder.
5. **Creates the `AlertsPool` app pool**, sets it to run .NET 4.x **as `svc_alerts`**, and turns on rapid-fail protection (5 crashes in 5 minutes). Then creates the **`Alerts` site** on port 8080 using that pool.
6. **Installs a helper, `C:\lab\Test-Site.ps1`**, which requests a page and prints the HTTP status and page text, *even for error pages*. That's like `curl -i`, which you'll use constantly.
7. **Runs a smoke test.** You should see:

```
HTTP 200 OK
Alerts API - release v1 Status: healthy Server time (UTC): ... Running as: ...\svc_alerts .NET CLR version: 4.0.30319...
```

**"Running as `...\svc_alerts`"** proves the page is running inside a worker process logged in as the service account, the chain from Part A working end to end.

**See it in the console:** Systems Manager → **Run Command** → **Command history** shows every command, its status and output per instance. **Documents** → **Owned by me** → `IISLab-Setup` shows the script itself. Packaging a procedure as a document turns it into a versioned, reusable runbook, with every run logged and access controlled by IAM.

---

## Part 3: Connect to the server, three ways (15 min)

### 3a. Session Manager: a PowerShell prompt with no open ports

This is how you'll work for the rest of the lab.

**From the console:**

```bash
terraform output -raw session_manager_url
```

Open the link and click **Start session**. A PowerShell window opens in your browser.

**Or from your workstation** (needs the plugin from Part 0):

```bash
aws ssm start-session --target "$(terraform output -raw instance_id)"
```

Type `exit` to leave a session.

Now look around:

```powershell
whoami
```
Shows `nt authority\system`. Session Manager sessions run as **SYSTEM**, Windows' most powerful built-in account, roughly like root. That's why access to Session Manager must be tightly controlled with IAM.

```powershell
Import-Module WebAdministration
Get-Website
```
Loads the IIS commands, then lists all sites. You'll see **Default Web Site** on port 80 (created automatically with IIS) and **Alerts** on port 8080, both `Started`.

```powershell
Get-ChildItem IIS:\AppPools
```
Lists app pools by browsing the `IIS:\` drive like a folder. `AlertsPool` should be `Started`.

```powershell
C:\lab\Test-Site.ps1
```
Requests `http://localhost:8080/` and prints the result: **HTTP 200** and the page text.

### 3b. Port forwarding: see the site in your own browser

Port forwarding sends traffic from a port on your workstation, through Systems Manager, to a port on the server. Like an `ssh -L` tunnel, but with no SSH and no open ports.

From a **second** terminal on your workstation:

```bash
aws ssm start-session --target "$(terraform output -raw instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
```

`portNumber` is the port on the server (the Alerts site); `localPortNumber` is the port on your workstation. Leave it running. VS Code's Remote-SSH then notices port 8080 on your workstation and forwards it to your laptop; check the **Ports** tab at the bottom of VS Code. Open `http://localhost:8080` in your browser to see the Alerts page. Press `Ctrl+C` in that terminal to stop forwarding.

### 3c. Fleet Manager Remote Desktop: a full Windows desktop

Sometimes a GUI is easier, especially when learning. **IIS Manager** shows sites and app pools visually, and **Event Viewer** lets you browse logs.

```bash
terraform output -raw fleet_manager_url   # link to the server's page in Fleet Manager
cat iis-lab-key.pem                       # the private key you'll paste in the browser
```

Open the link → **Node actions** → **Connect** → **Connect with Remote Desktop** → Authentication type **Key pair** → **Paste key pair content** → paste the key, including the `BEGIN` and `END` lines → **Connect**.

Fleet Manager uses the key only to decrypt the Administrator password that Windows generated at first boot. The remote desktop traffic still goes through Systems Manager, so port 3389 stays closed.

**Take a 5-minute tour:**
- Start menu → type **`inetmgr`** to open **IIS Manager**. In the left pane, expand the server name: **Application Pools** shows `AlertsPool`. Right-click it → **Advanced Settings** to see the **Identity** (`svc_alerts`) and **Rapid-Fail Protection** settings from Part A. Under **Sites**, click **Alerts**, then **Bindings...** on the right to see `http` on port `8080`.
- Start menu → type **`eventvwr`** to open **Event Viewer**. Expand **Windows Logs**: **System** and **Application** are the two logs you'll use in the scenarios.

Everything you see there, you'll also do with PowerShell, which is what scales to many servers.

---

## Part 4: Your IIS troubleshooting toolkit (10 min)

These six checks follow the request path from Part A, from the outside in. Run each one now while the site is healthy, so you know what "normal" looks like. When something breaks, the difference jumps out.

**1. What does the user see?**

```powershell
C:\lab\Test-Site.ps1
```
Always start here, so you know whether you're dealing with a 503 (never reached the code), a 500 (reached IIS, failed inside) or a 200 with wrong content.

**2. Are the site and its app pool running?**

```powershell
Import-Module WebAdministration
Get-Website | Format-Table Name, State, PhysicalPath, @{n='Bindings';e={$_.bindings.Collection.bindingInformation}}
```
Lists every site with its state, folder and bindings. The `@{n='Bindings';e={...}}` part adds a custom column (`n` for name, `e` for the expression that computes it), because bindings are tucked inside another object. You'll see `*:8080:`, meaning any IP, port 8080, any host name.

```powershell
Get-ChildItem IIS:\AppPools | Format-Table Name, State, @{n='Identity';e={$_.processModel.userName}}
```
Lists app pools, whether each is `Started` or `Stopped`, and which account each runs as.

**3. What did WAS record?** WAS (the kubelet-like process manager from Part A) writes to the **System** log whenever it starts, stops or gives up on an app pool:

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WAS'; StartTime=(Get-Date).AddMinutes(-30)} |
  Format-List TimeCreated, Id, Message
```
`Get-WinEvent` reads Windows logs. Think of this one as `kubectl get events` for IIS: platform events about the app pool, not the app's own errors. The filter means "System log, from WAS only, last 30 minutes." `Format-List` shows the full message, which is where the explanation is. On a healthy server this may print nothing, and that's fine.

**4. Did the application crash?** Program crashes go to the **Application** log:

```powershell
Get-WinEvent -FilterHashtable @{LogName='Application'; Level=2; StartTime=(Get-Date).AddMinutes(-30)} |
  Format-List TimeCreated, ProviderName, Id, Message
```
`Level=2` means **errors only** (1 = critical, 3 = warning, 4 = information). This is the `kubectl logs` side: where you find *why* the code crashed.

**5. What did HTTP.sys reject?** When HTTP.sys can't hand a request to an app pool, it answers the 503 itself and records the reason in the **HTTPERR** log:

```powershell
netsh http flush logbuffer | Out-Null
$log = Get-ChildItem C:\Windows\System32\LogFiles\HTTPERR\*.log | Sort-Object LastWriteTime | Select-Object -Last 1
Get-Content $log.FullName -Tail 5
```
Line by line: HTTP.sys buffers its log in memory, so the first line writes it to disk now (`Out-Null` hides the "OK" message). The second finds the newest log file. The third prints its last 5 lines, like `tail -5`. The **last word on each line is the reason**; `AppOffline` means the app pool wasn't running. On a healthy server the log may be empty or missing.

**6. What did IIS log?** Requests that *did* reach IIS go in the site's access log:

```powershell
$id = (Get-Website -Name Alerts).id
Get-ChildItem "C:\inetpub\logs\LogFiles\W3SVC$id" | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Tail 5
```
Each site has a numeric ID, and its logs live in a folder named `W3SVC` plus that ID. The lines are space-separated, one per request, like an Ingress controller's access log; near the end are the **status** and **substatus**, e.g. `200 0` for success or `500 19` for a configuration error. IIS also buffers these, so new lines can take a minute to appear.

**Event IDs worth recognizing** (you'll meet most of these in Part 5):

| Log | Source | ID | Plain-English meaning |
|---|---|---|---|
| System | WAS | 5011 | A worker process (w3wp.exe) died unexpectedly |
| System | WAS | 5002 | Rapid-fail protection: too many crashes, so WAS stopped the app pool |
| System | WAS | 5021 | The app pool's account or password is wrong, so no worker process can start |
| System | WAS | 5057 / 5059 | The app pool was disabled because a worker process couldn't start |
| Application | .NET Runtime | 1026 | A .NET program crashed; the message contains the exception |
| Application | Application Error | 1000 | A program (here w3wp.exe) crashed |

---

## Part 5: Break and fix (about 60 min)

**How each scenario works:**
1. On **your workstation**, inject a fault with `./ssm-run.sh break <scenario>`. The break script hides its own errors on purpose, so its output only says "Fault injected."
2. In a **Session Manager** PowerShell prompt, work through the Part 4 toolkit: what does the user see, is the app pool running, what do the logs say?
3. Decide on the cause and fix it, then confirm with `C:\lab\Test-Site.ps1`.

Try each one before opening its solution. Each solution explains the diagnosis, every fix command, and the lesson. If you get completely stuck, `./ssm-run.sh setup` resets the lab.

### Scenario 1: "The site is down" (warm-up)

```bash
./ssm-run.sh break 1-stopped-pool
```

**Symptom:** customers get errors from the Alerts site.

<details>
<summary>Solution</summary>

**Diagnose:**
- `Test-Site.ps1` returns **HTTP 503 Service Unavailable** with a very short page. That page comes from **HTTP.sys**, not from IIS or your app, so the request never reached the code (step ① in Part A).
- `Get-ChildItem IIS:\AppPools` shows **`AlertsPool` Stopped**. That's why HTTP.sys had nowhere to send the request.
- The HTTPERR log shows `503 ... AppOffline`, confirming it.
- The WAS log shows **no crash** before it stopped. An app pool that stopped without crashing was usually stopped by **a person or a script**.

**Fix:**

```powershell
Start-WebAppPool -Name AlertsPool
C:\lab\Test-Site.ps1
```
`Start-WebAppPool` tells WAS to start the pool again, like `systemctl start`. WAS starts a worker process on the next request, and the test returns **HTTP 200**.

**Find out who did it:** on your workstation, list recent Run Commands:

```bash
aws ssm list-commands --max-results 5 \
  --query 'Commands[].{When:RequestedDateTime,Doc:DocumentName,Comment:Comment,Status:Status}' --output table
```
You'll see the `IISLab-Break` command, when it ran, and its comment. Because every Run Command is logged, a change made through Systems Manager is traceable, just like CloudTrail in the drift lab.

**Lesson:** a 503 from IIS almost always means the app pool isn't running. Starting it fixes the symptom, but you also need to know **why** it stopped. The next two scenarios are the common reasons.

</details>

---

### Scenario 2: "We deployed release v2 and now the site is down"

```bash
./ssm-run.sh break 2-crash-loop
```

This takes about 30 seconds: it deploys a bad page, then sends a few "customer" requests.

**Symptom:** right after a deployment, the site fails. Restarting the app pool only helps for a moment.

<details>
<summary>Solution</summary>

**Diagnose:**
- `Test-Site.ps1`: **503**, and `AlertsPool` is **Stopped**. But this time nobody stopped it.
- The WAS log tells the story in order: several **5011** events, *"A process serving application pool 'AlertsPool' suffered a fatal communication error..."*, meaning the worker process died. Then **5002**: *"Application pool 'AlertsPool' is being automatically disabled due to a series of failures."* That's **rapid-fail protection** from Part A: after 5 crashes in 5 minutes, WAS gave up rather than restart forever. It's like a pod in CrashLoopBackOff, except IIS stops trying completely until someone starts the pool again.
- The WAS log tells you *that* it crashed. The **Application** log tells you *why*: a **.NET Runtime 1026** event with the message `AlertsApi v2: fatal error while loading sensor configuration`, and an **Application Error 1000** event naming `w3wp.exe` as the program that crashed.

**Prove that restarting doesn't help:**

```powershell
Start-WebAppPool -Name AlertsPool
C:\lab\Test-Site.ps1
```
The request crashes the new worker process immediately. The code is broken, so restarting only resets the counter.

**Fix:** put the last good release back, then start the pool:

```powershell
Copy-Item C:\lab\releases\v1\default.aspx C:\inetpub\alerts\default.aspx -Force
Start-WebAppPool -Name AlertsPool
C:\lab\Test-Site.ps1
```
`Copy-Item` is `cp`; `-Force` overwrites the bad file. The test returns **HTTP 200** and "release v1".

**Lesson:** for a crash loop, the System log says *that* it crashes and the Application log says *why*. In production, this is why you deploy with health checks and blue/green or canary releases, so a bad build is caught before it takes all the traffic, and why you always keep the previous release ready to redeploy.

</details>

---

### Scenario 3: "Nothing was deployed, but the site went down after the overnight restart"

```bash
./ssm-run.sh break 3-bad-identity
```

**Symptom:** no code or configuration changed. The site failed after the app pool restarted.

<details>
<summary>Solution</summary>

**Diagnose:**
- `Test-Site.ps1`: **503**, pool **Stopped**, but **no crash events** in the Application log. So the code never even ran.
- The WAS log has **5021**: *"The identity of application pool AlertsPool is invalid. The user name or password that is specified for the identity may be incorrect..."* WAS couldn't log in as `svc_alerts` to start the worker process (step ③ in Part A).

**What happened:** the `svc_alerts` password was **changed**, as security policies require every few months. But IIS keeps its own copy of the password in the app pool's settings, and that copy wasn't updated. Nothing broke right away, because the worker process that was already running didn't need to log in again. It broke at the next restart, which could be days later, after patching or a reboot. That delay is what makes this outage so confusing in real life.

**Fix:** set a new password on the account **and** in the app pool, so they match:

```powershell
$plain = 'Fix#' + [guid]::NewGuid().ToString('N').Substring(0,16) + 'K4!'
```
Builds a random password: a fixed prefix and suffix (for the required uppercase letter, digit and symbol) around 16 random characters taken from a new GUID. It's stored in the variable `$plain`.

```powershell
Set-LocalUser -Name svc_alerts -Password (ConvertTo-SecureString $plain -AsPlainText -Force)
```
Sets the account's password. Windows only accepts passwords as a protected "SecureString", so `ConvertTo-SecureString` converts it.

```powershell
Set-ItemProperty IIS:\AppPools\AlertsPool -Name processModel `
  -Value @{userName="$env:COMPUTERNAME\svc_alerts"; password=$plain; identityType=3}
```
Updates the app pool's identity settings (stored under `processModel`) with the same password. `$env:COMPUTERNAME\svc_alerts` is the account's full name (server name\user name), and `identityType=3` means "a specific user account" rather than a built-in identity.

```powershell
Start-WebAppPool -Name AlertsPool
C:\lab\Test-Site.ps1
```
Start the pool and test: **HTTP 200**, "Running as ...\svc_alerts".

**Lesson:** the permanent fix is a **group Managed Service Account (gMSA)** in Active Directory. AD changes its password automatically and IIS never stores a password at all, so rotation can't break the app. Without AD, keep the password in **AWS Secrets Manager** and have the rotation update the account and the app pool together.

</details>

---

### Scenario 4: "Customers are seeing a staging page"

```bash
./ssm-run.sh break 4-port-conflict
```

**Symptom:** after a maintenance window, the Alerts URL loads, but shows the wrong content.

<details>
<summary>Solution</summary>

**Diagnose:**
- `Test-Site.ps1`: **HTTP 200**, but the page says **"STAGING BUILD - internal testing only."** Not every outage is an error code; this one is wrong content, which monitoring that only checks for "200 OK" would miss.
- `Get-Website` shows **two sites with the same binding `*:8080:`**. **`Alerts-staging` is Started** and **`Alerts` is Stopped**.
- Try starting the real site:

  ```powershell
  Start-Website -Name Alerts
  ```
  It fails with *"Cannot create a file when that file already exists. (Exception from HRESULT: 0x800700B7)"*. That cryptic message is IIS's way of saying **the binding is already taken**: HTTP.sys can only route `*:8080:` to one running site, and staging grabbed it first while Alerts was stopped. It's like two Ingress rules claiming the same host and port, except IIS doesn't merge or pick one: the second site simply won't start.

**Fix:** give staging its own port, then start the real site:

```powershell
Set-WebBinding -Name 'Alerts-staging' -BindingInformation '*:8080:' -PropertyName Port -Value 8081
```
Finds the staging site's `*:8080:` binding and changes its port to 8081.

```powershell
Start-Website -Name Alerts
C:\lab\Test-Site.ps1                                   # Alerts, release v1
C:\lab\Test-Site.ps1 -Url http://localhost:8081/       # staging, now on its own port
```
Port 8080 is free now, so Alerts starts. Both sites work, each on its own port.

**Lesson:** each binding (IP + port + host name) can belong to only one running site. In production, staging belongs on a separate server or environment. And health checks should verify the page **content** (for example, that it says "healthy"), not just the status code.

</details>

---

### Scenario 5: "The new configuration broke everything"

```bash
./ssm-run.sh break 5-bad-config
```

**Symptom:** after a configuration change was deployed, every request fails.

<details>
<summary>Solution</summary>

**Diagnose:**
- `Test-Site.ps1`: **HTTP 500**. And this time **`AlertsPool` is Started**, so the request reached IIS (step ④ in Part A). The page text contains **HTTP Error 500.19**, *"The requested page cannot be accessed because the related configuration data for the page is invalid,"* with an error code such as `0x8007000d`, which means the configuration file isn't valid XML.
- You see this detailed error only because you're testing **on the server itself**. Remote users get a generic "500 Internal Server Error" with no detail, for security. That's one reason testing locally through Session Manager is so useful.
- Ask Windows exactly what's wrong with the file:

  ```powershell
  [xml](Get-Content C:\inetpub\alerts\web.config)
  ```
  `[xml]` tries to load the file as XML. It fails with the exact problem and line number: the `<system.web>` element is opened but never closed. Its closing tag was lost.

**Fix:** restore the last good configuration:

```powershell
Copy-Item C:\lab\releases\v1\web.config C:\inetpub\alerts\web.config -Force
C:\lab\Test-Site.ps1
```
**HTTP 200**. No restart needed: IIS watches `web.config` and reloads it automatically when it changes. (Adding the missing `</system.web>` line by hand would also work.)

**Lesson:** a 500.19 is a configuration error, not a code error. Prevent it by validating configuration files in the CI/CD pipeline before deployment; even this one-line XML check would have caught it.

</details>

---

### The pattern behind all five

| What the user sees | First check | Likely cause | Where the evidence is |
|---|---|---|---|
| 503, short page | Is the app pool running? | Stopped by someone | No crash events; Run Command history |
| 503 that comes back after every restart | Application log | Bad release crashing w3wp.exe | WAS 5011 → 5002; .NET 1026 |
| 503 after a restart, no code change | WAS log | Wrong app pool password | WAS 5021 |
| 200 but wrong content | `Get-Website` bindings | Another site holding the binding | `0x800700B7` when starting the site |
| 500.19 | `web.config` | Invalid configuration | `[xml](Get-Content ...)` |

---

## Part 6: Scan for missing patches with Patch Manager (10 min)

```bash
./ssm-run.sh patch-scan
```

**What this does:** sends the AWS-provided `AWS-RunPatchBaseline` document with `Operation=Scan`. The server compares its installed updates against its **patch baseline** (the list of approved patches) and reports what's missing, **without installing anything or rebooting**. That's why scans are safe to run in production during the day.

Then look at the results:

```bash
IID=$(terraform output -raw instance_id)

aws ssm describe-instance-patch-states --instance-ids "$IID" \
  --query 'InstancePatchStates[0].{Installed:InstalledCount,Missing:MissingCount,Failed:FailedCount,Baseline:BaselineId,Scanned:OperationEndTime}' \
  --output table
```
A summary: how many patches are installed, missing or failed, and which baseline was used.

```bash
aws ssm describe-instance-patches --instance-id "$IID" --filters Key=State,Values=Missing \
  --query 'Patches[].{KB:KBId,Severity:Severity,Title:Title}' --output table
```
The missing patches themselves. Windows updates are identified by **KB numbers** (Knowledge Base articles, e.g. `KB5034439`).

Because the server was built from the latest published image, you may see **0 missing**. That's the point of building from fresh golden images. In the console: Systems Manager → **Patch Manager** → **Compliance reporting**.

**How this works at scale:**
- **Patch baselines** decide which patches are approved and how soon after release, for example critical security updates after 7 days.
- **Patch groups**, assigned by tag, link servers to baselines, e.g. dev and prod.
- **Maintenance windows** run `Operation=Install` at agreed times: dev first, then production a few days later.
- **Compliance reports** are the evidence auditors ask for under SOC 2 and ISO 27001.

---

## Part 7: Clean up (5 min)

```bash
terraform destroy        # type "yes"
```

This removes the server, VPC, IAM role, SSM documents and key pair. Terminating Windows takes a few minutes. The local `iis-lab-key.pem` file is deleted too. The state file stays in the shared S3 bucket, now recording an empty lab, and goes when you destroy the drift lab's bootstrap bucket.

---

## Summary: the approach in a nutshell

> "I manage Windows servers through Systems Manager rather than RDP. The servers have no inbound ports; admins use Session Manager for PowerShell, port forwarding to test sites, and Fleet Manager when they need a GUI, with every session logged. I package configuration as custom SSM documents and run them by tag with Run Command, so the same change reaches one server or a whole fleet.
>
> For IIS troubleshooting, I follow the request path. A 503 means the request never reached the application, so I check the app pool first. If it's stopped, the WAS events in the System log tell me why: 5002 means rapid-fail protection after repeated crashes, and the Application log's .NET 1026 event gives the actual exception; 5021 means the pool's identity is invalid, usually a rotated service-account password, which is why I'd move app pools to gMSAs. A 500.19 is a broken `web.config`, which I'd catch in the pipeline by validating it before deployment. And if a site won't start with 0x800700B7, another site holds its binding. For patching, I use Patch Manager with baselines, patch groups and maintenance windows, scan-only during the day, with compliance reports as audit evidence."
