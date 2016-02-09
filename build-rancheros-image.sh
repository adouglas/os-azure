#!/bin/bash
set -e -x

cd $(dirname $0)

## Pre-requisites:
## - installed packages: apg, jq
## - you are logged in with azure cli

. ./common.sh

BUILD_HOST=build-$(apg -a 1 -n 1 -m 7 -x 7 -M NL)
BUILD_HOST_IMAGE="2b171e93f07c4903bcad35bda10acf22__CoreOS-Stable-835.12.0"
BUILD_HOST_USER="core"

azure vm create -z Standard_D2 -l "West US" -e -P -t ${BUILD_USER_CERT} ${BUILD_HOST} ${BUILD_HOST_IMAGE} ${BUILD_HOST_USER}
azure vm disk attach-new ${BUILD_HOST} 50

until ssh -F ./ssh_config -i ${BUILD_USER_KEY} ${BUILD_HOST_USER}@${BUILD_HOST}.cloudapp.net /bin/true; do
  sleep 2
done

sftp -F ./ssh_config -i ${BUILD_USER_KEY} ${BUILD_HOST_USER}@${BUILD_HOST}.cloudapp.net:/home/${BUILD_HOST_USER} <<EOF
put azure.yml
EOF

ssh -F ./ssh_config -i ${BUILD_USER_KEY} ${BUILD_HOST_USER}@${BUILD_HOST}.cloudapp.net <<EOF
  docker pull imikushin/waagent
  docker tag imikushin/waagent waagent

  docker pull imikushin/sshwatcher
  docker tag imikushin/sshwatcher sshwatcher

  docker pull imikushin/debianconsole:v0.3.1
  docker tag imikushin/debianconsole:v0.3.1 rancher/debianconsole:v0.3.1

  echo Saving docker images to: azure.tar.xz ...
  docker save waagent sshwatcher rancher/debianconsole:v0.3.1 | xz > azure.tar.xz
  echo Done.

  docker run --privileged --net=host --entrypoint=/scripts/set-disk-partitions imikushin/os:${RANCHEROS_VERSION} /dev/sdc

  docker run --privileged --net=host -v=/home:/home \
    -e KERNEL_ARGS='earlyprintk=ttyS0 rootdelay=300' \
    imikushin/os:${RANCHEROS_VERSION} \
      -d /dev/sdc -t generic -c /home/${BUILD_HOST_USER}/azure.yml \
      -f /home/${BUILD_HOST_USER}/azure.tar.xz:/lib/system-docker/preload/azure.tar.xz
EOF

mkdir -p ./tmp

azure vm disk list --json -d ${BUILD_HOST}.cloudapp.net > ./tmp/disks.json

DISK_NAME=$(cat tmp/disks.json | jq '.[1].name' | xargs -I{} echo {})
IMAGE_VHD=$(cat tmp/disks.json | jq '.[1].mediaLink' | xargs -I{} echo {})

azure vm disk detach ${BUILD_HOST} 0
echo "Sleeping for 60 seconds... (let azure finish with detaching the disk)"
sleep 60

azure vm disk delete ${DISK_NAME}

azure vm delete -q -b ${BUILD_HOST}

azure vm image create -o linux -u ${IMAGE_VHD} ${RANCHEROS_IMAGE}
