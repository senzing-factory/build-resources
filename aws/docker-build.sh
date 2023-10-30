#!/usr/bin/env bash

# Default variable values
build_arguments=""
image_tag=""

# Function to display script usage
usage() {
 echo "Usage: $0 [OPTIONS]"
 echo "Options:"
 echo " -h, --help      Display this help message"
 echo " -a, --args      Additional build arguments to pass to docker buildx build"
 echo " -b, --base      Docker base image"
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

docker-build() {

    docker_tag="--tag $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/$image_tag"

    if [[ "$PUSH_TO_DOCKERHUB" == "true" ]]; then
        docker_tag+=" --tag docker.io/$image_tag"
    fi

    docker buildx build \
            --push \
            --platform "${PLATFORMS}" \
            --no-cache \
            "$docker_tag" \
            "$build_arguments"

}

#########################################
# Main
#########################################

parse_flags "$@"

echo "[INFO] Docker build arguments: $build_arguments"
echo "[INFO] Docker image tag: $image_tag"

docker-build