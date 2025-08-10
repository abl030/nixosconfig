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


Ok, so it would seem we don't need anything for the IGPU passthrough. At all. You can just use a clean system!!
And in Proxmox9 the updated kernel actually has our realtek nic's firmware. So we don't need the usb dongle, and nor do we need our dkms script to bootstrap the firmware in!!
Everything is no much much much more streamlined on Prom and the state being managed by ansible is significantly less.
1. Run Proxmox Post-Install and the Microcode Update script.
2. Join the cluster
3. Zpool import -f nvmeprom
4. Run passthrough_igpu2.yml - all this does is download for vbios files.
5. Run Patch_igpu_reset_PVE9 - this adds in the vendor-reset module, patched for granite ridge.

And thats it, if you add in the vbios file for any vm utilising the igpu it will succeed and as long as you turn off the vm in a normal manner the igpu will reset properly and you are good to go.
