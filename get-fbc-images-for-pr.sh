#!/bin/bash

set -euo pipefail

repo="${1:?Specify github repository. ex: rhbk/rhbk-fbc}"
pr="${2:?Specify pull request number. ex: 44}"

call_gh() {
    set -euo pipefail
    api_path="$1"
    shift
    curl -sSfL \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$@" \
        "https://api.github.com/$api_path"
}

echo "=> Querying $repo/pull/$pr" >&2
commit="$(call_gh "repos/$repo/pulls/$pr/commits" | jq -r '.[0] | .sha')"
echo "=> Head commit ${commit:0:10}" >&2

echo "=> Finding image coordinates" >&2
error=""
completed_check_ids=()
while true
do
    waiting=""
    while IFS=$'\t' read -r id status conclusion html_url details_url
    do
        # Don't repeatedly show checks that we've already shown as pass/fail
        skip=""
        for completed_id in "${completed_check_ids[@]}"
        do
            if [[ "$completed_id" == "$id" ]]
            then
                skip="yes"
            fi
        done
        if [ -n "$skip" ]
        then
            continue
        fi

        if [[ "$status" == "completed" ]] && [[ "$conclusion" == "success" ]]
        then
            echo " -> $id has $status ok" >&2
            completed_check_ids+=("$id")
            # ex: https://console.redhat.com/preview/application-pipeline/ns/rhbk-release-tenant/pipelinerun/rhbk-fbc-component-v4-12-on-pull-request-4rpfs
            IFS=$'\t' read -r konflux_namespace konflux_component < <(sed -r 's|^.*/ns/([^/]+)/pipelinerun/([^/]+)-on-pull-request[^/]*$|\1\t\2|;tx;d;:x' <<<"$details_url")

            # New format with just namespace and component name
            image_coord="quay.io/redhat-user-workloads/$konflux_namespace/$konflux_component:on-pr-$commit"
            if ! skopeo inspect --no-tags "docker://$image_coord" >/dev/null 2>&1
            then
                echo " -> Image not found, trying fallback image location" >&2
                konflux_application="$(sed 's/-component//' <<<"$konflux_component")"

                # ex: quay.io/redhat-user-workloads/rhbk-release-tenant/rhbk-fbc-v4-13/rhbk-fbc-component-v4-13:on-pr-51476f518900c699e66c4d0fdd33dbb9524e83de
                image_coord="quay.io/redhat-user-workloads/$konflux_namespace/$konflux_application/$konflux_component:on-pr-$commit"

                if ! skopeo inspect --no-tags "docker://$image_coord" >/dev/null
                then
                    echo "ERROR: No image found for $id, see $html_url" >&2
                    error="yes"
                else
                    echo "$image_coord"
                fi
            else
                echo "$image_coord"
            fi
        elif [[ "$status" != "completed" ]]
        then
            echo " -> $id is $status" >&2
            waiting="yes"
        else
            echo "ERROR: $id is $status ($conclusion), see $html_url" >&2
            error="yes"
            completed_check_ids+=("$id")
        fi
    done < <(
        call_gh "repos/$repo/commits/$commit/check-runs" \
            | jq -r '.check_runs
                | .[]
                | select(.external_id | contains("-on-pull-request-"))
                | [.external_id, .status, .conclusion, .html_url, .details_url]
                | @tsv' \
            | sort -V
    )
    if [ -z "$waiting" ]
    then
        break
    else
        echo "=> Waiting for checks to complete..." >&2
        sleep 120s
    fi
done
if [ -n "$error" ]
then
    echo "ERROR: One or more index images could not be found" >&2
    exit 1
fi
