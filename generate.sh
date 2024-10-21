#!/usr/bin/env bash

set -euo pipefail

#
# Setup
#

if ! cfg="$(readlink -e config.yaml)"
then
    echo "Could not find config file $cfg" >&2
    exit 1
fi

echo "=> Setting up" >&2

# Save starting dir as the place to put the catalog files
catalog_dir="$(readlink -e .)"

# We need a few binaries at specific versions, so create a local cache for those
bin_dir="$(readlink -f bin)"
mkdir -p "$bin_dir"
export PATH="$bin_dir:$PATH"

# There will be some temporary files, put these together for neatness, and so
# they can be easily deleted.
work_dir="$(readlink -f workdir)"
rm -rf "$work_dir"
mkdir "$work_dir"

# Acquire any missing binaries
cd "$bin_dir"

# Being binaries, they're OS and Arch specific
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m | sed 's/x86_64/amd64/')"

# These are the specific versions we want
opm_version="v1.47.0"
yq_version="v4.22.1"
tf_version="v0.1.0"

# Store them first into a versioned filename so the bin dir never gets stale if
# the required versions change.
opm_filename="opm-$opm_version"
yq_filename="yq-$yq_version"
tf_filename="tf-$tf_version"

if ! [ -x "$opm_filename" ]
then
    echo "-> Downloading opm" >&2
    curl -sSfLo "$opm_filename" "https://github.com/operator-framework/operator-registry/releases/download/$opm_version/$os-$arch-opm"
    chmod +x "$opm_filename"
fi
ln -fs "$opm_filename" opm

if ! [ -x "$yq_filename" ]
then
    echo "-> Downloading yq" >&2
    curl -sSfLo "$yq_filename" "https://github.com/mikefarah/yq/releases/download/$yq_version/yq_${os}_$arch"
    chmod +x "$yq_filename"
fi
ln -fs "$yq_filename" yq

#
# Generate Config YAMLs
#

cd "$work_dir"

echo "=> Checking config" >&2

# Should be equal to .spec.name from the bundle CSVs
operator_name="$(yq -e ea '.name' "$cfg")"

# Assume the replacement with "bundle" in the name is the one we need to prefix
# onto the bundle hashes listed in the config YAML.
IFS=$'\t' read -r bundle_reg_from bundle_reg_to < <(yq -e -o tsv ea '.replacements[] | select(.from == "*bundle*") | [.from, .to]' "$cfg")

# opm will need to access the images in this registry to do its work
# https://source.redhat.com/groups/public/teamnado/wiki/brew_registry#obtaining-registry-tokens
registry="$(cut -f1 -d/ <<<"$bundle_reg_from")"
if ! skopeo login --get-login "$registry" >/dev/null
then
    echo "Login to $registry before running this script" >&2
    exit 125
fi

readarray -t ocp_versions < <(yq -e ea '.ocp[]' "$cfg")

echo "=> Generating catalog configuration" >&2

echo "-> Applying bundle image list" >&2
render_config="semver-template.yaml"
{
    # Write intial config values
    cat <<EOF
schema: olm.semver
generatemajorchannels: true
generateminorchannels: false
stable:
  bundles:
EOF
    # Append the bundle image coordinates.
    # We're using an initial "from" registry and switching it later because opm
    # can't be configured with a mirror replacement policy, and some of these
    # bundle images may currently be only present in the "from" registry, not
    # the public "to" registry.
    yq -e ea '.bundles | .[]' "$cfg" | xargs -n1 printf '    - image: %s@%s\n' "$bundle_reg_from"
} > "$render_config"

#
# Generate Catalog
#

echo "=> Generating catalog for $operator_name" >&2

