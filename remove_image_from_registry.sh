#!/bin/bash

IMAGE_ARG=""
HOST=""
IMAGE=""
URI=""
TAG=""
USERNAME=""
CREDENTIALS_STRING=""
INSECURE=""
RAW_URL=""
RAW_HTTP_METHOD=""
RAW_HTTP_HEADER=""
TAG_ONLY=false

function printUsage
{
    local RESULT=$1
    if [ "$RESULT" == "" ]; then
        RESULT=0
    fi
    cat << EOF

Usage:
 $ ./remove_image_from_registry.sh [OPTIONS] [IMAGE]

IMAGE
 Image name has the format registryhost:port/repository/imagename:version
 For instance : mydockerregistry:5000/myrepo/zoombie:latest
 Note that the version tag ("latest" in this example) is mandatory.
 Please note that this script will delete the image from the repository, not only the tag; if the
 image you are deleting have multiple tags ( for instance "1.0" and "latest" ), both tags will be
 removed from the registry.
 Docker registry does not support deleting only a tag ATM, ref https://github.com/docker/distribution/issues/2317
 The option "--tag-only" tries to circumvent this by restoring other tags which also disappear from
 the registry during the delete. However, this is not entirely safe:
  - Do not delete multiple images concurrently.
  - Do not run registry garbage collector while deleting images (this you should never do anyway....).
  - Do not create new local tags for the image during the delete operation.

REQUIREMENTS
 The registry must run a v2 registry and have token based authentication enabled.
 Deletion must be enabled on the registry server (REGISTRY_STORAGE_DELETE_ENABLED=true).
 
NOTE
  The blobs are actually not deleted from the registry server automatically after running this script.
  In order to do that you must manually (for the time being) run the registry garbage collector.
  See https://docs.docker.com/registry/garbage-collection/ for more info about this.

OPTIONS
 -h, --help
        Print help
 --insecure
        Connect to a registry which has a self-signed SSL certificate
 -p
        Prompt for password
 -u <username>
        Use the given username when authenticating with the registry
 --raw <url> <http-method> [http-header]
        Send custom request to the registry. When using this argument, do not use the  [IMAGE] argument too.
        Example:
        ./remove_image_from_registry.sh \\
             -u admin \\
             --insecure \\
             --raw \\
             mydockerregistry:5000/v2/imagename/manifests/latest \\
             GET \\
             "Accept: application/vnd.docker.distribution.manifest.v2+json"
 --tag-only
        After deleting the image, try to recover all other tags which also pointed to the image

 
Password may also be set using the environment variable REGISTRY_PASSWORD
 $ export REGISTRY_PASSWORD=sesame

EOF
    exit $RESULT;
}

