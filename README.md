zonesync
========

# Desscription
Syncing zone between 2 systems for cold standby

# Prerequisites

* Passwordless ssh root access 

# Example crontab entry
0 7 * * * /usr/bin/zonesync <zone> <remote system>
