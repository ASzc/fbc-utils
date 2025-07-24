#!/bin/bash

set -euo pipefail

fbc_index_image_coord="${1?:Supply fragmentary FBC index image coordinate to test, ex: quay.io/redhat-user-workloads/rhbk-release-tenant/rhbk-fbc-v4-15/rhbk-fbc-component-v4-15:on-pr-d8d77b76503d9d94c98926c053bcdf80b074c9cd}"

echo "=> Setup" >&2

bin_dir="$(readlink -f bin)"
mkdir -p "$bin_dir"
export PATH="$bin_dir:$PATH"

work_dir="$(readlink -f workdir)"
rm -rf "$work_dir"
mkdir "$work_dir"

cd "$bin_dir"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m | sed 's/x86_64/amd64/')"

# Configure bin directory as specified in the HEREDOC
while IFS=' ' read -r name version url_template
do
    # Download if required
    versioned_filename="$name-$version"
    if ! [ -x "$versioned_filename" ]
    then
        echo "  -> Downloading $name" >&2
        url="$(eval echo "$url_template")"
        curl -sSfL --retry 5 -o "$versioned_filename" "$url"

        # Unpack zip if needed
        if grep -q '.zip$' <<<"$url"
        then
            unzip -qp "$versioned_filename" "$name" > "$versioned_filename.bin"
            mv "$versioned_filename.bin" "$versioned_filename"
        fi

        # Make executable
        chmod +x "$versioned_filename"
    fi

    # Set current version to active binary for this name
    ln -fs "$versioned_filename" "$name"
done <<'EOF'
kubectl v1.29.2 https://dl.k8s.io/release/$version/bin/$os/$arch/kubectl
kind v0.23.0 https://kind.sigs.k8s.io/dl/$version/kind-$os-$arch
operator-sdk v1.34.2 https://github.com/operator-framework/operator-sdk/releases/download/$version/operator-sdk_${os}_${arch}
EOF

cd "$work_dir"

echo "=> Setup OLM" >&2
export KUBECONFIG="$work_dir/kubeconfig"

kind_cluster_name="fbc-test"
echo "  -> KIND cluster $kind_cluster_name" >&2
#kind delete cluster --name "$kind_cluster_name"
if kind create cluster --name "$kind_cluster_name"
then
    echo "  -> Applying extra first-time KIND setup" >&2
    cat > config.toml <<EOF
[plugins."io.containerd.grpc.v1.cri".registry]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.redhat.io"]
      endpoint = ["https://brew.registry.redhat.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."brew.registry.redhat.io"]
      endpoint = ["https://brew.registry.redhat.io"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs]
    [plugins."io.containerd.grpc.v1.cri".registry.configs."brew.registry.redhat.io".auth]
      username = "$RH_REGISTRY_USERNAME"
      password = '$RH_REGISTRY_PASSWORD'
EOF
    set -x
    podman exec -i fbc-test-control-plane tee -a /etc/containerd/config.toml < config.toml >/dev/null
    podman exec -t fbc-test-control-plane systemctl restart containerd

    operator-sdk olm install
    { set +x; } 2>/dev/null
else
    echo "  -> Resetting existing KIND" >&2
    kind export kubeconfig --name "$kind_cluster_name"

    kubectl get namespaces -o name | grep fbc-test | xargs -r kubectl delete
fi

echo "  -> Create CatalogSource and remove all others" >&2
catalog_name="fbc-catalog"
cat > catalog.yaml <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $catalog_name
  namespace: olm
spec:
  sourceType: grpc
  image: $fbc_index_image_coord
  displayName: FBC Catalog
  publisher: grpc
EOF
kubectl delete -n olm catalogsource --all
kubectl apply -f catalog.yaml

echo "  -> Wait for PackageManifest" >&2
sleep 30s
while true
do
    kubectl get packagemanifest -o name > package_fqn
    [ -s package_fqn ] && break
    sleep 30s
done
package_name="$(cut -d/ -f2 package_fqn)"
echo "  -> Found operator '$package_name'"  >&2

echo "=> Test install of head and tail for each channel" >&2
kubectl get -o json packagemanifest "$package_name" | jq '.status.channels | .[] | {"name": .name, "entries": (.entries | [ .[] | .name ])}' > channels

i=0
while read -r channel
do
    while read -r version_name
    do
        printf '%s\t%s\t%s\n' "fbc-test-$i" "$version_name" "$channel"
        (( i++ )) || true
    done < <(jq -r --arg N "$channel" 'select(.name == $N) | [.entries[0], .entries[-1]] | .[]' channels)
done < <(jq -r '.name' channels) > setup_plan

echo "  -> Setup $(wc -l setup_plan | cut -d' ' -f1) namespaces"  >&2
while read -r namespace version_name channel
do
    kubectl create namespace "$namespace" >&2

    cat > operatorgroup.yaml <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operatorgroup-$package_name
  namespace: $namespace
spec:
  targetNamespaces:
  - $namespace
EOF
    kubectl apply -f operatorgroup.yaml >&2
    cat > subscription.yaml <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: subscription-$package_name
  namespace: $namespace
spec:
  channel: $channel
  name: $package_name
  source: $catalog_name
  sourceNamespace: olm
  installPlanApproval: Manual
  startingCSV: $version_name
EOF
    kubectl apply -f subscription.yaml >&2

    echo "$namespace"
done < setup_plan > namespaces

installplan_go() {
    set -euo pipefail

    all_namespaces="${1:-}"

    echo "  -> Wait for InstallPlans"  >&2
    while true
    do
        kubectl get -A -o json subscription | jq -r '.items | .[] | select(.spec.approved == false or .status.state == "UpgradePending") | [.metadata.namespace, .status.currentCSV, .status.installPlanRef.name, .status.state] | @tsv' > subscription-state
        if [ -n "$all_namespaces" ] && ! grep -qFf namespaces subscription-state
        then
            cat subscription-state >&2
            sleep 30s
        elif ! [ -s subscription-state ]
        then
            sleep 10s
        else
            break
        fi
    done

    echo "  -> Approve InstallPlans"  >&2
    while IFS=$'\t' read -r namespace csv installplan state
    do
        kubectl patch -n "$namespace" installplan "$installplan" --type merge --patch '{"spec":{"approved":true}}'
    done < subscription-state

    echo "  -> Wait for approved installs to occur"  >&2
    while grep -q 'UpgradePending$' subscription-state
    do
        cat subscription-state >&2
        sleep 30s
        kubectl get -A -o json subscription | jq -r '.items | .[] | select(.spec.approved == true) | [.metadata.namespace, .status.currentCSV, .status.installPlanRef.name, .status.state] | @tsv' > subscription-state
    done
    cat subscription-state >&2
}

installplan_go yes

echo "=> Test intra-channel upgrades" >&2
installplan_go

echo "=> Test inter-channel upgrades" >&2
latest_channel="$(jq -r '.name' channels | sort -V | tail -n1)"
echo "  -> Switch channels to latest"  >&2
while IFS=$'\t' read -r namespace name current_channel
do
    if [[ "$current_channel" != "$latest_channel" ]]
    then
        echo "$namespace: $current_channel to $latest_channel" >&2
        kubectl patch -n "$namespace" subscription "$name" --type merge -p "{\"spec\":{\"channel\": \"$latest_channel\"}}"
    fi
done < <(kubectl get -A -o json subscription | jq -r '.items | .[] | [.metadata.namespace, .metadata.name, .spec.channel] | @tsv')

installplan_go

echo "" >&2
echo "=> Testing Completed OK!" >&2
