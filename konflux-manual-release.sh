#!/bin/bash

set -euo pipefail

commit="${1:?Specify full git commit ID, ex: ef49b86f7c250fb80253fe0ef9e743ba6f8e48a0}"

tmp_dir="/tmp/kmr"
rm -rf "$tmp_dir"
mkdir "$tmp_dir"
cd "$tmp_dir"

echo "=> Generating YAMLs" >&2

while IFS=$'\t' read -r snapshot imagecoord
do
    root="${snapshot%-*}"
    echo " -> $root" >&2
    echo "$imagecoord"

    release_name="$snapshot-manual-release"
    release_plan="$root-prod-release-plan"

    cat >"$release_name.yaml" <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: $release_name
  namespace: rhbk-release-tenant
spec:
  releasePlan: $release_plan
  snapshot: $snapshot
EOF
done < <(
    oc get -o json snapshot --kubeconfig="$HOME/.kube/konflux-kubeconfig-rhbk.yaml" | \
        jq -r --arg commit "$commit" '.items | .[] | select(.metadata.annotations."build.appstudio.redhat.com/commit_sha" == $commit) | [.metadata.name, .spec.components[0].containerImage] | @tsv'
)

echo "=> Done, review and if ok, then run: oc apply --kubeconfig=$HOME/.kube/konflux-kubeconfig-yourproduct.yaml -f $tmp_dir" >&2
