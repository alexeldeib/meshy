#!/usr/bin/env bash

set -euxo pipefail

WORKDIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
PROJECT="$(gcloud config get core/project)"
pushd $WORKDIR
trap 'popd' INT TERM EXIT

rm ~/.kube/config || true

gcloud container clusters get-credentials ${PROJECT}-east --location=us-east4
mv ~/.kube/config $WORKDIR/kubeconfig-east

gcloud container clusters get-credentials ${PROJECT}-west --location=us-central1
mv ~/.kube/config $WORKDIR/kubeconfig-west

function keast() {
    kubectl --kubeconfig $WORKDIR/kubeconfig-east $@
}

function kwest() {
    kubectl --kubeconfig $WORKDIR/kubeconfig-west $@
}

function least() {
    linkerd --kubeconfig $WORKDIR/kubeconfig-east $@
}

function lwest() {
    linkerd --kubeconfig $WORKDIR/kubeconfig-west $@
}

# step certificate create root.linkerd.cluster.local root.crt root.key --profile root-ca --no-password --insecure
# step certificate create identity.linkerd.cluster.local issuer.crt issuer.key --profile intermediate-ca --not-after 8760h --no-password --insecure --ca root.crt --ca-key root.key


linkerd --kubeconfig $WORKDIR/kubeconfig-west install --crds | kubectl --kubeconfig $WORKDIR/kubeconfig-west apply -f -
linkerd --kubeconfig $WORKDIR/kubeconfig-east install --crds | kubectl --kubeconfig $WORKDIR/kubeconfig-east apply -f -

# then install the Linkerd control plane in both clusters
linkerd --kubeconfig $WORKDIR/kubeconfig-west install --identity-trust-anchors-file root.crt  --identity-issuer-certificate-file issuer.crt  --identity-issuer-key-file issuer.key | kubectl --kubeconfig $WORKDIR/kubeconfig-west apply -f -
linkerd --kubeconfig $WORKDIR/kubeconfig-east install --identity-trust-anchors-file root.crt  --identity-issuer-certificate-file issuer.crt  --identity-issuer-key-file issuer.key | kubectl --kubeconfig $WORKDIR/kubeconfig-east apply -f -

for ctx in west east; do
    linkerd --kubeconfig $WORKDIR/kubeconfig-${ctx} viz install | kubectl --kubeconfig $WORKDIR/kubeconfig-${ctx} apply -f -
done

for ctx in west east; do
    echo "Checking cluster: ${ctx} ........."
    linkerd --kubeconfig $WORKDIR/kubeconfig-${ctx} check || break
    echo "-------------"
done

for ctx in west east; do
    echo "Installing on cluster: ${ctx} ........."
    linkerd --kubeconfig $WORKDIR/kubeconfig-${ctx} multicluster install | kubectl --kubeconfig $WORKDIR/kubeconfig-${ctx} apply -f -
    echo "-------------"
done

for ctx in west east; do
    echo "Checking gateway on cluster: ${ctx} ........."
    kubectl --kubeconfig $WORKDIR/kubeconfig-${ctx} -n linkerd-multicluster \
    rollout status deploy/linkerd-gateway || break
    echo "-------------"
done

for ctx in west east; do
    printf "Checking cluster: ${ctx} ........."
    while [ "$(kubectl --kubeconfig $WORKDIR/kubeconfig-${ctx} -n linkerd-multicluster get service -o 'custom-columns=:.status.loadBalancer.ingress[0].ip' --no-headers)" = "<none>" ]; do
        printf '.'
        sleep 1
    done
    printf "\n"
done

linkerd --kubeconfig $WORKDIR/kubeconfig-east multicluster link --cluster-name east | kubectl --kubeconfig $WORKDIR/kubeconfig-west apply -f -
linkerd --kubeconfig $WORKDIR/kubeconfig-west multicluster check
linkerd --kubeconfig $WORKDIR/kubeconfig-west multicluster gateways

for ctx in west east; do
  echo "Adding test services on cluster: ${ctx} ........."
  kustomize build $WORKDIR/../manifests/${ctx} | k${ctx} apply -n test -
  k${ctx} -n test rollout status deploy/podinfo || break
  echo "-------------"
done

kubectl --kubeconfig $WORKDIR/kubeconfig-east label svc -n test podinfo mirror.linkerd.io/exported=true
kubectl --kubeconfig $WORKDIR/kubeconfig-west -n test get svc podinfo-east

kubectl --kubeconfig $WORKDIR/kubeconfig-west -n test get endpoints podinfo-east -o 'custom-columns=ENDPOINT_IP:.subsets[*].addresses[*].ip'
kubectl --kubeconfig $WORKDIR/kubeconfig-east -n linkerd-multicluster get svc linkerd-gateway -o "custom-columns=GATEWAY_IP:.status.loadBalancer.ingress[*].ip"

