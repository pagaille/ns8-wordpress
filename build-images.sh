#!/bin/bash

#
# Copyright (C) 2023 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#

# Terminate on error
set -ex

# Prepare variables for later use
images=()
# The image will be pushed to GitHub container registry
repobase="${REPOBASE:-ghcr.io/pagaille}"

#Create webt-op-webapp container
reponame="ns8-ordpress672-app-pagaille"
container=$(buildah from docker.io/wordpress:6.7.2-php8.0-apache)
buildah run "${container}" /bin/sh <<'EOF'
docker-php-ext-install pdo_mysql
docker-php-ext-install calendar

EOF
# Commit the image
buildah commit --rm "${container}" "${repobase}/${reponame}"

# Append the image URL to the images array
images+=("${repobase}/${reponame}")


# Configure the image name
reponame="wordpress"

# Create a new empty container image
container=$(buildah from scratch)
# Reuse existing nodebuilder-wordpress container, to speed up builds
if ! buildah containers --format "{{.ContainerName}}" | grep -q nodebuilder-wordpress; then
    echo "Pulling NodeJS runtime..."
    buildah from --name nodebuilder-wordpress -v "${PWD}:/usr/src:Z" docker.io/library/node:lts
fi

echo "Build static UI files with node..."
buildah run \
    --workingdir=/usr/src/ui \
    --env="NODE_OPTIONS=--openssl-legacy-provider" \
    nodebuilder-wordpress \
    sh -c "yarn install && yarn build"

# Add imageroot directory to the container image
buildah add "${container}" imageroot /imageroot
buildah add "${container}" ui/dist /ui

# Setup the entrypoint, ask to reserve one TCP port with the label and set a rootless container
# Select you image(s) with the label org.nethserver.images
# ghcr.io/xxxxx is the GitHub container registry or your own registry or docker.io for Docker Hub
# The image tag is set to latest by default, but can be overridden with the IMAGETAG environment variable
# --label="org.nethserver.images=docker.io/mariadb:10.11.11 docker.io/roundcube/roundcubemail:1.6.4-apache"
# rootfull=0 === rootless container
# tcp-ports-demand=1 number of tcp Port to reserve , 1 is the minimum, can be udp or tcp
buildah config --entrypoint=/ \
    --label="org.nethserver.authorizations=traefik@node:routeadm" \
    --label="org.nethserver.tcp-ports-demand=3" \
    --label="org.nethserver.rootfull=0" \
    --label="org.nethserver.images=docker.io/mariadb:10.11.11 ${repobase}/wordpress-app:${IMAGETAG:-latest}" \
    "${container}"

# Commit the image
buildah commit "${container}" "${repobase}/${reponame}"

# Append the image URL to the images array
images+=("${repobase}/${reponame}")

#
# NOTICE:
#
# It is possible to build and publish multiple images.
#
# 1. create another buildah container
# 2. add things to it and commit it
# 3. append the image url to the images array
#

#
# Setup CI when pushing to Github. 
# Warning! docker::// protocol expects lowercase letters (,,)

if [[ -n "${CI}" ]]; then
    # Set output value for Github Actions
    printf "images=%s\n" "${images[*],,}" >> "${GITHUB_OUTPUT}"
else
    # Just print info for manual push
    printf "Publish the images with:\n\n"
    for image in "${images[@],,}"; do printf "  buildah push %s docker://%s:%s\n" "${image}" "${image}" "${IMAGETAG:-latest}" ; done
    printf "\n"
fi
