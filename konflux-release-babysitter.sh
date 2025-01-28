#!/bin/bash

set -euo pipefail

if ! cfg="$(readlink -e config.yaml)"
then
    echo "Could not find config file" >&2
    exit 1
fi

product="rhbk"
kubeconfig="$HOME/.kube/konflux-kubeconfig-$product.yaml"

git checkout main >&2
git pull --rebase >&2
commit="$(git rev-parse HEAD)"
git show HEAD >&2
read -rn1 -p "Is the above commit ok to release? [y/N]: "
echo "" >&2
if ! [[ $REPLY =~ ^[Yy]$ ]]
then
    echo "Error: User rejected the commit, aborting" >&2
    exit 2
fi

tmp_dir="/tmp/krb"
rm -rf "$tmp_dir"
mkdir "$tmp_dir"
cd "$tmp_dir"

# Ensure that there's a successful build of each version of the FBC for the head commit
yq -e e '.ocp | .[]' "$cfg" | sort -V > active_ocp_versions

oc get -o json snapshot --kubeconfig="$kubeconfig" | jq -r --arg commit "$commit" '.items | .[] | select(.metadata.annotations."build.appstudio.redhat.com/commit_sha" == $commit) | [.metadata.name, .spec.components[0].containerImage] | @tsv' | sort -V > snapshots

sed -r 's/.*(v[0-9]+)-([0-9]+).*/\1.\2/' snapshots > available_ocp_versions

if ! diff -u active_ocp_versions available_ocp_versions
then
    echo "Error: A snapshot is not available for all active OCP versions" >&2
    exit 1
fi

echo "" >&2
cat available_ocp_versions >&2
echo "" >&2
read -rn1 -p "Are the above active OCP versions ok to release to? [y/N]: "
echo "" >&2
if ! [[ $REPLY =~ ^[Yy]$ ]]
then
    echo "Error: User rejected the OCP versions, aborting" >&2
    exit 2
fi

# Retry until all builds are released
while true
do
    pending_releases=""

    timestamp="$(date +%s)"

    # Fetch existing releases
    oc get -o json releases --kubeconfig="$kubeconfig" | jq -r '.items | .[] | select(.spec.releasePlan | contains("prod-release-plan")) | [.metadata.name, (.status.conditions | .[] | select(.type == "Released") | .reason, .message)] | @tsv' > releases

    # Handle each snapshot as required
    while IFS=$'\t' read -r snapshot imagecoord
    do
        root="${snapshot%-*}"

        release_plan="$root-prod-release-plan"

        if IFS=$'\t' read -r existing_release_name release_status release_message < <(grep -F "$snapshot" releases | tail -n1 || true)
        then
            if [[ "$release_status" == "Progressing" ]]
            then
                # Do nothing for any snapshot with an ongoing release
                pending_releases="yes"
                continue
            elif [[ "$release_status" == "Failed" ]]
            then
                # Retry failed releases
                echo "-> $root failed, retrying" >&2
                pending_releases="yes"
            elif [[ "$release_status" == "Succeeded" ]]
            then
                # Successful
                continue
            fi
        else
            # First release for this snapshot
            echo "-> $root"
            pending_releases="yes"
        fi

        release_name="$snapshot-release-$timestamp"
        echo "Creating release $release_name for snapshot $snapshot" >&2

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

        oc apply --kubeconfig="$kubeconfig" -f "$release_name.yaml"
        pending_releases="yes"
    done < snapshots

    if [ -z "$pending_releases" ]
    then
        # Done
        echo "" >&2
        echo "" >&2
        grep Succeeded releases
        echo "" >&2
        echo "All snapshots released successfully" >&2
        exit 0
    else
        # Wait for Konflux to process pending releases
        sleep 5m
    fi
done
