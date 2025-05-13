# updatarr
Use the radarr and/or sonarr API to search for films/series

> [!Warning]
> The script is currently only compatible with radarr, sonarr will be soon

# Installation
1/ Download the "bash" directory into your server

2/ Sets execution permissions on both scripts
```bash
chmod +x install.sh
chmod +x search.sh
```

3/ Run `install.sh` script

4/ Test with `search.sh` script

5/ DONE, you can set up a scheduled task (cron or other) to run the script periodically

# How it works

The script will retrieve the list of missing films, sort them by date of addition from the most recent to the oldest, and search for the first

It will save the film ID, so that it can be passed on the next time the script is run (via cron for example), which will then search for the second etc...

Once all the films have been searched, the script will start again from the beginning

# Planned improvements

- Sonarr compatibility

- Search for films with “unsatisfactory limit” when all missing films have been searched

- All suggestions are welcome!