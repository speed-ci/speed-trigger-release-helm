#!/bin/bash
set -e

source /init.sh

printmainstep "Déclenchement de la release des microservices"
printstep "Vérification des paramètres d'entrée"
init_env

echo "REPO_URL: $REPO_URL"
echo "GITLAB_URL: $GITLAB_URL"
echo "GITLAB_API_URL: $GITLAB_API_URL"

exit 1

