# Copyright Thales 2025
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#!/usr/bin/env sh

# Install requirements
apk update
apk add --no-cache kubectl helm

# Patch kubeconfig
if ! kubectl config get-contexts | grep -q k8s-cluster-local
then
    kubectl config set-cluster default --server=https://app-kube:6443
    kubectl config rename-context default k8s-cluster-local
fi

# Install some helm charts for demo purposes
helm install kafka oci://registry-1.docker.io/bitnamicharts/kafka --namespace messaging --create-namespace
helm install nginx oci://registry-1.docker.io/bitnamicharts/nginx --namespace web --create-namespace
helm install redis oci://registry-1.docker.io/bitnamicharts/redis --namespace cache --create-namespace
helm install postgresql oci://registry-1.docker.io/bitnamicharts/postgresql --namespace database --create-namespace
helm install dashboard oci://registry-1.docker.io/bitnamicharts/kubernetes-dashboard --namespace dashboard --create-namespace

# # Install kubernetes dashboard
# helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
# helm repo update
# helm install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard --namespace dashboard --create-namespace \
#     --set app.ingress.enabled=true \
#     --set app.ingress.hosts[0]=${DOCKER_COMPOSE_HOST_FQDN:-localhost}
