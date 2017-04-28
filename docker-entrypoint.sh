#!/bin/bash
set -e

source /init.sh

printmainstep "Déclenchement de la release des microservices"
printstep "Vérification des paramètres d'entrée"
init_env

DOCKER_DIR=docker
if [ ! -d $DOCKER_DIR ]; then
    printerror "Impossible de trouver le dossier $DOCKER_DIR contenant les services docker dans le projet"
    exit 1
else
    ls -l $DOCKER_DIR
fi

exit 1

