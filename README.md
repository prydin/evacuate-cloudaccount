# Aria Automation cloud-account cleanup

Self-contained Windows PowerShell 5.1 scripts for inventorying managed vSphere
VMs and cleaning up Aria Automation 8.18 records associated with a retired or
unreachable vCenter.

- [Get-ManagedVMs.ps1](Get-ManagedVMs.ps1) exports managed VMs to CSV, including
  missing VMs, while excluding discovered VMs.
- [Remove-VMs.ps1](Remove-VMs.ps1) reads the CSV and previews deletion by default.
  Execution requires `-Execute`. It always deletes whole deployments with Ignore
  Delete Failures. Unless `-All` is supplied, all machines must be missing based
  on live status. `-Concurrency` limits deployment requests (default 5).
  It requires every machine in each deployment to be listed in the CSV.
  Every deployment resource must have a verified cloud account matching that
  deployment's CSV machines; mixed or unknown account membership blocks cleanup.

**Warning:** deployment cleanup removes entire deployments and related resources
from Automation. Physical infrastructure may remain behind. Execution requires
the cloud account to report unhealthy; independently verify vCenter isolation.
Targets on healthy or unknown-health accounts are skipped without stopping
cleanup of other targets.

See the [proposed cleanup runbook](runbook.md) for prerequisites, commands,
safety checks, verification, and cloud-account removal instructions.

Run scripts using `.\Get-ManagedVMs.ps1 ...` or `& 'C:\path\Get-ManagedVMs.ps1' ...`
rather than dot-sourcing them. Both scripts clear any previous token before
logging in, preventing an expired token from being reused on login.
