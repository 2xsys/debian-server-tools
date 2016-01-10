#!/bin/bash
#
# Build a Debian package from a Python package.
#
# VERSION       :0.1.0
# DATE          :2016-01-10
# AUTHOR        :Viktor Szépe <viktor@szepe.net>
# URL           :https://github.com/szepeviktor/debian-server-tools
# LICENSE       :The MIT License (MIT)
# BASH-VERSION  :4.2+
# DEPENDS       :apt-get install fakeroot python-all python3-all python-stdeb python3-stdeb
# DOCS          :https://pypi.python.org/pypi/stdeb
# LOCATION      :/usr/local/bin/py2deb.sh

PACKAGE="$1"

Error() {
    local RET="$1"

    shift
    echo "ERROR: $*" 1>&2
    exit "$RET"
}

if [ -z "$PACKAGE" ]; then
    Error 1 "Needs a package name"
fi

TARBALL="$(python3 /usr/bin/pypi-download "$PACKAGE")"
if [ "${TARBALL:0:4}" != "OK: " ]; then
    Error 2 "Failed to download ${PACKAGE}: ${TARBALL}"
fi

# --no-python2-scripts=true means "exclude /bin scripts from Python2 package"
python3 /usr/bin/py2dsc-deb --with-python2=true --with-python3=true --no-python2-scripts=true \
    --suite $(lsb_release -cs) "${TARBALL:4}"
