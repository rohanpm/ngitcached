#!/bin/sh
set -x
set -e

TAG="$1"
if [ "x$TAG" = "x" ]; then
    echo "Usage: release.sh <release-tag>" 1>&2
    exit 2
fi

SHA=$(git rev-parse --verify $TAG)
if [ "x$SHA" = "x" ]; then
    exit 3
fi

for dist in \
    lucid \
    maverick \
    natty \
    oneiric \
    precise \
    quantal \
    ; do
    git reset --hard $SHA
    sed -r -e "1 s/\((.+)\)/(\1~${dist}1)/" -i debian/changelog
    dch -a "git revision $SHA"
    dch --release --distribution $dist ""
    rm -f ../ngitcached*${dist}1*.dsc ../ngitcached*${dist}1*source.changes ../ngitcached*${dist}1*.ppa.upload
    dpkg-buildpackage -S -kAD117A2E
    dput ppa:rohanpm/ngitcached ../ngitcached*${dist}1*source.changes
done
git reset --hard $SHA
