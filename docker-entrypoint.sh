#!/bin/bash
set -e

myCurl() {
    HTTP_RESPONSE=`curl --silent --noproxy '*' --write-out "HTTPSTATUS:%{http_code}" "$@"`
    HTTP_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    if [[ ! $HTTP_STATUS -eq 200 ]] && [[ ! $HTTP_STATUS -eq 404 ]] && [[ ! $HTTP_STATUS -eq 201 ]]; then
        echo -e "\033[31mError [HTTP status: $HTTP_STATUS] \033[37m" 1>&2
        echo -e "\033[31mError [HTTP body: $HTTP_BODY] \033[37m" 1>&2
        echo "{\"error\"}"
        exit 1
    fi
    echo "$HTTP_BODY"
}

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

PROJECT_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects?search=$PROJECT_NAME" | jq --arg project_namespace "$PROJECT_NAMESPACE" '.[] | select(.namespace.name == "\($project_namespace)")' | jq .id`
FOUND_TAG=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/tags/$RELEASE_VERSION" | jq .name | tr -d '"'`
if [[ $FOUND_TAG != "null" ]]; then
    printerror "La version $FOUND_TAG du projet $PROJECT_NAMESPACE/$PROJECT_NAME existe déjà" 
    printerror "Un utilisateur master du projet doit mettre à jour à la version suivante la variable secrète RELEASE_VERSION dans le menu Settings / CI/CD Pipelines" 
    exit 1
fi

RELEASE_BRANCH=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/branches/release" | jq .name`

if [[ $RELEASE_BRANCH == "null" ]]; then
    printinfo "Création de la branche release manquante sur le projet $PROJECT_NAMESPACE/$PROJECT_NAME"
    myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/branches" -d "branch=release" -d "ref=master" | jq .

else
    LAST_NEW_COMMIT=`curl --silent --noproxy '*' --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/compare?from=release&to=master" | jq .commit.id | tr -d '"'`
    if [[ $LAST_NEW_COMMIT != "null" ]]; then
        printinfo "Mise à jour de la branche release avec les derniers commits de master"
        RELEASE_MR_IID=`curl --silent --noproxy '*' --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/merge_requests" -d "source_branch=master" -d "target_branch=release" -d "title=chore(release): Update release branch with $LAST_NEW_COMMIT to prepare release" | jq .iid`
        echo "RELEASE_MR_IID : $RELEASE_MR_IID"
        myCurl --request PUT --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/merge_requests/$RELEASE_MR_IID/merge" | jq .
    fi
fi


RECSMA_BRANCH=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/branches/recsma" | jq .name`

if [[ $RECSMA_BRANCH == "null" ]]; then
    printinfo "Création de la branche recsma manquante sur le projet $PROJECT_NAMESPACE/$PROJECT_NAME"
    myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/branches" -d "branch=recsma" -d "ref=release" | jq .
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
    
    PROJECT_RELEASE_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects?search=$PROJECT_RELEASE_NAME" | jq --arg project_namespace "$PROJECT_NAMESPACE" '.[] | select(.namespace.name == "\($project_namespace)")' | jq .id`
    PROJECT_RELEASE_IDS[$PROJECT_RELEASE_NAME]=$PROJECT_RELEASE_ID
    
    if [[ $PROJECT_RELEASE_ID != "null" ]]; then
    
        printstep "Préparation du projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME"
        GITLAB_CI_USER_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/users?username=$GITLAB_CI_USER" | jq .[0].id`
        GITLAB_CI_USER_MEMBERSHIP=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/members?query=$GITLAB_CI_USER" | jq .[0]`
        if [[ $GITLAB_CI_USER_MEMBERSHIP == "null" ]]; then 
            printinfo "Ajout du user $GITLAB_CI_USER manquant au projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME"
            myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/members" -d "user_id=$GITLAB_CI_USER_ID" -d "access_level=40"
        fi
    
        printstep "Préparation du lancement du job release sur le projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME"
        LAST_COMMIT_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/repository/commits?per_page=1&page=1" | jq .[0].id | tr -d '"'`
        LAST_COMMIT_IDS[$PROJECT_RELEASE_NAME]=$LAST_COMMIT_ID
        LAST_PIPELINE_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/pipelines?per_page=1&page=1" | jq .[0].id  | tr -d '"'`
        JOB_RELEASE_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs" | jq --arg commit_id "$LAST_COMMIT_ID" --arg pipeline_id "$LAST_PIPELINE_ID" '.[] | select(.commit.id == "\($commit_id)" and (.pipeline.id | tostring  == "\($pipeline_id)")  and .name == "release" and .ref == "master")' | jq .id | head -1`
        JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]=$JOB_RELEASE_ID
    
        if [[ $JOB_RELEASE_ID != "" ]]; then
            printstep "Déclenchement de la release sur le projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME pour le dernier commit $LAST_COMMIT_ID"
            JOB_RELEASE_STATUS=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID" | jq .status | tr -d '"'`
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
                JOB_RELEASE_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" -XPOST "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID/play" | jq .id`
                JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]=$JOB_RELEASE_ID
                printinfo "JOB_RELEASE_ID     : $JOB_RELEASE_ID"
                printinfo "JOB_RELEASE_ID MAP : ${JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]}"
            else
                JOB_RELEASE_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" -XPOST "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID/retry" | jq .id`
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
        JOB_RELEASE_STATUS=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID" | jq .status | tr -d '"'`
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
PAYLOAD=$(cat << 'JSON'
{
  "branch": "release",
  "actions": []
}
JSON
)