function validateImageName
{
    local IMAGE_NAME
    IMAGE_NAME="$1"
    if [[ "$IMAGE_NAME" == https://* ]]; then
        echo "Image name or raw URL should not start with https://"
        exit 1
    fi
    if [[ "$IMAGE_NAME" == http://* ]]; then
        echo "Image name or raw URL should not start with http://"
        echo "Anyway, registry must use SSL in order to make token based auth work"
        exit 1
    fi
}

function parseArguments
{
    while (( "$#" )); do
        if [ "$1" = "-u" ]; then
            shift
            USERNAME=$1
        elif [ "$1" = "-p" ]; then
            echo -n "Password: "
            read -s REGISTRY_PASSWORD
            echo
        elif [ "$1" = "--insecure" ]; then
            INSECURE=" --insecure"
        elif [ "$1" = "--help" ]; then
            printUsage
        elif [ "$1" = "-h" ]; then
            printUsage
        elif [ "$1" = "--raw" ]; then
            shift
            RAW_URL="$1"
            validateImageName "$1"
            shift
            RAW_HTTP_METHOD="$1"
            shift
            RAW_HTTP_HEADER="$1"
        elif [ "$1" = "--tag-only" ]; then
            TAG_ONLY=true
        else
            # If first param is a dash, we have an invalid argumwent
            if [ ${1:0:1} == "-" ]; then
                echo "Error: Unknown parameter : $1"
                exit 1
            fi
            if [ "$IMAGE_ARG" != "" ]; then
                echo "Error: You may only provide IMAGE name once"
                exit 1
            fi
            validateImageName "$1"
            IMAGE_ARG="$1"
            HOST=`echo $IMAGE_ARG|cut -f 1 -d "/"`
            IMAGE=`echo $IMAGE_ARG|cut -f 2- -d "/"|cut -f 1 -d ":"`
            TAG=`echo $IMAGE_ARG|cut -f 2- -d "/"|cut -f 2 -d ":"`
        fi
        shift
    done

    if [ "$IMAGE_ARG" = "" ] && [ "$RAW_URL" = "" ]; then
        echo "Error: You need to provide image name"
        printUsage 1
    fi

    if [ "$USERNAME" != "" ]; then
        CREDENTIALS_STRING=" --user ${USERNAME}:${REGISTRY_PASSWORD}"
    fi
}

# $1 is URL
# $2 is HTTP METHOD (default GET)
# $2 is additional header ( optional )
function sendRegistryRequest
{
    local URL
    local WWW_AUTH_HEADER
    local TOKEN
    local TOKEN_RESP
    local REALM
    local SERVICE
    local SCOPE
    local CUSTOM_HEADER
    local HTTP_METHOD
    local CURL_HTTP_METHOD_OPTION
    local CURL_ARG
    local RESULT
    
    URL="$1"

    CURL_HTTP_METHOD_OPTION="-X"
    if [ "$2" != "" ]; then
        HTTP_METHOD="$2"
    else
        HTTP_METHOD="GET"
    fi
    
    # If HTTP_METHOD == "HEAD", we'll need to use -I option instead
    if [ $HTTP_METHOD = "HEAD" ]; then
        CURL_HTTP_METHOD_OPTION="-I"
        HTTP_METHOD=""
    fi

    if [ "$3" != "" ]; then
        CUSTOM_HEADER="$3"
    else
        CUSTOM_HEADER=""
    fi
    WWW_AUTH_HEADER=`curl -sS -i $INSECURE $CURL_HTTP_METHOD_OPTION $HTTP_METHOD -H "Content-Type: application/json" ${URL} |grep Www-Authenticate|sed 's|.*realm="\(.*\)",service="\(.*\)",scope="\(.*\)".*|\1,\2,\3|'`

    REALM=`echo $WWW_AUTH_HEADER|cut -f 1 -d ","`
    SERVICE=`echo $WWW_AUTH_HEADER|cut -f 2 -d ","`
    SCOPE=`echo $WWW_AUTH_HEADER|cut -f 3 -d ","`

    TOKEN=`curl -f -sS $INSECURE -G --data-urlencode "service=${SERVICE}" --data-urlencode "scope=${SCOPE}" "${REALM}" -K- <<< $CREDENTIALS_STRING|jq .token|cut -f 2 -d "\""`
    RESULT=$?
    if [ $RESULT -ne 0 ] || [ "$TOKEN" == "" ]; then
        # Run command again (without -f arg) and output message to std err 
        >&2 echo Auth server responded:
        >&2 curl -sS $INSECURE -G --data-urlencode "service=${SERVICE}" --data-urlencode "scope=${SCOPE}" "${REALM}" -K- <<< $CREDENTIALS_STRING
        if [ $RESULT -eq 0 ]; then
            RESULT=42
        fi
        exit $RESULT
    fi

    # We only use -f parameter if we are doing a ordinary delete request
    # If we are doing raw request, we output both request and response ( including headers )
    if [ "$RAW_URL" = "" ]; then
        CURL_ARG="-f "
    else
        CURL_ARG="-v "
    fi
    if [ "$CUSTOM_HEADER" == "" ]; then
        curl $CURL_ARG -sS $INSECURE $CURL_HTTP_METHOD_OPTION $HTTP_METHOD -H "Authorization: Bearer $TOKEN" "${URL}"
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
        # Run command again (without -f arg) and output message to std err 
            >&2 curl -sS $INSECURE $CURL_HTTP_METHOD_OPTION $HTTP_METHOD -H "Authorization: Bearer $TOKEN" "${URL}"
            exit $RESULT
        fi
    else
        curl $CURL_ARG -i -sS $INSECURE $CURL_HTTP_METHOD_OPTION $HTTP_METHOD -H "$CUSTOM_HEADER" -H "Authorization: Bearer $TOKEN" "${URL}"
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
        # Run command again (without -f arg) and output message to std err 
            >&2 curl -i -sS $INSECURE $CURL_HTTP_METHOD_OPTION $HTTP_METHOD -H "$CUSTOM_HEADER" -H "Authorization: Bearer $TOKEN" "${URL}"
            exit $RESULT
        fi
    fi
}

function getTags
{
    TAGS=`sendRegistryRequest https://${HOST}/v2/${IMAGE}/tags/list GET |jq --compact-output .tags`
    RESULT=$?
    if [ "$TAGS" == "" ] || [ $RESULT -ne 0 ]; then
        exit $RESULT
    fi
    # imagenames and tags cannot contain special characters or space. So let's just remove that JSON syntax
    TAGS=${TAGS//\"}
    TAGS=${TAGS//\[}
    TAGS=${TAGS//\]}
    TAGS=${TAGS//,/ }
}

# $1 is the tag you want to take backup of
# $2 is tag name used for backup (backup tag)
function backupLocalImage
{
    # If the tag we are going to delete exists locally we need to take a backup of that
    # then download the image from registry ( remote and local image may not match even though they have the same name )
    if [ `docker images --format "{{.Repository}}:{{.Tag}}" ${HOST}/${IMAGE}:$1| wc -l` -eq 1 ]; then
        BACKUP_TAKEN="true"
        docker tag ${HOST}/${IMAGE}:$1 ${HOST}/${IMAGE}:$2
        docker rmi ${HOST}/${IMAGE}:$1
    fi
}

# $1 is the tag you want to restore to
# $2 is the tag name used when taking the backup (backup tag)
function restoreBackup
{
    if [ `docker images --format "{{.Repository}}:{{.Tag}}" ${HOST}/${IMAGE}:$2| wc -l` -eq 1 ]; then
#        docker rmi ${HOST}/${IMAGE}:$1
        docker tag ${HOST}/${IMAGE}:$2 ${HOST}/${IMAGE}:$1
        docker rmi ${HOST}/${IMAGE}:$2
    fi
}

parseArguments "$@"

if [ "$RAW_URL" = "" ]; then
    if [ "$TAG_ONLY" = "true" ]; then
        getTags
        backupLocalImage $TAG remove_image_from_registry1
        docker pull ${HOST}/${IMAGE}:${TAG}
    fi
    SHA_REQ=`sendRegistryRequest https://${HOST}/v2/${IMAGE}/manifests/${TAG} GET "Accept: application/vnd.docker.distribution.manifest.v2+json"`
    RESULT=$?
    if [ "$SHA_REQ" == "" ] || [ $RESULT -ne 0 ]; then
        docker rmi ${HOST}/${IMAGE}:${TAG}
        restoreBackup $TAG remove_image_from_registry1
        exit $RESULT
    fi

    SHA=$(echo "$SHA_REQ"|grep "Docker-Content-Digest:"|cut -f 2- -d ":"|tr -d '[:space:]')
    sendRegistryRequest https://${HOST}/v2/${IMAGE}/manifests/${SHA} DELETE
    if [ "$TAG_ONLY" = "true" ]; then
        OLDTAGS="$TAGS"
        getTags
        TAGSPIPE="|${TAGS// /|}|"

        for i in $OLDTAGS; do
            # Clearly, we expect TAG to be gone
            # We don't want to restore that one
            if [ "$i" = "$TAG" ]; then
                continue
            fi

            if [[ $TAGSPIPE != *"|$i|"* ]]; then
                echo This tag needs to be restored : ${HOST}/${IMAGE}:${i}
                backupLocalImage $i remove_image_from_registry2
                docker tag ${HOST}/${IMAGE}:${TAG} ${HOST}/${IMAGE}:${i}
                docker push ${HOST}/${IMAGE}:${i}
                docker rmi ${HOST}/${IMAGE}:${i}
                restoreBackup $i remove_image_from_registry2
            fi
        done
        docker rmi ${HOST}/${IMAGE}:${TAG}
        restoreBackup $TAG remove_image_from_registry1
    fi
else
    sendRegistryRequest "https://${RAW_URL}" "${RAW_HTTP_METHOD}" "${RAW_HTTP_HEADER}"
fi

