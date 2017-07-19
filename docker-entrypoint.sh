#!/bin/bash
set -e

source /init.sh

printmainstep "Déclenchement de la release de tous les microservices"
printstep "Vérification des paramètres d'entrée"
init_env
int_gitlab_api_env

GITLAB_CI_USER="gitlab-ci-sln"
POLLLING_PERIOD=5
DOCKER_DIR=docker
SERVICE_EXT=.serv

if [ ! -d $DOCKER_DIR ]; then
    printerror "Impossible de trouver le dossier $DOCKER_DIR contenant les services docker dans le projet"
    exit 1
fi    

declare -A PROJECT_RELEASE_IDS
declare -A LAST_COMMIT_IDS
declare -A PROJECT_RELEASE_VERSIONS
declare -A JOB_RELEASE_IDS
declare -A JOB_RELEASE_STATUSES

printstep "Préparation du projet $PROJECT_NAMESPACE/$PROJECT_NAME"

if [[ -z $RELEASE_VERSION ]]; then
    printerror "La variable secrète RELEASE_VERSION doit être renseignée par un utilisateur master du projet $PROJECT_NAMESPACE/$PROJECT_NAME dans le menu Settings / CI/CD Pipelines" 
    exit 1
fi

FOUND_TAG=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/tags/$RELEASE_VERSION" | jq .name | tr -d '"'`
echo "RELEASE_VERSION : $RELEASE_VERSION"
echo "FOUND_TAG : $FOUND_TAG"
if [[ $FOUND_TAG != "null" ]]; then
    printerror "La version $FOUND_TAG du projet $PROJECT_NAMESPACE/$PROJECT_NAME existe déjà, un utilisateur master du projet doit mettre à jour la variable secrète RELEASE_VERSION dans le menu Settings / CI/CD Pipelines" 
    exit 1
fi

PROJECT_ID=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects?search=$PROJECT_NAME" | jq --arg project_namespace "$PROJECT_NAMESPACE" '.[] | select(.namespace.name == "\($project_namespace)")' | jq .id`
RELEASE_BRANCH=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/branches/release" | jq .name`

if [[ $RELEASE_BRANCH == "null" ]]; then
	printinfo "Création de la branch release manquante sur le projet $PROJECT_NAMESPACE/$PROJECT_NAME"
	curl --silent --noproxy '*' --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/branches" -d "branch=release" -d "ref=master" | jq .

else
	LAST_NEW_COMMIT=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/compare?from=release&to=master" | jq .commit.id | tr -d '"'`
	if [[ $LAST_NEW_COMMIT != "null" ]]; then
		printinfo "Mise à jour de la branch release avec les derniers commits de master"
		MR_IID=`curl --silent --noproxy '*' --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/merge_requests" -d "source_branch=master" -d "target_branch=release" -d "title=chore(release): Update release branch with $LAST_NEW_COMMIT to prepare release" | jq .iid`
		curl --silent --noproxy '*' --request PUT --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/merge_requests/$MR_IID/merge" | jq .
	fi
fi

