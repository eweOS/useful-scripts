#!/usr/bin/env bash

set -e

GIT_UPSTREAM="git@github.com:Aleksanaa/test-repo-script.git"

# This will be implemented as a parameter
REPO_NAME=$1
COMMIT_MESSAGE=""
TEMPDIR_NAME=".temp_$(date +%s)"
HAS_PACKED_FILES=false

validate_with_namcap() {
    if ! command -v namcap &> /dev/null ;then
        echo "WARNING: namcap not installed, skipping PKGBUILD check..."
    elif ! namcap -m PKGBUILD &> /dev/null ;then
        echo "ERROR: PKGBUILD invalid. Please use namcap -i PKGBUILD to see errors."
        exit 1
    else
        echo "PKGBUILD validation success."
    fi
}

load_PKGBUILD() {
    source PKGBUILD
    PACKAGE_NAME=$pkgname
    BRANCH_NAME="$REPO_NAME/$PACKAGE_NAME"
    PACKAGE_VERSION="$pkgver-$pkgrel"
    LOCAL_SOURCE=()
    for _component in "${source[@]}"; do
        if [[ ! "$_component" =~ ^.*://.*$ ]];then
            LOCAL_SOURCE+=("$_component")
        fi
    done
}

validate_other_parts() {
    echo -e "The package $PACKAGE_NAME $PACKAGE_VERSION will be pushed to $BRANCH_NAME."
    read -r -p "Are you sure? [y/N] " response
    if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]];then
        echo "ERROR: comfirmation failed. Please check precisely again."
        exit 1
    fi
    unset _component
    for _component in "${LOCAL_SOURCE[@]}"; do
        if [ ! -f "${_component}" ];then
            echo "ERROR: file $_component in source not found."
            exit 1
        fi
    done
    echo "Local source validation success."
}

pack_files() {
    if ! $HAS_PACKED_FILES ;then
        mkdir $TEMPDIR_NAME
        cp ./* $TEMPDIR_NAME
        git rm -r --cached $TEMPDIR_NAME &> /dev/null || true
        HAS_PACKED_FILES=true
    fi
}

unpack_files() {
    if $HAS_PACKED_FILES ;then
        rm -r ./*
        cp -r $TEMPDIR_NAME/* ./
        rm -r $TEMPDIR_NAME
        HAS_PACKED_FILES=false
    fi
}

try_pull() {
    if $HAS_REMOTE_BRANCH;then
        echo "Now we are trying to pull from $REMOTE_NAME/$BRANCH_NAME..."
        git branch -u $REMOTE_NAME/$BRANCH_NAME
        git pull
        if $HAS_PACKED_FILES; then
            read -r -p "A new set of files will overwrite old ones, show diff? [Y/n] " response
            if [[ ! "$response" =~ ^([nN][oO]|[nN])$ ]];then
                git diff --no-index ./ ./$TEMPDIR_NAME/
                read -r -p "Continue to rebase? [Y/n] " response
                if [[ "$response" =~ ^([nN][oO]|[nN])$ ]];then
                    echo "The new files are in $TEMPDIR_NAME, exiting."
                    exit 0
                fi
            fi
        fi
    fi
}

init_repo() {
    unset REMOTE_NAME
    if [ ! -d ".git" ];then
        git init &> /dev/null
        git add -- . -- ":(exclude)$TEMPDIR_NAME" &> /dev/null
        git commit -m "This is a useless commit" &> /dev/null
    else
        for _remote in $(git remote show);do
            if [ "$(git remote get-url "$_remote")" == $GIT_UPSTREAM ];then
                REMOTE_NAME=$_remote
                break
            fi
        done
    fi
    if [ -z $REMOTE_NAME ];then
        git remote add origin $GIT_UPSTREAM
        REMOTE_NAME="origin"
    fi
}

check_remote() {
    # must run after load_PKGBUILD
    if [ -z "$remote_matching_branches" ];then
        echo "Searching remote branches, this may take a few seconds..."
        remote_matching_branches=$(git ls-remote $GIT_UPSTREAM "refs/heads/*/$PACKAGE_NAME" | cut -f 2)
    fi
    HAS_REMOTE_BRANCH=true
    if [ -z "$remote_matching_branches" ];then
        HAS_REMOTE_BRANCH=false
    elif [[ ! "$remote_matching_branches" == *"refs/heads/$REPO_NAME/$PACKAGE_NAME"* ]];then
        echo -e "$PACKAGE_NAME exists in remote, but not in $REPO_NAME."
        echo -e "Here are remote repos where it exists:"
        for long_name in $remote_matching_branches;do
            IFS='/' read -r -a long_name_split <<< "$long_name"
            echo "- ${long_name_split[2]}"
        done
        read -r -p "[e]dit repo, [p]ush anyway or [q]uit? " response
        case $response in
        E*|e*)
            read -r -p "Type new repo name: " REPO_NAME
            BRANCH_NAME="$REPO_NAME/$PACKAGE_NAME"
            check_remote
            ;;
        P*|p*)
            HAS_REMOTE_BRANCH=false
            ;;
        Q*|q*)
            exit 0
            ;;
        *)
            echo "ERROR: unrecognized option, exiting."
            exit 1
            ;;
        esac
    fi
}

