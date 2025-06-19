# X870 Taichii-Lite w/ 9950x Proxmox Journey
where to start!

This took a long time.

So, when you want to start up this machine from scratch here's the bios setting we've come to:

Summary of CRITICAL Settings for Proxmox + GPU Passthrough:

    OC Tweaker -> DRAM Profile: EXPO/XMP Enabled

    Advanced -> CPU Configuration -> SVM Mode: Enabled

    Advanced -> PCI Configuration -> Above 4G Decoding: Enabled

    Advanced -> AMD CBS -> NBIO Common Options -> IOMMU: Enabled

    Advanced -> AMD PBS -> Primary Video Adaptor: Int Graphics (IGD) (if using iGPU for host)

    Security -> Secure Boot: Disabled

    Boot -> CSM: Disabled

    Boot -> Fast Boot: Disabled


Next we tried to replicate the proxmox post install helper script https://community-scripts.github.io/ProxmoxVE/scripts?id=post-pve-install but whats the point, it ended up with too many errors and just why. 

So first step, 

## Generate SSH KEY and copy
ssh-keygen -t ed25519

ssh-copy-id root@192.168.1.26

Now note that we've set the usb NIC to a static ip as the management network as dkms is not flawless, when upgrading to 6.14 kernel we lost headers and couldn't install them easily. This borked our realtek drivers.

SSH into the machine, run the proxmox post install script:

bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"

## Ansible

01 - Update Microcode (this is to the latest for our 9950x)

02 - realtek_dkms (install the driver with the dkms shim - not foolproof but good enough)

03 - post_realtek (sets up our two bridges, one for the management nic and the other for the main nic. TODO: to make this better put the management nic on another VLAN)

04 - Passthrough_nvid - sets up passthrough for our nvidia 1080. As we add or change device this will need to change. 

## Optional

Well we could join clusters, this is the next frontier for now.

## Old

In the old folder is our attempt at replicating the post install script as well as a passthrough script for both the igpu and the 1080. We managed to get the igpu to pass through effectively and it was quite good, the template for the vm is in the templates folder.

However the problem was the reset bug, if we simpy shutdown the vm cleanly, it would boot up fine. But if we 'stopped' the vm to simulate a crash then the gpu would never reset. So you'd have to reset the host to reset that state.

If, for instance I've got plex in that vm doing transcoding on the igpu having to reset my whole proxmox host sounds absolutely horrible. 

For now I have decided to go with lxc containers, however, as with everything this remains a work in progress I haven't even started yet.


vim.api.nvim_clear_autocmds({ group = "nvim_lint", buffer = 0 })

