asnp "VeeamPSSnapIn" -ErrorAction SilentlyContinue

####################################################################
# Configuration
#
# vCenter server
$vcenter = "vc01.notyourdomain.com"
#
# To Exclude VMs from report add VM names to be excluded as follows
# simple wildcards are supported:
# $excludevms=@("vm1","vm2", "*_replica")
$excludevms = @()
#
# This variable sets the number of hours of session history to
# search for a successul backup of a VM before considering a VM
# "Unprotected".  For example, the default of "24" tells the script
# to search for all successful/warning session in the last 24 hours
# and if a VM is not found then assume that VM is "unprotected".
$HourstoCheck = 24
####################################################################

$vcenterobj = Get-VBRServer -Name $vcenter
$vmobjs = Find-VBRObject -Server $vcenterobj | Where-Object {$_.Type -eq "VirtualMachine"}
$jobobjids = [Veeam.Backup.Core.CHierarchyObj]::GetObjectsOnHost($vcenterobj.id) | Where-Object {$_.GetItem().Type -eq "Vm"}

# Convert exclusion list to simple regular expression
$excludevms_regex = (‘(?i)^(‘ + (($excludevms | ForEach {[regex]::escape($_)}) –join “|”) + ‘)$’) -replace "\\\*", ".*"

foreach ($vm in $vmobjs) {
    $jobobjid = ($jobobjids | Where-Object {$_.ObjectId -eq $vm.Id}).Id
    if (!$jobobjid) {
        $jobobjid = $vm.FindParent("Datacenter").Id + "\" + $vm.Id
    }
    $vm | Add-Member -MemberType NoteProperty "JobObjId" -Value $jobobjid
}    
    
# Get a list of all VMs from vCenter and add to hash table, assume Unprotected
$vms=@{}
foreach ($vm in ($vmobjs | where {$_.Name -notmatch $excludevms_regex}))  {
	if(!$vms.ContainsKey($vm.JobObjId)) {
		$vms.Add($vm.JobObjId, @("!", [string]$vm.GetParent("Datacenter"), $vm.Name))
    }
}

# Find all backup job sessions that have ended in the last 24 hours
$vbrjobs = Get-VBRJob | Where-Object {$_.JobType -eq "Backup"}
$vbrsessions = Get-VBRBackupSession | Where-Object {$_.JobType -eq "Backup" -and $_.EndTime -ge (Get-Date).addhours(-$HourstoCheck)}

if (!$vbrsessions) {
    write-host "No backup sessions found in last" $HourstoCheck "Hours!"
    exit
}

# Find all successfully backed up VMs in selected sessions (i.e. VMs not ending in failure) and update status to "Protected"
foreach ($session in $vbrsessions) {
    foreach ($vm in ($session.gettasksessions() | Where-Object {$_.Status -ne "Failed"} | ForEach-Object { $_ })) {
        if($vms.ContainsKey($vm.Info.ObjectId)) {
            $vms[$vm.Info.ObjectId][0]=$session.JobName
        }
    }
}

$vms = $vms.GetEnumerator() | Sort-Object Value

# Output VMs in color coded format based on status.
foreach ($vm in $vms)
{
  if ($vm.Value[0] -ne "!") {
      write-host -foregroundcolor green (($vm.Value[1]) + "\" + ($vm.Value[2])) "is backed up in job:" $vm.Value[0]
  } else {
      write-host -foregroundcolor red (($vm.Value[1]) + "\" + ($vm.Value[2])) "is not found in any backup session in the last" $HourstoCheck "hours"
  }
}
