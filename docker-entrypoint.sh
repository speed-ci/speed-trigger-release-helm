#!/bin/bash
set -e

source /init.sh

printmainstep "Déclenchement de la release des microservices"
printstep "Vérification des paramètres d'entrée"
init_env
int_gitlab_api_env

DOCKER_DIR=docker
SERVICE_EXT=.service
if [ ! -d $DOCKER_DIR ]; then
    printerror "Impossible de trouver le dossier $DOCKER_DIR contenant les services docker dans le projet"
    exit 1
else
    SERVICE_LIST=$DOCKER_DIR/*$SERVICE_EXT
    for SERVICE in $SERVICE_LIST
    do
        PROJECT_DEPLOY_NAME=$(basename "$SERVICE" $SERVICE_EXT)
        PROJECT_DEPLOY_ID=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects?search=$PROJECT_DEPLOY_NAME" | jq .[0].id`
        
        if [[ $PROJECT_DEPLOY_ID != "null" ]]; then
        
            printstep "Préparation du lancement du job release sur le projet $PROJECT_DEPLOY_NAME"
            LAST_COMMIT_ID=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_DEPLOY_ID/repository/commits?per_page=1&page=1" | jq .[0].id | tr -d '"'`
            JOB_RELEASE_ID=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_DEPLOY_ID/jobs" | jq --arg commit_id "$LAST_COMMIT_ID" '.[] | select(.commit.id == "\($commit_id)" and .name == "release" and .status == "manual" and .ref == "master")' | jq .id`
            echo "JOB_RELEASE_ID : $JOB_RELEASE_ID"
        
            if [[ -n $JOB_RELEASE_ID ]]; then
                printinfo "Déclenchement de la release sur le projet $PROJECT_DEPLOY_NAME"
                curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" -XPOST "$GITLAB_API_URL/projects/$PROJECT_DEPLOY_ID/jobs/$JOB_RELEASE_ID/play" | jq .
            else
                printwarn "Pas de déclenchement de release possible, le projet $PROJECT_DEPLOY_NAME ne dispose pas de job release disponible pour le commit $LAST_COMMIT" 
            fi
        
        else
            printerror "Pas de déclenchement de release possible, le projet $PROJECT_DEPLOY_NAME n'existe pas"
            exit 1
        fi
    done
fi

exit 1

