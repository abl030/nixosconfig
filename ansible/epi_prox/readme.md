# Proxmox Host & VM Ansible Playbooks

## Project Overview

This folder contains two Ansible playbooks designed to configure a Proxmox host and a specific VM for reliable Intel Arc GPU passthrough. The configuration solves a critical hardware reset bug present in the Intel Arc A310 GPU, which lacks support for standard Function-Level Reset (FLR).

1.  **`gpu.yml`**: Configures the Proxmox host. It sets the required kernel parameters, blacklists native drivers to prevent conflicts, and configures VFIO modules. It includes an automatic reboot if critical changes are made.
2.  **`configure_vm_hook.yml`**: Configures a specific VM after it has been created. It creates and applies a Proxmox `pre-start` hook script that performs a forceful "PCI remove and rescan" cycle on the GPU. This action is the key to recovering the GPU from a hung state, which occurs after a guest-initiated reboot.

---

## Playbook Usage

1.  **Host Setup**:
    Run `gpu.yml` to prepare the entire Proxmox host. This only needs to be done once. The playbook will handle the required host reboot automatically.
    ```bash
    ansible-playbook -i inventory.ini gpu.yml
    ```

2.  **VM Hook Configuration**:
    After creating your passthrough VM, edit the `vars` section in `configure_vm_hook.yml` to match your VM's ID and PCI addresses. Then, run the playbook. No reboot is required.
    ```bash
    ansible-playbook -i inventory.ini configure_vm_hook.yml
    ```

---

## The Problem & The Solution: A Debugging Journey

The primary challenge was making an Intel Arc A310 GPU work reliably for passthrough to a VM. The initial symptom was intermittent failure: the VM would work after a host reboot, but would fail to produce video output after a guest reboot, requiring a full host reboot to recover.

Our debugging revealed the following:
*   The GPU (`lspci -vvv`) reported `FLReset-`, confirming it **lacks support for Function-Level Reset**. This is the root cause of the problem, as the host cannot cleanly reset the device between uses.
*   A guest reboot leaves the GPU in a "hung" or "dirty" state.
*   Standard fixes like blacklisting native drivers were necessary but insufficient.
*   Advanced `vfio-pci` options like `reset_method=bus` were ineffective because the host kernel version did not support the parameter.
*   A simple driver `unbind/bind` was not powerful enough to recover the deeply hung card.

The **eventual solution** was to use a Proxmox hook script that runs before the VM starts. This script performs the most forceful software reset possible:
1.  It tells the kernel to **remove** the GPU from the PCI bus (`echo 1 > /sys/.../remove`).
2.  It then tells the kernel to **rescan** the parent PCI bridge (`echo 1 > /sys/.../rescan`).

This "remove and rescan" cycle is the software equivalent of unplugging and replugging the card, forcing a complete re-initialization and clearing the hung state. This script, applied via the `configure_vm_hook.yml` playbook, makes the passthrough stable and reliable.

---

## Prompt for Future AI Assistance

(Copy and paste the text below to quickly provide context for future troubleshooting.)

```text
I am running a Proxmox host with an Intel Arc A310 GPU passed through to a VM (ID 101). I have already solved a major hardware reset issue and have a working Ansible setup.

Here is the summary of the situation:

1.  **Problem:** The Intel Arc A310 GPU lacks Function-Level Reset (FLR-). This caused the GPU to enter a hung state after a guest reboot, requiring a full host reboot to recover.
2.  **Failed Attempts:** We tried blacklisting drivers (necessary but insufficient), using the `reset_method=bus` vfio-pci option (unsupported by the kernel), and a simple driver `unbind/bind` script (insufficient to clear the hang).
3.  **Working Solution:** The definitive solution is a Proxmox `pre-start` hook script. This script performs a forceful PCI "remove and rescan" (`echo 1 > /sys/bus/pci/devices/.../remove` followed by `echo 1 > /sys/bus/pci/devices/.../rescan`) on the GPU and its parent PCI bridge just before the VM starts.
4.  **Current State:** This solution is implemented via two Ansible playbooks: `gpu.yml` for base host setup and `configure_vm_hook.yml` to apply the specific reset script to the VM. This setup is stable and works perfectly, even when using the "Reboot" button in the Proxmox web UI, as the UI action triggers the stop/start cycle and therefore runs the hook script.

My current query is about [INSERT YOUR NEW QUESTION HERE].
