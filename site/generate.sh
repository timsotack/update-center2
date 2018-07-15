#!/bin/bash -ex
# used from ci.jenkins-ci.org to actually generate the production OSS update center

# Used later for rsyncing updates
UPDATES_SITE="updates.jenkins.io"
RSYNC_USER="www-data"

wget -O jq https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64 || { echo "Failed to download jq" >&2 ; exit 1; }
chmod +x jq || { echo "Failed to make jq executable" >&2 ; exit 1; }

set -o pipefail

RELEASES=$( curl 'https://repo.jenkins-ci.org/api/search/versions?g=org.jenkins-ci.main&a=jenkins-core&repos=releases&v=?.*.1' | ./jq --raw-output '.results[].version' | head -n 5 | sort --version-sort ) || { echo "Failed to retrieve list of releases" >&2 ; exit 1 ; }

set +o pipefail

umask

# prepare the www workspace for execution
rm -rf www2 || true
mkdir www2
$( dirname "$0" )/generate-htaccess.sh "${RELEASES[@]}" > www2/.htaccess

mvn -e clean install

function generate() {
    java -jar target/update-center2-*-bin*/update-center2-*.jar \
      -id default \
      -connectionCheckUrl http://www.google.com/ \
      -key $SECRET/update-center.key \
      -certificate $SECRET/update-center.cert \
      "$@"
}

function sanity-check() {
    dir="$1"
    file="$dir/update-center.json"
    if [ 700000 -ge $(wc -c "$file" | cut -f 1 -d ' ') ]; then
        echo $file looks too small
        exit 1
    fi
}

# generate several update centers for different segments
# so that plugins can aggressively update baseline requirements
# without strnding earlier users.
#
# we use LTS as a boundary of different segments, to create
# a reasonable number of segments with reasonable sizes. Plugins
# tend to pick LTS baseline as the required version, so this works well.
#
# Looking at statistics like http://stats.jenkins-ci.org/jenkins-stats/svg/201409-jenkins.svg,
# I think three or four should be sufficient
#
# make sure the latest baseline version here is available as LTS and in the Maven index of the repo,
# otherwise it'll offer the weekly as update to a running LTS version


for ltsv in ${RELEASES[@]}; do
    v="${ltsv/%.1/}"
    # for mainline up to $v, which advertises the latest core
    generate -no-experimental -skip-release-history -skip-plugin-versions -www ./www2/$v -cap $v.999 -capCore 2.999
    sanity-check ./www2/$v
    ln -sf ../updates ./www2/$v/updates

    # for LTS
    generate -no-experimental -skip-release-history -skip-plugin-versions -www ./www2/stable-$v -cap $v.999 -capCore 2.999 -stableCore
    sanity-check ./www2/stable-$v
    ln -sf ../updates ./www2/stable-$v/updates
done


# On generating http://mirrors.jenkins-ci.org/plugins layout
#     this directory that hosts actual bits need to be generated by combining both experimental content and current content,
#     with symlinks pointing to the 'latest' current versions. So we generate exprimental first, then overwrite current to produce proper symlinks

# experimental update center. this is not a part of the version-based redirection rules
generate -skip-release-history -skip-plugin-versions -www ./www2/experimental -download ./download
ln -sf ../updates ./www2/experimental/updates

# for the latest without any cap
# also use this to generae https://updates.jenkins-ci.org/download layout, since this generator run
# will capture every plugin and every core
generate -no-experimental -www ./www2/current -www-download ./www2/download -download ./download -pluginCount.txt ./www2/pluginCount.txt
ln -sf ../updates ./www2/current/updates

# generate symlinks to retain compatibility with past layout and make Apache index useful
pushd www2
    ln -s stable-$lastLTS stable
    for f in latest latestCore.txt plugin-documentation-urls.json release-history.json update-center.*; do
        ln -s current/$f .
    done

    # copy other static resource files
    rsync -avz "../site/static/" ./
popd


# push plugins to mirrors.jenkins-ci.org
chmod -R a+r download
rsync -avz --size-only download/plugins/ ${RSYNC_USER}@${UPDATES_SITE}:/srv/releases/jenkins/plugins

# push generated index to the production servers
# 'updates' come from tool installer generator, so leave that alone, but otherwise
# delete old sites
chmod -R a+r www2
rsync -acvz www2/ --exclude=/updates --delete ${RSYNC_USER}@${UPDATES_SITE}:/var/www/${UPDATES_SITE}
