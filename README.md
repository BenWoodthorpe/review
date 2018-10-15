# dbaReview
Usage:
--user <username>      Specify user
--pass <password>      Specify password
--host <host>          Specify IP/host
--port <port number>   Specify Port number ### New to be added
--socket <socket>      Specify socket
--help                 Usage
--update               Update to latest version
--csv                  Output in CSV format

If no user or password is supplied, this script will attempt to login using
either Plesk credentials (if installed) or as a fallback it will check ~/.my.cnf.
