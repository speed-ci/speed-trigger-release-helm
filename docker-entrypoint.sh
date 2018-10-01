#!/bin/bash
set -e

source /init.sh

printmainstep "Déclenchement de la release de tous les microservices"
printstep "Vérification des paramètres d'entrée"
init_env
int_gitlab_api_env

GITLAB_CI_USER="gitlab-ci-sln"
POLLLING_PERIOD=5
HELM_VALUES="values.yaml"
REC_ENV=${REC_ENV:-"rec"}

if [ ! -f $HELM_VALUES ]; then
    printerror "Impossible de trouver le fichier Helm de values $HELM_VALUES contenant les images des services docker du projet"
    exit 1
fi    

declare -A PROJECT_RELEASE_IDS
declare -A LAST_COMMIT_IDS
declare -A PROJECT_RELEASE_VERSIONS
declare -A JOB_RELEASE_IDS
declare -A JOB_RELEASE_STATUSES

printstep "Préparation du projet $PROJECT_NAMESPACE/$PROJECT_NAME"

if [[ -z $RELEASE_VERSION ]]; then
    printerror "La variable secrète RELEASE_VERSION doit être renseignée par un utilisateur master du projet $PROJECT_NAMESPACE/$PROJECT_NAME dans le menu Settings / Pipelines" 
    exit 1
fi

PROJECT_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects?search=$PROJECT_NAME" | jq --arg project_namespace "$PROJECT_NAMESPACE" '.[] | select(.namespace.name == "\($project_namespace)") | .id'`
FOUND_TAG=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/tags/$RELEASE_VERSION" | jq -r .name`
if [[ $FOUND_TAG != "null" ]]; then
    printerror "La version $FOUND_TAG du projet $PROJECT_NAMESPACE/$PROJECT_NAME existe déjà" 
    printerror "Un utilisateur master du projet doit mettre à jour à la version suivante la variable secrète RELEASE_VERSION dans le menu Settings / Pipelines" 
    exit 1
fi

RELEASE_BRANCH=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/branches/release" | jq .name`

if [[ $RELEASE_BRANCH == "null" ]]; then
    printinfo "Création de la branche release manquante sur le projet $PROJECT_NAMESPACE/$PROJECT_NAME"
    myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/branches" -d "branch=release" -d "ref=dev" | jq .

else
    LAST_NEW_COMMIT=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/compare?from=release&to=dev" | jq -r .commit.id`
    if [[ $LAST_NEW_COMMIT != "null" ]]; then
        printinfo "Mise à jour de la branche release avec les derniers commits de dev"
        RELEASE_MR_IID=`myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" --header "SUDO: $GITLAB_USER_ID" "$GITLAB_API_URL/projects/$PROJECT_ID/merge_requests" -d "source_branch=dev" -d "target_branch=release" -d "title=chore(release): Update release branch with $LAST_NEW_COMMIT to prepare release" | jq .iid`
        printinfo "Lien d'accès à la merge request : $GITLAB_URL/$PROJECT_NAMESPACE/$PROJECT_NAME/merge_requests/$RELEASE_MR_IID"
        myCurl --request PUT --header "PRIVATE-TOKEN: $GITLAB_TOKEN" --header "SUDO: $GITLAB_USER_ID" "$GITLAB_API_URL/projects/$PROJECT_ID/merge_requests/$RELEASE_MR_IID/merge" | jq .
    fi
fi


REC_BRANCH=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/branches/$REC_ENV" | jq .name`

if [[ $REC_BRANCH == "null" ]]; then
    printinfo "Création de la branche $REC_ENV manquante sur le projet $PROJECT_NAMESPACE/$PROJECT_NAME"
    myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/branches" -d "branch=$REC_ENV" -d "ref=release" | jq .
fi

