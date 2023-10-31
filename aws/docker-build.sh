#!/usr/bin/env bash

# exit when any command fails
set -e

# Default variable values
build_arguments=""
image_tag=""
push_image="true"

# Function to display script usage
usage() {
 echo "Usage: $0 [OPTIONS]"
 echo "PreReq: Dockerfile to build should be in the current working directory"
 echo "Options:"
 echo " -h, --help      Display this help message"
 echo " -a, --args      Additional build arguments to pass to docker buildx build"
 echo " -p, --push      Push images to remote repository: true or false. Default: true"
 echo " -t, --tag       Docker image tag"
}

# Function to parse input flags
parse_flags() {
  while [ $# -gt 0 ]; do
    case $1 in

      -h | --help)
        usage
        exit 0
        ;;

      -a | --args)
        build_arguments="$2"
        shift
        shift
        ;;

      -p | --push)
        push_image="$2"
        shift
        shift
        ;;


      -t | --tag)
        image_tag="$2"
        shift
        shift
        ;;

      *)
        echo "Invalid option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

build() {

    docker_tag="--tag public.ecr.aws/$image_tag"

    if [[ "$PUSH_TO_DOCKERHUB" == "true" ]]; then
        docker_tag+=" --tag docker.io/$image_tag"
    fi

    if [[ "$push_image" == "false" ]]; then
      PUSH=""
    else
      PUSH="--push"
    fi

    echo "[INFO] docker buildx build \
            ${PUSH} \
            --platform ${PLATFORMS} \
            --no-cache \
            ${build_arguments} \
            ${docker_tag} \
            ."

    docker buildx build \
            ${PUSH} \
            --platform "${PLATFORMS}" \
            --no-cache \
            ${build_arguments} \
            ${docker_tag} \
            .

}

#########################################
# Main
#########################################

parse_flags "$@"

echo "[INFO] Docker build arguments: $build_arguments"
echo "[INFO] Docker image tag: $image_tag"

build