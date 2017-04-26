#!/bin/bash
set -e

printstep() {
    # 36 is blue
    echo -e "\033[36m\n== ${1} \033[37m \n"
}
printmainstep() {
   # 35 is purple
   echo -e "\033[35m\n== ${1} \033[37m \n"
}
printinfo () {
    # 32 is green
    echo -e "\033[32m==== INFO : ${1} \033[37m"
}
printwarn () {
    # 33 is yellow
    echo -e "\033[33m==== ATTENTION : ${1} \033[37m"
}
printerror () {
    # 31 is red
    echo -e "\033[31m==== ERREUR : ${1} \033[37m"
}

init_env () {
    CONF_DIR=/conf/
    if [ ! -d $CONF_DIR ]; then
        printerror "Impossible de trouver le dossier de configuration $CONF_DIR sur le runner"
        exit 1
    else
        source $CONF_DIR/variables
    fi
    APP_DIR=/usr/src/app/
    if [ ! -d $APP_DIR ]; then
        printerror "Impossible de trouver le dossier du code source de l'application $APP_DIR sur le runner"
        exit 1
    fi    
    if [[ -z $GITLAB_TOKEN ]]; then
        printerror "La variable GITLAB_TOKEN n'est pas présente, sortie..."
        exit 1
    fi
}

printmainstep "Déclenchement de la release des microservices"
printstep "Vérification des paramètres d'entrée"

init_env
REPO_URL=$(git config --get remote.origin.url | sed 's/\.git//g' | sed 's/\/\/.*:.*@/\/\//g')
GITLAB_URL=`echo $REPO_URL | grep -o 'https\?://[^/]\+/'`
GITLAB_API_URL="$GITLAB_URL/api/v4"

exit 1

