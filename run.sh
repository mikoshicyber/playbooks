#!/bin/bash
IMAGE=quay.io/ansible/awx-ee:latest
SOURCE_DIR=/mnt/autodownloads
# docker run --rm -it -v "$PWD":/work -w /work quay.io/ansible/awx-ee:latest ansible -i inventory.yaml -m ping all -o
# docker run --rm -it -v "$PWD":/work -w /work -e "HOME=/work" quay.io/ansible/awx-ee:latest ansible-galaxy collection install community.windows -p .ansible/collections
docker run --rm -it -v "$PWD"/win_soft_management:/work -v "${SOURCE_DIR}":/source -w /work -e "HOME=/work" ${IMAGE} ansible-playbook -i inventory.yaml $@