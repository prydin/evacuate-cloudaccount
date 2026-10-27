# Aria Automation cloud-account cleanup

Self-contained Windows PowerShell 5.1 scripts for inventorying managed vSphere
VMs and cleaning up Aria Automation 8.18 records associated with a retired or
unreachable vCenter.

- [Get-ManagedVMs.ps1](Get-ManagedVMs.ps1) exports managed VMs to CSV, including
  missing VMs, while excluding discovered VMs.
- [Remove-VMs.ps1](Remove-VMs.ps1) reads the CSV and previews deletion by default.
  Execution requires `-Execute`. It checks live status, targets missing VMs
  unless `-All` is supplied, and supports `-Concurrency` (default 5).
- `-DeploymentCleanup` enables whole-deployment deletion with Ignore Delete
  Failures. It requires every machine in each deployment to be listed in the CSV.

**Warning:** deployment cleanup removes entire deployments and related resources
from Automation. Physical infrastructure may remain behind. Execution requires
the cloud account to report unhealthy; independently verify vCenter isolation.

See the [proposed cleanup runbook](runbook.md) for prerequisites, commands,
safety checks, verification, and cloud-account removal instructions.
