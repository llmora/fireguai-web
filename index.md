# Installing fireguai

fireguai has been packaged as a set of docker containers, make sure you have `docker` and `docker-compose` installed and run the following commands to install:

```
$ curl -Lso fireguai.sh "https://raw.githubusercontent.com/llmora/fireguai-web/master/fireguai.sh" \
  && chmod +x fireguai.sh
$ ./fireguai.sh install
```

At the end of the installation the password for the default admin account is produced, take note of it as you will need it to access the fireguai application.

