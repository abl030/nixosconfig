I thought long and hard about this one, and the most 'proxmoxy' thing to do would be an lxc container, but that became too difficult to maintain, in the homelab space we've settled on docker so that's what I need to use. Unfortunately i will not get a single pane of glass. But it will only be for GPU requiring things.
If I went to a vm for this then I would be passing throgh the IGPU and this poses many many problems. not least of all the difficults of not being able to put a monitor on my rack to diagnose problems, especially since my ethernet nix is not in the proxmox base kernel, on upgrades I may need to fix this without internet access. If I was passing through my IGPU and got to this point, I might brick my server. 
So docker it is.

Remember this compose file will be for running on the proxmox host itself!!!!