SERVICE_LIST=$DOCKER_DIR/*$SERVICE_EXT
for SERVICE in $SERVICE_LIST
do
    PROJECT_RELEASE_NAME=$(basename "$SERVICE" $SERVICE_EXT)
    if [[ $PROJECT_RELEASE_NAME == "*" ]]; then
        printerror "Aucun service docker trouvé respectant le format $SERVICE_LIST"
        exit 1
    fi
    
    printmainstep "Déclenchement de la release du microservice $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME"
    
    PROJECT_RELEASE_ID=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects?search=$PROJECT_RELEASE_NAME" | jq --arg project_namespace "$PROJECT_NAMESPACE" '.[] | select(.namespace.name == "\($project_namespace)")' | jq .id`
    PROJECT_RELEASE_IDS[$PROJECT_RELEASE_NAME]=$PROJECT_RELEASE_ID
    
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
        LAST_COMMIT_IDS[$PROJECT_RELEASE_NAME]=$LAST_COMMIT_ID
        LAST_PIPELINE_ID=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/pipelines?per_page=1&page=1" | jq .[0].id  | tr -d '"'`
        JOB_RELEASE_ID=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs" | jq --arg commit_id "$LAST_COMMIT_ID" --arg pipeline_id "$LAST_PIPELINE_ID" '.[] | select(.commit.id == "\($commit_id)" and (.pipeline.id | tostring  == "\($pipeline_id)")  and .name == "release" and .ref == "master")' | jq .id | head -1`
        JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]=$JOB_RELEASE_ID
    
        if [[ $JOB_RELEASE_ID != "" ]]; then
            printstep "Déclenchement de la release sur le projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME pour le dernier commit $LAST_COMMIT_ID"
            JOB_RELEASE_STATUS=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID" | jq .status | tr -d '"'`
            printinfo "LAST_PIPELINE_ID   : $LAST_PIPELINE_ID"
            printinfo "JOB_RELEASE_ID     : $JOB_RELEASE_ID"
            printinfo "JOB_RELEASE_STATUS : $JOB_RELEASE_STATUS"

            if [[ $JOB_RELEASE_STATUS == "skipped" ]]; then
                printerror "Les étapes préalables à la release doivent être effectuées avec succès, release interrompue"
                exit 1
            elif [[ $JOB_RELEASE_STATUS == "success" ]]; then
                echo ""
                printinfo "Le job release est déjà un succès, relancement inutile"
            elif [[ $JOB_RELEASE_STATUS == "manual" ]]; then
                JOB_RELEASE_ID=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" -XPOST "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID/play" | jq .id`
                JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]=$JOB_RELEASE_ID
                printinfo "JOB_RELEASE_ID     : $JOB_RELEASE_ID"
                printinfo "JOB_RELEASE_ID MAP : ${JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]}"
            else
                JOB_RELEASE_ID=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" -XPOST "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID/retry" | jq .id`
                JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]=$JOB_RELEASE_ID
                printinfo "JOB_RELEASE_ID MAP : ${JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]}"
            fi
        else
            printerror "Pas de déclenchement de release possible, le projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME ne dispose pas de job release disponible pour le commit $LAST_COMMIT_ID" 
            exit 1
        fi
    
    else
        printerror "Pas de déclenchement de release possible, le projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME n'existe pas"
        exit 1
    fi
done

sleep $POLLLING_PERIOD

while :
do
    HAS_RUNNING=false
    for SERVICE in $SERVICE_LIST
    do
        PROJECT_RELEASE_NAME=$(basename "$SERVICE" $SERVICE_EXT)
        PROJECT_RELEASE_ID=${PROJECT_RELEASE_IDS[$PROJECT_RELEASE_NAME]}
        JOB_RELEASE_ID=${JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]}
        JOB_RELEASE_STATUS=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID" | jq .status | tr -d '"'`
        JOB_RELEASE_STATUSES[$PROJECT_RELEASE_NAME]=$JOB_RELEASE_STATUS
        if [[ $JOB_RELEASE_STATUS == "pending" ]] || [[ $JOB_RELEASE_STATUS == "running" ]]; then HAS_RUNNING=true; fi
        printinfo "JOB_RELEASE_STATUS : $JOB_RELEASE_STATUS"
    done
    
    if [[ $HAS_RUNNING == "false" ]]; then break; fi
    printinfo "HAS_RUNNING : $HAS_RUNNING : [[ $HAS_RUNNING == "false" ]]"
    sleep $POLLLING_PERIOD
done

printmainstep "Affichage des résultats des jobs de release"
HAS_FAILED_JOB=false
for SERVICE in $SERVICE_LIST
do
    PROJECT_RELEASE_NAME=$(basename "$SERVICE" $SERVICE_EXT)
    PROJECT_RELEASE_ID=${PROJECT_RELEASE_IDS[$PROJECT_RELEASE_NAME]}
    JOB_RELEASE_ID=${JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]}
    JOB_RELEASE_STATUS=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID" | jq .status | tr -d '"'`

    printinfo "Status final du job release du projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME : $JOB_RELEASE_STATUS"
    printinfo "Lien d'accès aux logs distants : $GITLAB_URL/$PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME/builds/$JOB_RELEASE_ID"

    LAST_COMMIT_ID=${LAST_COMMIT_IDS[$PROJECT_RELEASE_NAME]}
    PROJECT_RELEASE_VERSION=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/repository/tags" | jq --arg commit_id "$LAST_COMMIT_ID" '.[] | select(.commit.id == "\($commit_id)")' | jq .name | tr -d '"'`
    PROJECT_RELEASE_VERSIONS[$PROJECT_RELEASE_NAME]=$PROJECT_RELEASE_VERSION
    
    printinfo "Version applicative générée : $PROJECT_RELEASE_VERSION"
    echo ""
    
    if [[ $JOB_RELEASE_STATUS != "success" ]]; then HAS_FAILED_JOB=true; fi
done    

echo "HAS_RUNNING : $HAS_RUNNING"
echo "HAS_FAILED_JOB : $HAS_FAILED_JOB"


if [[ $HAS_FAILED_JOB == "true" ]]; then exit 1; fi

