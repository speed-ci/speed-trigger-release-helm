#!/bin/bash
set -e

source /init.sh

printmainstep "Déclenchement de la release des microservices"
printstep "Vérification des paramètres d'entrée"
init_env

DOCKER_DIR=dockererr
if [ ! -d $DOCKER_DIR ]; then
    printerror "Impossible de trouver le dossier contenant les unit systemd docker $CONF_DIR dans le projet"
    exit 1
else
    ls -l $DOCKER_DIR
fi

exit 1