echo "-> opm render" >&2
opm alpha render-template semver -o yaml semver-template.yaml > "bo-catalog.yaml"
echo "-> opm render --migrate" >&2
opm alpha render-template semver --migrate-level=bundle-object-to-csv-metadata -o yaml semver-template.yaml > "cm-catalog.yaml"
for ocp_ver in "${ocp_versions[@]}"
do
    # For OCP versions equal or newer than 4.17, use csv-metadata formatted bundle info inside catalog
    if printf '%s\n' "$ocp_ver" "v4.17" | sort -V | head -n1 | grep -q -xF 'v4.17'
    then
        catalog_format="cm-catalog.yaml"
    else
        catalog_format="bo-catalog.yaml"
    fi
    mkdir -p "catalog/$ocp_ver/$operator_name"
    cp "$catalog_format" "catalog/$ocp_ver/$operator_name/catalog.yaml"
done

# Optionally, add a skipRange relationship between the first version in a
# channel and all prior versions in the previous channel. This allows automatic
# upgrades between major versions when the channels go stable-v22, stable-v24,
# etc. This won't do anything if there's only one channel so far.
if yq -e e '.upgrade.between_major' "$cfg" 2>/dev/null | grep -qi 'skipRange'
then
    echo "-> Major version upgrade fix (skipRange)" >&2
    while read -r catalog
    do
        previous_first_entry_name=""
        while IFS=$'\t' read -r name first_entry_name
        do
            if [ -n "$previous_first_entry_name" ]
            then
                # ex: rhbk-operator.v24.0.3-opr.1 -> 24.0.3-opr.1
                low_ver="$(cut -d. -f2- <<<"$previous_first_entry_name" | sed 's/^v//')"
                high_ver="$(cut -d. -f2- <<<"$first_entry_name" | sed 's/^v//')"
                skip_range=">=$low_ver <$high_ver"

                n="$name" r="$skip_range" yq -ei e 'select(.schema == "olm.channel" and .name == strenv(n)).entries[-1].skipRange = strenv(r)' "$catalog"
            fi
            previous_first_entry_name="$first_entry_name"
        done < <(yq -o tsv -e e 'select(.schema == "olm.channel" and (.name | contains("stable-"))) | [.name, .entries[0].name]' "$catalog")
    done < <(find catalog/ -type f -name 'catalog.yaml')
fi

echo "-> Dockerfiles" >&2
for ocp_ver in "${ocp_versions[@]}"
do
    mkdir -p catalog/$ocp_ver
    pushd catalog/$ocp_ver
    ocp_image_ver_name=
    # OCP version 4.15 changed the image name
    if [[ "$(printf '%s\n' "v4.14" "$ocp_ver" | sort -V | tail -n1)" == "v4.14" ]]
    then
        # Use old form <= v4.14
        ocp_image_name="ose-operator-registry"
    else
        # Use new form > v4.14
        ocp_image_name="ose-operator-registry-rhel9"
    fi

    cat > Dockerfile <<EOF
# The base image is expected to contain
# /bin/opm (with a serve subcommand) and /bin/grpc_health_probe
FROM registry.redhat.io/openshift4/$ocp_image_name:$ocp_ver

# Configure the entrypoint and command
ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs", "--cache-dir=/tmp/cache"]

# Copy declarative config root into image at /configs and pre-populate serve cache
ADD $operator_name /configs/$operator_name
RUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]

# Set DC-specific label for the location of the DC root directory
# in the image
LABEL operators.operatorframework.io.index.configs.v1=/configs
EOF

    popd
done

echo "-> Replacing registries" >&2
# This step is required because opm doesn't support registry mirrors, and must
# be able to see the images, so we have to give it the stage registry to work
# with, and then replace the coordinates so they are valid public ones.
while IFS=$'\t' read -r reg_from reg_to
do
    find catalog -type f | xargs sed -i "s|$reg_from|$reg_to|g"
done < <(yq -e -o tsv ea '.replacements[] | [.from, .to]' "$cfg")

echo "-> Copying generated files" >&2
rm -rf "$catalog_dir/catalog"
cp -r "catalog" "$catalog_dir"

{
    echo ""
    echo "Catalog generated OK!"
} >&2