checkout_branch() {
    CURRENT_BRANCH=$(git branch --show-current)
    if [ ! $CURRENT_BRANCH == $BRANCH_NAME ];then
        if [[ "$(git --no-pager branch)" == *"$BRANCH_NAME"* ]];then
            echo -e "The $BRANCH_NAME branch already exists in local repo and is not current branch."
            echo -e "1. Switch to $BRANCH_NAME and rerun publish script."
            echo -e "2. Override files in $BRANCH_NAME with files in current branch."
            echo -e "3. Revert all uncommitted changes and exit."
            echo -e "4. Exit without doing anything."
            read -r -p "What's your choice? [1/2/3/4] " response
            case $response in
            1)
                pack_files
                git checkout -f $BRANCH_NAME
                # run main script
                git checkout -f $CURRENT_BRANCH
                unpack_files
                exit 0
                ;;
            2)
                pack_files
                git checkout -f $BRANCH_NAME
                try_pull
                unpack_files
                ;;
            3)
                git reset --hard
                git clean -f
                exit 0
                ;;
            4)
                exit 0
                ;;
            *)
                echo "ERROR: unrecognized option, exiting."
                exit 1
            esac
        else
            echo -e "$BRANCH_NAME doesn't exist in local branches."
            read -r -p "Create and move files there? [Y/n] " response
            if [[ ! "$response" =~ ^([nN][oO]|[nN])$ ]];then
                pack_files
                git checkout --orphan $BRANCH_NAME
                try_pull
                unpack_files
            else
                echo "No work to do with $PACKAGE_NAME in $CURRENT_BRANCH, exiting."
                exit 0
            fi
        fi
    else
        try_pull
    fi
}

commit_and_push() {
    git add -- . -- ":(exclude)$TEMPDIR_NAME"
    if [ -z $COMMIT_MESSAGE ];then
        read -r -p "Write commit messages here: " COMMIT_MESSAGE
    fi
    git commit -m "$COMMIT_MESSAGE"
    git push --set-upstream $REMOTE_NAME $BRANCH_NAME
    echo "$PACKAGE_NAME pushed to $REMOTE_NAME/$BRANCH_NAME Succeessfully."
}

WORKDIR=$2
cd $WORKDIR

if [ ! -f "PKGBUILD" ];then
    echo "Error: no PKGBUILD found in this folder."
    exit 1
fi

validate_with_namcap
load_PKGBUILD
validate_other_parts
init_repo
check_remote
checkout_branch
commit_and_push