SERVICE_IMAGE_LIST="repositories.txt"
yq r -j $HELM_VALUES | jq -r '.. | .repository? // empty' > $SERVICE_IMAGE_LIST
for SERVICE in $(cat $SERVICE_IMAGE_LIST)
do
    PROJECT_RELEASE_NAME=${SERVICE##*/}
    PROJECT_RELEASE_NAME=${PROJECT_RELEASE_NAME%--*}
    if [[ $PROJECT_RELEASE_NAME == "*" ]]; then
        printerror "Aucun service docker trouvé respectant le format $SERVICE_LIST"
        exit 1
    fi

    printmainstep "Traitement du projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME"

    if  [[ -z ${PROJECT_RELEASE_IDS[$PROJECT_RELEASE_NAME]} ]]; then
    
        PROJECT_RELEASE_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects?search=$PROJECT_RELEASE_NAME" | jq --arg project_namespace "$PROJECT_NAMESPACE" '.[] | select(.namespace.name == "\($project_namespace)") | .id'`
        PROJECT_RELEASE_IDS[$PROJECT_RELEASE_NAME]=$PROJECT_RELEASE_ID
        
        if [[ $PROJECT_RELEASE_ID != "null" ]]; then
        
            printstep "Préparation du projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME"
            GITLAB_CI_USER_MEMBERSHIP=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/members?query=$GITLAB_CI_USER" | jq .[0]`
            if [[ $GITLAB_CI_USER_MEMBERSHIP == "null" ]]; then 
                printinfo "Ajout du user $GITLAB_CI_USER manquant au projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME"
                myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/members" -d "user_id=$GITLAB_CI_USER_ID" -d "access_level=40"
            fi
        
            printstep "Préparation du lancement du job release sur le projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME"
            LAST_COMMIT_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/repository/commits?per_page=1&page=1" | jq -r .[0].id`
            LAST_COMMIT_IDS[$PROJECT_RELEASE_NAME]=$LAST_COMMIT_ID
            LAST_PIPELINE_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/pipelines?per_page=1&page=1" | jq -r .[0].id`
            JOB_RELEASE_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs" | jq --arg commit_id "$LAST_COMMIT_ID" --arg pipeline_id "$LAST_PIPELINE_ID" '.[] | select(.commit.id == "\($commit_id)" and (.pipeline.id | tostring  == "\($pipeline_id)")  and .name == "release" and .ref == "master") | .id' | head -1`
            JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]=$JOB_RELEASE_ID
        
            if [[ $JOB_RELEASE_ID != "" ]]; then
                printstep "Déclenchement de la release sur le projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME pour le dernier commit $LAST_COMMIT_ID"
                JOB_RELEASE_STATUS=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID" | jq -r .status`
                printinfo "LAST_PIPELINE_ID   : $LAST_PIPELINE_ID"
                printinfo "JOB_RELEASE_ID     : $JOB_RELEASE_ID"
                printinfo "JOB_RELEASE_STATUS : $JOB_RELEASE_STATUS"
    
                if [[ $JOB_RELEASE_STATUS == "skipped" ]]; then
                    printerror "Les étapes préalables à la release sur le projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME doivent être effectuées avec succès, release interrompue"
                    exit 1
                elif [[ $JOB_RELEASE_STATUS == "success" ]]; then
                    echo ""
                    printinfo "Le job release est déjà un succès, relancement inutile"
                elif [[ $JOB_RELEASE_STATUS == "manual" ]]; then
                    JOB_RELEASE_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" --header "SUDO: $GITLAB_USER_ID" -XPOST "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID/play" | jq .id`
                    JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]=$JOB_RELEASE_ID
                else
                    JOB_RELEASE_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" --header "SUDO: $GITLAB_USER_ID" -XPOST "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID/retry" | jq .id`
                    JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]=$JOB_RELEASE_ID
                fi
            else
                printerror "Pas de déclenchement de release possible, le projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME ne dispose pas de job release disponible pour le commit $LAST_COMMIT_ID" 
                exit 1
            fi
        
        else
            printerror "Pas de déclenchement de release possible, le projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME n'existe pas"
            exit 1
        fi
    else
        printinfo "Projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME déjà traité précédemment"
    fi
done

printmainstep "Attente de la fin de tous les jobs de release"
sleep $POLLLING_PERIOD

while :
do
    HAS_RUNNING=false
    for PROJECT_RELEASE_NAME in "${!PROJECT_RELEASE_IDS[@]}"
    do
        PROJECT_RELEASE_ID=${PROJECT_RELEASE_IDS[$PROJECT_RELEASE_NAME]}
        JOB_RELEASE_ID=${JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]}
        JOB_RELEASE_STATUS=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID" | jq -r .status`
        JOB_RELEASE_STATUSES[$PROJECT_RELEASE_NAME]=$JOB_RELEASE_STATUS
        if [[ $JOB_RELEASE_STATUS == "pending" ]] || [[ $JOB_RELEASE_STATUS == "running" ]]; then HAS_RUNNING=true; fi
        printinfo "Job release status for $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME : $JOB_RELEASE_STATUS"
    done
    
    if [[ $HAS_RUNNING == "false" ]]; then break; fi
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

