# VM Management Library
# =====================
#
# Pure Nix functions for VM configuration management and safety checks.
# These functions work with the definitions in vms/definitions.nix.

{ lib, ... }:

with lib;

rec {
  # Load VM definitions from definitions.nix
  # Returns the full definitions structure
  loadDefinitions = import ./definitions.nix;

  # Get all VMIDs that are marked as readonly (imported)
  # Returns: list of integers [104, 109]
  getReadonlyVMIDs = defs:
    let
      imported = defs.imported or {};
      readonlyVMs = filterAttrs (_: vm: vm.readonly or false) imported;
    in
      map (vm: vm.vmid) (attrValues readonlyVMs);

  # Get all VMIDs that are managed
  # Returns: list of integers
  getManagedVMIDs = defs:
    let
      managed = defs.managed or {};
    in
      map (vm: vm.vmid) (attrValues managed);

  # Get all VMIDs (readonly + managed)
  # Returns: list of integers
  getAllDefinedVMIDs = defs:
    (getReadonlyVMIDs defs) ++ (getManagedVMIDs defs);

  # Check if a VMID is readonly/imported
  # Returns: bool
  isReadonlyVMID = defs: vmid:
    elem vmid (getReadonlyVMIDs defs);

  # Check if a VMID is managed
  # Returns: bool
  isManagedVMID = defs: vmid:
    elem vmid (getManagedVMIDs defs);

  # Check if a VMID is defined at all
  # Returns: bool
  isDefinedVMID = defs: vmid:
    elem vmid (getAllDefinedVMIDs defs);

  # Get VM definition by name from managed VMs
  # Returns: attrset or null
  getManagedVM = defs: name:
    let
      managed = defs.managed or {};
    in
      managed.${name} or null;

  # Get VM definition by name from imported VMs
  # Returns: attrset or null
  getImportedVM = defs: name:
    let
      imported = defs.imported or {};
    in
      imported.${name} or null;

  # Get VM definition by name from either managed or imported
  # Returns: attrset with additional _type field ("managed" or "imported")
  getVM = defs: name:
    let
      managed = getManagedVM defs name;
      imported = getImportedVM defs name;
    in
      if managed != null then
        managed // { _type = "managed"; _name = name; }
      else if imported != null then
        imported // { _type = "imported"; _name = name; }
      else
        null;

  # Safety check: verify operation is allowed on a VM
  # Throws an error if trying to modify a readonly VM
  # Returns: bool (true if allowed, throws if not)
  assertVMOperationAllowed = defs: vmid: operation:
    let
      readonly = isReadonlyVMID defs vmid;
      managed = isManagedVMID defs vmid;
      readonlyOps = ["status" "list" "config" "get"]; # Safe read-only operations
      isReadOnlyOp = any (op: hasInfix op operation) readonlyOps;
    in
      if readonly && !isReadOnlyOp then
        throw ''
          SAFETY ERROR: VMID ${toString vmid} is marked as READONLY (imported).
          Operation '${operation}' is not allowed on imported VMs.

          This VM is documented for inventory purposes only.
          If you need to manage this VM, move it from 'imported' to 'managed' in vms/definitions.nix.

          Allowed operations on readonly VMs: status, list, config, get
        ''
      else
        true;

  # Get next available VMID in a range
  # Returns: integer
  getNextVMID = defs: usedVMIDs: rangeStart: rangeEnd:
    let
      definedVMIDs = getAllDefinedVMIDs defs;
      allUsedVMIDs = definedVMIDs ++ usedVMIDs;
      isAvailable = vmid: !(elem vmid allUsedVMIDs);
      candidates = range rangeStart rangeEnd;
      availableVMIDs = filter isAvailable candidates;
    in
      if availableVMIDs == [] then
        throw "No available VMIDs in range ${toString rangeStart}-${toString rangeEnd}"
      else
        head availableVMIDs;

  # Suggest next VMID based on allocation strategy
  # Returns: integer
  suggestNextVMID = defs: usedVMIDs:
    let
      ranges = defs.vmidRanges or {};
      productionRange = ranges.production or { start = 100; end = 199; };
    in
      getNextVMID defs usedVMIDs productionRange.start productionRange.end;

  # Validate VM definition structure
  # Returns: list of error messages (empty if valid)
  validateVMDefinition = name: vm:
    let
      errors = []
        ++ (optional (!(vm ? vmid)) "Missing required field: vmid")
        ++ (optional (!(vm ? cores)) "Missing required field: cores")
        ++ (optional (!(vm ? memory)) "Missing required field: memory")
        ++ (optional (!(vm ? disk)) "Missing required field: disk")
        ++ (optional (vm ? vmid && vm.vmid < 100) "VMID must be >= 100")
        ++ (optional (vm ? vmid && vm.vmid >= 10000) "VMID must be < 10000")
        ++ (optional (vm ? cores && vm.cores < 1) "cores must be >= 1")
        ++ (optional (vm ? memory && vm.memory < 512) "memory must be >= 512 MB");
    in
      errors;

  # Validate all managed VM definitions
  # Returns: attrset of { vmName = [errors]; }
  validateAllManagedVMs = defs:
    let
      managed = defs.managed or {};
      validations = mapAttrs validateVMDefinition managed;
      withErrors = filterAttrs (_: errors: errors != []) validations;
    in
      withErrors;

  # Generate a summary of VM definitions for display
  # Returns: string
  summarizeDefinitions = defs:
    let
      imported = defs.imported or {};
      managed = defs.managed or {};
      template = defs.template or {};
      importedCount = length (attrNames imported);
      managedCount = length (attrNames managed);
      readonlyVMIDs = getReadonlyVMIDs defs;
      managedVMIDs = getManagedVMIDs defs;
    in
      ''
        VM Definitions Summary
        ======================
        Imported VMs: ${toString importedCount} (VMIDs: ${toString readonlyVMIDs})
        Managed VMs:  ${toString managedCount}${optionalString (managedCount > 0) " (VMIDs: ${toString managedVMIDs})"}
        Template:     ${template.name or "unknown"} (VMID: ${toString (template.vmid or 0)})

        Proxmox Host: ${defs.proxmox.host or "unknown"}@${defs.proxmox.node or "unknown"}
        Storage:      ${defs.proxmox.defaultStorage or "unknown"}
      '';

  # Generate VM configuration for cloud-init
  # Returns: attrset with cloud-init configuration
  generateCloudInitConfig = vm: sshKeys:
    {
      hostname = vm.hostname or vm._name or "nixos";
      user = "root";
      ssh_authorized_keys = sshKeys;
      # Disable password authentication
      chpasswd = {
        expire = false;
      };
      # Basic network configuration (DHCP)
      network = {
        version = 2;
        ethernets.eth0.dhcp4 = true;
      };
    };

  # Format VM specs for display
  # Returns: string
  formatVMSpecs = vm:
    let
      specs = vm.specs or vm;
      cores = specs.cores or vm.cores or "?";
      memory = specs.memory or vm.memory or "?";
      memGB = if isInt memory then toString (memory / 1024) else memory;
      disk = specs.disk or vm.disk or "?";
      storage = specs.storage or vm.storage or "default";
    in
      "${toString cores} cores, ${memGB} GB RAM, ${disk} disk (${storage})";
}
