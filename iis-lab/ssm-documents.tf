# -----------------------------------------------------------------------------
# Custom SSM Command documents: reusable, versioned runbooks.
#
#   IISLab-Setup : installs IIS + ASP.NET, builds the "Alerts" site. Re-running it
#                  resets everything to a clean, working state.
#   IISLab-Break : injects one of five realistic faults.
#
# In a real fleet, documents like these are how you run the same change on 1 or
# 500 servers, by tag, with output logged and access controlled by IAM.
# -----------------------------------------------------------------------------

resource "aws_ssm_document" "setup" {
  name            = "IISLab-Setup"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install IIS and ASP.NET 4.8, and deploy the Alerts site on port 8080. Safe to re-run: it resets the lab."
    mainSteps = [
      {
        action = "aws:runPowerShellScript"
        name   = "SetupIIS"
        inputs = {
          timeoutSeconds = "1800"
          runCommand     = split("\n", file("${path.module}/scripts/setup.ps1"))
        }
      }
    ]
  })
}

resource "aws_ssm_document" "break" {
  name            = "IISLab-Break"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Inject a fault into the Alerts site for troubleshooting practice."
    parameters = {
      Scenario = {
        type          = "String"
        description   = "Which fault to inject"
        allowedValues = ["1-stopped-pool", "2-crash-loop", "3-bad-identity", "4-port-conflict", "5-bad-config"]
      }
    }
    mainSteps = [
      {
        action = "aws:runPowerShellScript"
        name   = "BreakIIS"
        inputs = {
          timeoutSeconds = "600"
          runCommand     = split("\n", file("${path.module}/scripts/break.ps1"))
        }
      }
    ]
  })
}
