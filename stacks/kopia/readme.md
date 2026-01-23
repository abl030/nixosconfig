This kopia every three hours will backup /photos to wasabi.
This is an interim option until we finalise our real zfs backups, but it felt too important not 
to have an up-to-date offsite.

I still don't quite understand how kopia manages configurations. Because if you move your config directory, while pointing the docker compose file to the new directory, then the kopia docker image will complain that it has the wrong password for the repository. I am assuming its the remote repo? BEcause our local repo is stored in our .env file.
Long story short though is its generally just easier to imagine your kopia config living on the remote repo. Docker images and config files are ephemeral. As long as you mount all the directories in the same place here, then its just easier to re-connect to the remote repo and start again when things go wrong.

