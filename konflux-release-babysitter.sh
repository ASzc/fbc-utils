#!/bin/bash

set -euo pipefail

commit_override="${1:-}"

namespace="rhbk-release-tenant"

if [ -n "$commit_override" ]
then
    commit="$commit_override"
else
    git checkout main >&2
    git pull --rebase >&2
    commit="$(git rev-parse HEAD)"
fi
git show "$commit" >&2
read -rn1 -p "Is the above commit ok to release? [y/N]: "
echo "" >&2
if ! [[ $REPLY =~ ^[Yy]$ ]]
then
    echo "Error: User rejected the commit, aborting" >&2
    exit 2
fi

origin_dir="$(readlink -e .)"
tmp_dir="/tmp/krb"
rm -rf "$tmp_dir"
mkdir "$tmp_dir"
cd "$tmp_dir"

# Ensure that there's a successful build of each version of the FBC for the head commit
git -C "$origin_dir" show "$commit:config.yaml" | yq -e e '.ocp | .[]' | sort -V > active_ocp_versions

while true
do
    echo "" >&2
    cat active_ocp_versions >&2
    echo "" >&2
    read -rn1 -p "Are the above active OCP versions ok to release to? [y/e/N]: "
    echo "" >&2
    if [[ $REPLY =~ ^[Ee]$ ]]
    then
        $EDITOR active_ocp_versions
    elif ! [[ $REPLY =~ ^[Yy]$ ]]
    then
        echo "Error: User rejected the OCP versions, aborting" >&2
        exit 2
    else
        break
    fi
done

# Retry until all snapshots are available
echo "Checking for available snapshots"
echo ""
firstloop="yes"
touch prev_available_ocp_versions
while true
do
    oc get -o json snapshot -n "$namespace" | jq -r --arg commit "$commit" '.items | .[] | select(.metadata.annotations."build.appstudio.redhat.com/commit_sha" == $commit) | [.metadata.name, .spec.components[0].containerImage] | @tsv' | sort -V | grep -f active_ocp_versions > snapshots

    sed -r 's/.*(v[0-9]+)-([0-9]+).*/\1.\2/' snapshots > available_ocp_versions

    if [ -n "$firstloop" ]
    then
        sed -r 's/^/-> /' available_ocp_versions
        firstloop=""
    else
        grep -Fxvf available_ocp_versions prev_available_ocp_versions | sed -r 's/^/-> /' || true
    fi
    cp available_ocp_versions prev_available_ocp_versions

    if ! diff active_ocp_versions available_ocp_versions >/dev/null
    then
        sleep 5m
    else
        break
    fi
done

echo ""
echo "Releasing snapshots"
echo ""
firstloop="yes"
# Retry until all builds are released
while true
do
    pending_releases=""

    timestamp="$(date +%s)"

    # Fetch existing releases
    oc get -o json releases -n "$namespace" | jq -r '.items | .[] | select(.spec.releasePlan | contains("prod-release-plan")) | [.metadata.name, (.status.conditions | .[] | select(.type == "Released") | .reason, .message)] | @tsv' > releases

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
                if [ -n "$firstloop" ]
                then
                    echo "-> $root in progress" >&2
                fi
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
                if [ -n "$firstloop" ]
                then
                    echo "-> $root released ok" >&2
                fi
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
  namespace: $namespace
spec:
  releasePlan: $release_plan
  snapshot: $snapshot
EOF

        oc apply -n "$namespace" -f "$release_name.yaml"
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

    firstloop=""
done