CHANGELOG=$(printf "### Versions des microservices\n")
PAYLOAD=`jq --arg commit_message "Update services versions for version $RELEASE_VERSION" '. | .commit_message=$commit_message' <<< $PAYLOAD`

for SERVICE in $SERVICE_LIST
do
    PROJECT_RELEASE_NAME=$(basename "$SERVICE" $SERVICE_EXT)
    PROJECT_RELEASE_ID=${PROJECT_RELEASE_IDS[$PROJECT_RELEASE_NAME]}
    JOB_RELEASE_ID=${JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]}
    JOB_RELEASE_STATUS=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID" | jq .status | tr -d '"'`

    printinfo "Status final du job release du projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME : $JOB_RELEASE_STATUS"
    printinfo "Lien d'accès aux logs distants : $GITLAB_URL/$PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME/builds/$JOB_RELEASE_ID"

    LAST_COMMIT_ID=${LAST_COMMIT_IDS[$PROJECT_RELEASE_NAME]}
    PROJECT_RELEASE_VERSION=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/repository/tags" | jq --arg commit_id "$LAST_COMMIT_ID" '.[] | select(.commit.id == "\($commit_id)")' | jq .name | tr -d '"'`
    PROJECT_RELEASE_VERSIONS[$PROJECT_RELEASE_NAME]=$PROJECT_RELEASE_VERSION
    
    SERVICE_URL_ENCODED=`echo $SERVICE | sed -e "s/\//%2F/g" | sed -e "s/\./%2E/g"`
    SERVICE_FILE_FROM_RELEASE=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/files/$SERVICE_URL_ENCODED/raw?ref=release"`
    VERSION_FOUND=`echo $SERVICE_FILE_FROM_RELEASE | grep $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME:$PROJECT_RELEASE_VERSION | wc -l`
    if [[ $VERSION_FOUND == 0 ]]; then
        printinfo "Prise en compte de la version applicative $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME:$PROJECT_RELEASE_VERSION"
        ACTION_NUM=`echo $PAYLOAD | jq '.actions | length'`
        CONTENT=`cat $SERVICE | sed -e "s/$PROJECT_NAMESPACE\/$PROJECT_RELEASE_NAME.*/$PROJECT_NAMESPACE\/$PROJECT_RELEASE_NAME:$PROJECT_RELEASE_VERSION/g"`
        PAYLOAD=`jq --arg action_num "$ACTION_NUM" --arg action "update" '. | .actions[$action_num|tonumber].action=$action' <<< $PAYLOAD`
        PAYLOAD=`jq --arg action_num "$ACTION_NUM" --arg content "$CONTENT" '. | .actions[$action_num|tonumber].content=$content' <<< $PAYLOAD`
        PAYLOAD=`jq --arg action_num "$ACTION_NUM" --arg file_path "$SERVICE" '. | .actions[$action_num|tonumber].file_path=$file_path' <<< $PAYLOAD`
        
        CHANGELOG=$(printf "$CHANGELOG\n - $PROJECT_RELEASE_NAME [$PROJECT_RELEASE_VERSION]($GITLAB_URL/$PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME/tags/$PROJECT_RELEASE_VERSION)")
    else
        printinfo "La version applicative $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME:$PROJECT_RELEASE_VERSION est déjà en place sur le projet $PROJECT_NAMESPACE/$PROJECT_NAME"
    fi
    
    if [[ $JOB_RELEASE_STATUS != "success" ]]; then 
        printerror "Le job de release du projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME est en erreur"
        HAS_FAILED_JOB=true;
    fi
done    

if [[ $HAS_FAILED_JOB == "true" ]]; then
    printerror "Un des jobs de release est en erreur, arrêt du job trigger release"
    exit 1;
fi

printmainstep "Mise à jour des fichiers de services dans la branche release avec les versions des microservices"
ACTION_NUM=`echo $PAYLOAD | jq '.actions | length'`
if [[ $ACTION_NUM != 0 ]]; then
    echo "PAYLOAD : $PAYLOAD"
    myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/commits" --header "Content-Type: application/json" -d "$PAYLOAD"| jq .
else
    printinfo "Toutes les versions des microservices sont déjà en place dans le projet $PROJECT_NAMESPACE/$PROJECT_NAME"
fi

RELEASE_LAST_NEW_COMMIT=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/compare?from=recsma&to=release" | jq .commit.id | tr -d '"'`
if [[ $RELEASE_LAST_NEW_COMMIT != "null" ]]; then
    printmainstep "Création du tag $RELEASE_VERSION sur le projet $PROJECT_NAMESPACE/$PROJECT_NAME"
    echo "CHANGELOG : $CHANGELOG"
    myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/tags" -d "tag_name=$RELEASE_VERSION" -d "ref=release" --data-urlencode "release_description=$CHANGELOG" | jq .
    
    printmainstep "Mise à jour de la branche recsma avec les derniers commits de release"
    RECSMA_MR_IID=`myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/merge_requests" -d "source_branch=release" -d "target_branch=recsma" -d "title=chore(release): Update recsma branch from release for version $RELEASE_VERSION" | jq .iid`
    echo "RECSMA_MR_IID : $RECSMA_MR_IID"
    myCurl --request PUT --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/merge_requests/$RECSMA_MR_IID/merge" | jq .
else
    printinfo "Aucun nouveau commit dans la branche release absent de la branche recsma"
    printinfo "- création du tag $RELEASE_VERSION dans la branche release inutile"
    printinfo "- mise à jour de la branche recsma à partir de la branche release inutile"
fi



