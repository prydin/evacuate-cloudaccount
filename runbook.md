# Proposed runbook: retire a broken vCenter cloud account

## Purpose and scope

Clean up managed VM and deployment records in Aria Automation 8.18 when the
associated vCenter is permanently unavailable, then remove its cloud account.

Use [Get-ManagedVMs.ps1](Get-ManagedVMs.ps1) to inventory managed vSphere VMs and
[Remove-VMs.ps1](Remove-VMs.ps1) to submit cleanup requests.

**This is a proposed procedure, not a fully validated recovery procedure.**
The scripts' safety checks and request payload have been tested with mocked
responses, and live previews have been run. Successful forced cleanup of a real
deployment has not yet been verified.

## Critical warnings

- `-DeploymentCleanup` deletes the **entire deployment**, including related
  resources, not just the CSV's VMs. Review disks, networks, integrations, and
  resources outside the target account before approving.
- Every machine in a deployment must appear in the CSV. This check does not
  establish that all non-machine resources are safe to remove.
- `-DeploymentCleanup` allows Automation cleanup despite infrastructure
  deletion failures. It is not a guarantee that infrastructure deletion is
  never attempted. Keep the retired endpoint isolated throughout cleanup.
- The scripts require the account to report `healthy=false` before execution.
  Health is a periodic result, not a live connectivity guarantee; it does not
  prove that vCenter is permanently unavailable.
- There is no script-level undo. Do not proceed if the intention is to recover
  the existing vCenter and preserve these deployments under management.

## 1. Approve retirement and establish a recovery point

1. Confirm with the platform and application owners that the account is being
   retired, not temporarily repaired.
2. Record the Automation server, cloud account name and ID, vCenter identity,
   affected projects, business owners, and change reference.
3. Use the organization's supported backup process for Automation and record
   the recovery procedure. Export deployment details and infrastructure
   identifiers needed for reconciliation.
4. Stop new provisioning and scheduled actions against the account. Review
   project cloud-zone assignments and placement configuration so new workloads
   cannot land there. Record configuration changes for later cleanup.
5. Confirm that no provisioning, deletion, or other deployment requests are
   still running.
6. If possible, maintain an approved network isolation control between Automation and the
   retired vCenter endpoint. Do not disconnect unrelated accounts or shared
   infrastructure. Arrange physical infrastructure cleanup separately.

**Go/no-go:** retirement, backup, isolation, and application-owner approval are
documented. Otherwise stop.

## 2. Prepare to run the scripts

Run Windows PowerShell 5.1 from the folder containing both scripts. Use an
account permitted to see all affected projects, delete their deployments, and
administer the cloud account. Incomplete visibility can produce an incomplete
inventory.

No separate login or session-setup code is needed: each script logs in itself.
Replace the example server, account, username, and password below with your
target values. Add `-Domain 'example.com'` for a domain login; omit it for a local
user. Supply credentials using your approved credential-handling procedure;
literal passwords entered on the command line can be saved in command history.

Add `-Insecure` only if a trusted server certificate is unavailable and the
exception is approved. It disables certificate validation for the remainder of
the PowerShell process; close the process afterward.

## 3. Capture and reconcile the inventory

```powershell
.\Get-ManagedVMs.ps1 -Server 'automation.example.com' -User 'admin' `
    -Password '<password>' -CloudAccount 'retired-vcenter' `
    -OutFile .\managed-vms.csv
```

The script logs in, queries managed VMs, and writes the CSV. Open the resulting
CSV in a spreadsheet or text editor to review it; no additional PowerShell
import or grouping commands are required. Use a new output filename for each
inventory you need to preserve, because the export overwrites its output file.

If desired, this script can me manually edit to exclude or include virtual 
machines marked for deletion.

Confirm that the export completed without errors. A header-only or partially
written CSV is not evidence that the account is empty.

The inventory:

- Includes `DEPLOYED` and `ONBOARDED` vSphere machine resources.
- Excludes discovered VMs.
- Retains missing VMs using deployment records, even when their IaaS machine
  records no longer exist.
- Does not enumerate every account dependency or non-VM resource.

Compare this inventory with the Automation UI and the pre-retirement records.
For each affected deployment, review the resources and identify anything
that must be preserved. Confirm every machine belongs to the retiring account.
Do not add another account's VMs merely to satisfy the coverage check.

Preserve the original inventory unchanged. If a separate approved execution CSV
is needed, copy it and select only complete, approved deployments. Review
deployment IDs as well as VM names; names alone are not reliable identifiers.

## 4. Preview whole-deployment cleanup

For deployments where every machine is currently missing:

```powershell
.\Remove-VMs.ps1 -Server 'automation.example.com' -User 'admin' `
    -Password '<password>' -CsvFile .\managed-vms.csv -DeploymentCleanup
```

For permanent retirement of the entire account, status may remain `SUCCESS`
because collection stopped when vCenter failed. After approving all listed VMs,
preview with:

```powershell
.\Remove-VMs.ps1 -Server 'automation.example.com' -User 'admin' `
    -Password '<password>' -CsvFile .\managed-vms.csv -DeploymentCleanup -All
```

