# Count regular SSH connections
ssh_count=$(netstat -nt | awk '$4 ~ /:22$/ && $6 == "ESTABLISHED"' | wc -l)

# Count Tailscale SSH connections
ts_count=$(who | grep -c "pts/")

echo $((ts_count))