PAYLOAD=`jq --arg commit_message "chore(release): bump services versions to $RELEASE_VERSION" '. | .commit_message=$commit_message' <<< $PAYLOAD`
VALUES_URL_ENCODED=`echo $HELM_VALUES | sed -e "s/\//%2F/g" | sed -e "s/\./%2E/g"`
VALUES_FILE_FROM_RELEASE="values-from-release.yaml"
`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" -o $VALUES_FILE_FROM_RELEASE "$GITLAB_API_URL/projects/$PROJECT_ID/repository/files/$VALUES_URL_ENCODED/raw?ref=release"`

for SERVICE in $(cat $SERVICE_IMAGE_LIST)
do
    PROJECT_RELEASE_NAME=${SERVICE##*/}
    PROJECT_RELEASE_NAME=${PROJECT_RELEASE_NAME%--*}
    PROJECT_RELEASE_ID=${PROJECT_RELEASE_IDS[$PROJECT_RELEASE_NAME]}
    JOB_RELEASE_ID=${JOB_RELEASE_IDS[$PROJECT_RELEASE_NAME]}
    JOB_RELEASE_STATUS=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/jobs/$JOB_RELEASE_ID" | jq -r .status`

    printinfo "Status final du job release du projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME : $JOB_RELEASE_STATUS"
    printinfo "Lien d'accès aux logs distants : $GITLAB_URL/$PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME/builds/$JOB_RELEASE_ID"

    LAST_COMMIT_ID=${LAST_COMMIT_IDS[$PROJECT_RELEASE_NAME]}
    PROJECT_RELEASE_VERSION=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_RELEASE_ID/repository/tags" | jq -r --arg commit_id "$LAST_COMMIT_ID" '.[] | select(.commit.id == "\($commit_id)") | .name'`
    PROJECT_RELEASE_VERSIONS[$PROJECT_RELEASE_NAME]=$PROJECT_RELEASE_VERSION
    
    IMAGE=$ARTIFACTORY_DOCKER_REGISTRY/$PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME:$PROJECT_RELEASE_VERSION
    printinfo "Ajouter la version du macroservice au tag de l'image du microservice : $IMAGE-part-of-$RELEASE_VERSION"
    ARTIFACTORY_IMAGE_ID=`myCurl -u $ARTIFACTORY_USER:$ARTIFACTORY_PASSWORD "$ARTIFACTORY_URL/artifactory/docker/$PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME/$PROJECT_RELEASE_VERSION-part-of-$RELEASE_VERSION/manifest.json" | jq -r .config.digest`
    if [[ $ARTIFACTORY_IMAGE_ID == "null" ]]; then
        docker login -u $ARTIFACTORY_USER -p $ARTIFACTORY_PASSWORD $ARTIFACTORY_DOCKER_REGISTRY
        docker pull $IMAGE
        docker tag $IMAGE $IMAGE-part-of-$RELEASE_VERSION
        docker push $IMAGE-part-of-$RELEASE_VERSION
        docker rmi $IMAGE $IMAGE-part-of-$RELEASE_VERSION
    else
       printinfo "L'image docker $IMAGE:$PROJECT_RELEASE_VERSION-part-of-$RELEASE_VERSION déjà présente dans Artifactory, docker push inutile"
    fi
    
    VERSION_FOUND=`yq r $VALUES_FILE_FROM_RELEASE $ALIAS.image.tag | grep $PROJECT_RELEASE_VERSION-part-of-$RELEASE_VERSION | wc -l`
    if [[ $VERSION_FOUND == 0 ]]; then
        printinfo "Prise en compte de la version applicative $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME:$PROJECT_RELEASE_VERSION-part-of-$RELEASE_VERSION"
        ALIAS==${PROJECT_RELEASE_NAME#$PROJECT_NAMESPACE-}
        yq w -i $HELM_VALUES $ALIAS.image.tag $PROJECT_RELEASE_VERSION-part-of-$RELEASE_VERSION
        
        if  [[ -z $CHANGELOG ]]; then CHANGELOG=$(printf "### Versions des microservices\n"); fi
        CHANGELOG=$(printf "$CHANGELOG\n - Service **$SERVICE** : Projet Gitlab associé **$PROJECT_RELEASE_NAME [$PROJECT_RELEASE_VERSION]($GITLAB_URL/$PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME/tags/$PROJECT_RELEASE_VERSION)**")
    else
        printinfo "La version applicative $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME:$PROJECT_RELEASE_VERSION-part-of-$RELEASE_VERSION est déjà en place sur le projet $PROJECT_NAMESPACE/$PROJECT_NAME"
    fi
    
    if [[ $JOB_RELEASE_STATUS != "success" ]]; then 
        printerror "Le job de release du projet $PROJECT_NAMESPACE/$PROJECT_RELEASE_NAME est en erreur"
        HAS_FAILED_JOB=true;
    fi
    echo ""
done    

if [[ $HAS_FAILED_JOB == "true" ]]; then
    printerror "Un des jobs de release est en erreur, arrêt du job trigger release"
    exit 1;
fi

printmainstep "Mise à jour du fichier de values dans la branche release avec les versions des microservices"
VALUES_HAS_CHANGED=`git status --porcelain $HELM_VALUES | wc -l`
if [[ $VALUES_HAS_CHANGED != 0 ]]; then
    ACTION_NUM=`echo $PAYLOAD | jq '.actions | length'`
    PAYLOAD=`jq --arg action_num "$ACTION_NUM" --arg action "update" '. | .actions[$action_num|tonumber].action=$action' <<< $PAYLOAD`
    PAYLOAD=`jq --arg action_num "$ACTION_NUM" --arg content "cat $HELM_VALUES" '. | .actions[$action_num|tonumber].content=$content' <<< $PAYLOAD`
    PAYLOAD=`jq --arg action_num "$ACTION_NUM" --arg file_path "$HELM_VALUES" '. | .actions[$action_num|tonumber].file_path=$file_path' <<< $PAYLOAD`

    ACTION_NUM=`echo $PAYLOAD | jq '.actions | length'`
    if [[ $ACTION_NUM != 0 ]]; then
        echo "PAYLOAD : $PAYLOAD"
        myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" --header "SUDO: $GITLAB_USER_ID" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/commits" --header "Content-Type: application/json" -d "$PAYLOAD"| jq .
    else
        printinfo "Toutes les versions des microservices sont déjà en place dans le projet $PROJECT_NAMESPACE/$PROJECT_NAME"
    fi
fi

RELEASE_LAST_NEW_COMMIT=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/compare?from=$REC_ENV&to=release" | jq -r .commit.id`
if [[ $RELEASE_LAST_NEW_COMMIT != "null" ]]; then
    printmainstep "Création du tag $RELEASE_VERSION sur le projet $PROJECT_NAMESPACE/$PROJECT_NAME"
    echo "CHANGELOG : $CHANGELOG"
    myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/tags" -d "tag_name=$RELEASE_VERSION" -d "ref=release" --data-urlencode "release_description=$CHANGELOG" | jq .
    
    printmainstep "Mise à jour de la branche $REC_ENV avec les derniers commits de release"
    REC_MR_IID=`myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" --header "SUDO: $GITLAB_USER_ID" "$GITLAB_API_URL/projects/$PROJECT_ID/merge_requests" -d "source_branch=release" -d "target_branch=$REC_ENV" -d "title=chore(release): Update $REC_ENV branch from release for version $RELEASE_VERSION" | jq .iid`
    printinfo "Lien d'accès à la merge request : $GITLAB_URL/$PROJECT_NAMESPACE/$PROJECT_NAME/merge_requests/$REC_MR_IID"
    myCurl --request PUT --header "PRIVATE-TOKEN: $GITLAB_TOKEN" --header "SUDO: $GITLAB_USER_ID" "$GITLAB_API_URL/projects/$PROJECT_ID/merge_requests/$REC_MR_IID/merge" | jq .
else
    printinfo "Aucun nouveau commit dans la branche release absent de la branche $REC_ENV"
    printinfo "- création du tag $RELEASE_VERSION dans la branche release inutile"
    printinfo "- mise à jour de la branche $REC_ENV à partir de la branche release inutile"
fi