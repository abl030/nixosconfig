Ok so, copy across the authorized keys file and the config files.
We'll track these with git for now in this manner for home manager installs.
I am super annoyed it has to be this way but I couldn't get that authorized keys file to get the right permissions.
The config file is to remind me how to use jump hosts. I don't want passwords open on SSH but i need to use caddy as a jumpy host for z11 forwarding.
Thus to simply get the _clipboard_ to work in ssh sessions we need to set and manage key files for all our hosts.
Connected through tailscale then jump through ourselves into the other sshd serve that has X11 enabled.
Its a shitshow. So for now we've set this up until home-manager enables authorized keys automatically or tailscale enalbes us to toggle x11 though ssh.