`-All` bypasses only the missing-status filter. It does not bypass cloud-account
health or membership checks. Without it, a deployment is skipped if any machine
is not missing. Empty sync status is treated as `MISSING`, so review uncertain
statuses rather than assuming physical absence.

Review the preview for:

- Correct account ID and `healthy=false`.
- Correct deployment and machine coverage, with no status-check errors.
- Approval to remove every associated non-machine resource.
- Expected skips and expected deployment count.

Preview performs read-only checks; it does not prove that Delete is available
or will succeed. Execution also checks action availability and whether the
deployment Delete schema exposes `ignoreDeleteFailures`.

**Stop** on incomplete coverage, unexpected resources, account mismatches, or an
unexplained count difference. Do not weaken the guards to continue.

## 5. Execute a pilot, then the approved remainder

First use a manually edited execution CSV containing all machines of one approved, low-risk
deployment. Run with `-Concurrency 1`, verify the result as described below, and
only then continue with the remaining approved deployments.

For an approved account-wide retirement:

```powershell
.\Remove-VMs.ps1 -Server 'automation.example.com' -User 'admin' `
    -Password '<password>' -CsvFile .\managed-vms.csv `
    -DeploymentCleanup -All -Execute -Concurrency 1 `
    -TimeoutSeconds 600 -ErrorFile .\cleanup-errors.csv
```

Point `-CsvFile` at the pilot CSV for the initial run. For missing-only cleanup,
omit `-All`. Once the pilot succeeds, increase concurrency if appropriate; the
default is 5. In this mode, concurrency counts deployment requests, not VMs.

Ordinary VM Delete without `-DeploymentCleanup` may fail trying to contact the
broken vCenter, as observed in this environment. It does not enable Ignore
Delete Failures.

Record request IDs and outcomes. In deployment-cleanup mode, error-log `Id` and
`DeploymentId` identify the deployment rather than an individual VM.

### Handling errors and timeouts

- Review the current run's error CSV and the requests in Automation. Error logs
  append records; use a distinct filename per run.
- A timeout or polling failure does **not** cancel the server request. A
  submission response without a request ID may still mean it was accepted.
- Do not retry until you establish whether the original request completed or
  remains active.
- If cleanup still fails with Ignore Delete Failures enabled, preserve the
  request IDs and escalate to Broadcom Support. Do not edit internal databases
  or provisioning documents as a workaround.
- After successful pilot cleanup, regenerate the inventory before processing
  the remainder; do not blindly rerun the original CSV against removed records.

## 6. Verify Automation cleanup

1. Confirm each submitted request reached a terminal state and investigate
   failures. A script summary alone is not sufficient.
2. Verify the approved deployments and their resources are absent in Automation.
3. Export a fresh inventory to a **new** file:

   ```powershell
   .\Get-ManagedVMs.ps1 -Server 'automation.example.com' -User 'admin' `
       -Password '<password>' -CloudAccount 'retired-vcenter' `
       -OutFile .\managed-vms-after.csv
   ```

4. Confirm the export succeeded and contains no remaining managed VM rows for
   the account. Reconcile this with the UI using sufficient project permissions.
5. Separately check non-VM resources, discovered inventory, shared resources,
   integrations, and account dependencies. An empty managed-VM CSV does not
   establish that the account can be deleted.

## 7. Remove cloud-account dependencies and the account

Use the Automation UI with an appropriately privileged account. Exact labels
can vary by build and installed integrations.

1. Review the cloud account's regions and cloud zones. Remove obsolete project
   assignments and zones only after confirming they have no remaining consumers.
2. Review account-associated network/storage profiles, image and flavor mappings,
   placement constraints, templates, and integrations. Remove or update obsolete
   references without deleting configuration used by other accounts.
3. In the Infrastructure cloud-account view, select the account by its recorded
   name **and ID**, and use the supported Delete operation.
4. If deletion is blocked, capture the reported dependencies and resolve them
   through supported UI/API operations. Do not assume deleting discovered VMs
   physically is necessary to remove inventory records.
5. If dependencies cannot be cleared while vCenter is unavailable, stop and
   involve Broadcom Support rather than forcing internal record deletion.
6. Verify the account is gone, no managed resources still reference it, and
   unrelated accounts and deployments remain intact.

The supplied scripts do not remove cloud accounts or their configuration.

## 8. Reconcile physical infrastructure and close the change

- Using independent infrastructure records and, when available, ESXi/vCenter
  access, account for surviving VMs, disks, snapshots, networks, and allocations.
  Reconcile external IDs, not names alone.
- Arrange approved physical deletion, migration, or retention. Review IPAM,
  DNS, backup, monitoring, and licensing records as applicable.
- Do not reconnect or reuse the retired endpoint identity until this
  reconciliation is complete and the consequences have been reviewed.
- Preserve inventories, approvals, request IDs, errors, dependency changes,
  and evidence of account removal. Protect these files as operational data.
- Close the PowerShell process to discard the credentials and any process-wide
  certificate-validation override.

**Completion criteria:** approved Automation deployments and account references
are removed, the cloud account is absent, unrelated workloads are unaffected,
and every leftover infrastructure resource has a documented disposition.
