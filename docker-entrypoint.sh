#!/bin/bash
set -e

printmainstep "Déclenchement de la release des microservices"
printstep "Vérification des paramètres d'entrée"

init_env
REPO_URL=$(git config --get remote.origin.url | sed 's/\.git//g' | sed 's/\/\/.*:.*@/\/\//g')
GITLAB_URL=`echo $REPO_URL | grep -o 'https\?://[^/]\+/'`
GITLAB_API_URL="$GITLAB_URL/api/v4"

exit 1

