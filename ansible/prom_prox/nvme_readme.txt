Why these choices (brief)

nvme_core.default_ps_max_latency_us=0: disables APST completely first. This removes D3/L1.2 transitions that commonly cause transient link drops behind PCIe switches. Once stable, you can raise to 5500 µs to allow shallow low-power states.

Runtime apply + idempotent persistence: you can test immediately (no reboot), and the kernel cmdline ensures the behavior persists across reboots.

power/control=on via udev + oneshot service: prevents PCI runtime suspend (D3hot/D3cold) on NVMe class 0x010802, stopping long wake latencies that look like device drops.

Optional ASPM policy: only applied if you set pcie_aspm_policy. Leaving it blank avoids global changes unless needed. If problems persist, set pcie_aspm_policy: "off".

Idempotent cmdline edits: negative-lookahead replace means “append only if missing,” avoiding duplicate tokens and unnecessary reboots.

Conditional reboot: we only reboot when cmdline actually changed.

Reboot will hang, and we need to run the script like this:

ANSIBLE_FORCE_TTY=0 \
ansible-playbook -i inventory.ini nvme.yml \
  -e ansible_user=root \
  -e ansible_become=false \
  -e ansible_ssh_pipelining=true \
  --ssh-extra-args='-o RequestTTY=no'

Also there are some duplicate somethings somethings.
This script needs work. but lets see if our nvme drive drops out again first.

