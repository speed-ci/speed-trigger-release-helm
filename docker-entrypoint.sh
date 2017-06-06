#!/bin/bash
set -e

source /init.sh

printmainstep "Déclenchement de la release des microservices"
printstep "Vérification des paramètres d'entrée"
init_env
int_gitlab_api_env
GITLAB_CI_USER="gitlab-ci-sln"

DOCKER_DIR=docker
SERVICE_EXT=.serv
if [ ! -d $DOCKER_DIR ]; then
    printerror "Impossible de trouver le dossier $DOCKER_DIR contenant les services docker dans le projet"
    exit 1
else
    SERVICE_LIST=$DOCKER_DIR/*$SERVICE_EXT
    for SERVICE in $SERVICE_LIST
    do
        PROJECT_RELEASE_NAME=$(basename "$SERVICE" $SERVICE_EXT)
        if [[ $PROJECT_RELEASE_NAME == "*" ]]; then
            printerror "Aucun service docker trouvé respectant le format $SERVICE_LIST"
            exit 1
        fi
        
        printinfo "PROJECT_NAMESPACE    : $PROJECT_NAMESPACE"
        printinfo "PROJECT_RELEASE_NAME : $PROJECT_RELEASE_NAME"
        
        PROJECT_RELEASE_ID=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects?search=$PROJECT_RELEASE_NAME" | jq --arg project_namespace "$PROJECT_NAMESPACE" '.[] | select(.namespace.name == "\($project_namespace)")' | jq .id`
        
        if [[ $PROJECT_RELEASE_ID != "null" ]]; then
        
            printstep "Préparation du projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME"
            GITLAB_CI_USER_ID=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/users?username=$GITLAB_CI_USER" | jq .[0].id`
            GITLAB_CI_USER_MEMBERSHIP=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/members?query=$GITLAB_CI_USER" | jq .[0]`
            if [[ $GITLAB_CI_USER_MEMBERSHIP == "null" ]]; then 
                printinfo "Ajout du user $GITLAB_CI_USER manquant au projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME"
                curl --silent --noproxy '*' --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/members" -d "user_id=$GITLAB_CI_USER_ID" -d "access_level=40"
            fi
        
            printstep "Préparation du lancement du job release sur le projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME"
            LAST_COMMIT_ID=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/repository/commits?per_page=1&page=1" | jq .[0].id | tr -d '"'`
            LAST_PIPELINE_ID=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/pipelines?per_page=1&page=1" | jq .[0].id  | tr -d '"'`
            JOB_RELEASE_ID=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs" | jq --arg commit_id "$LAST_COMMIT_ID" --arg pipeline_id "$LAST_PIPELINE_ID" '.[] | select(.commit.id == "\($commit_id)" and (.pipeline.id | tostring  == "\($pipeline_id)")  and .name == "release" and .ref == "master")' | jq .id | head -1`
        
            if [[ $JOB_RELEASE_ID != "" ]]; then
                printstep "Déclenchement de la release sur le projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME pour le commit $LAST_COMMIT_ID"
                JOB_RELEASE_STATUS=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID" | jq .status | tr -d '"'`
                printinfo "LAST_PIPELINE_ID   : $LAST_PIPELINE_ID"
                printinfo "JOB_RELEASE_ID     : $JOB_RELEASE_ID"
                printinfo "JOB_RELEASE_STATUS : $JOB_RELEASE_STATUS"
                if [[ $JOB_RELEASE_STATUS == "skipped" ]]; then
                    printerror "Les étapes préalables à la release doivent être effectuées avec succès, release interrompue"
                    exit 1
                elif [[ $JOB_RELEASE_STATUS == "success" ]]; then
                    printinfo "Le job release est déjà un succès, relancement inutile"
                elif [[ $JOB_RELEASE_STATUS == "manual" ]]; then
                    curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" -XPOST "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID/play" | jq .
                else
                    curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" -XPOST "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID/retry" | jq .
                fi
            else
                printwarn "Pas de déclenchement de release possible, le projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME ne dispose pas de job release disponible pour le commit $LAST_COMMIT_ID" 
            fi
        
        else
            printerror "Pas de déclenchement de release possible, le projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME n'existe pas"
            exit 1
        fi
    done
fi

exit 1

