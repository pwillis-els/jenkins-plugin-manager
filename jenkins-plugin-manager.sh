#!/usr/bin/env sh
# jenkins-plugin-manager.sh - various functions for managing Jenkins plugins

set -eu
[ "${DEBUG:-0}" = "1" ] && set -x # set DEBUG=1 to enable tracing

VERSION="2.9.0"
NAME="jenkins-plugin-manager-$VERSION"
URL="https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/$VERSION/$NAME.jar"
[ -n "${JENKINS_DOCKER_IMG:-}" ] || \
    JENKINS_DOCKER_IMG="jenkins/jenkins"


# Comment this to default to temporary directories for plugin downloads
plugindir="$HOME/.jenkins-plugins.d"

_clean () {
    ret=$?
    if [ -n "${tmpdir:-}" ] ; then rm -rf "$tmpdir" ; fi
    exit $ret
}
trap '_clean' EXIT INT QUIT TSTP USR1

# Run 'jenkins-plugin-manager' Java app locally
_run () {
    if [ $# -gt 0 ] && [ "$1" = "--download" ] ; then
        curl ${CURL_OPTIONS:--sSfL} -o "$NAME.jar" "$URL"
        shift
    fi
    [ $# -gt 0 ] && java -jar "$NAME.jar" "$@"
}

# Run 'jenkins-plugin-manager' from within the official Jenkins docker container
_run_in_jenkins_container () {
    docker run --rm $JENKINS_DOCKER_IMG jenkins-plugin-cli "$@"
}

# Get security warnings from update center
_get_warnings () {
    echo "$0: Downloading https://updates.jenkins.io/update-center.json ..." >&2
    curl ${CURL_OPTIONS:--sSfL} -o - https://updates.jenkins.io/update-center.json | sed -e 's/updateCenter.post(//g; s/);$//' | jq -r '.warnings[] | .name + ":" + .versions[].lastVersion' | sort -Vr
}

# print the base url for a given plugin or core version
_get_baseurl () {
    local plugin_name="$1"
    local url="https://updates.jenkins.io/download/plugins/$plugin_name/"
    [ "$1" = "core" ] && url="https://updates.jenkins.io/download/war/"
    printf "%s\n" "$url"
}

# Retrieve the list of plugin versions
_get_plugin_vers() {
    curl ${CURL_OPTIONS:--sSfL} "$(_get_baseurl "$1")" | sed -e "s/.*href='\([^']\+\)'.*/\1/g" | grep ^/download | rev | cut -d / -f 2 | rev | sort -Vr
}

# Get plugin versions on the command-line
_plugin_versions () {
    local latest=0 last_secure=0 next=0 prev=0 warnings=""

    if [ $# -gt 0 ] ; then
        case "$1" in
            --latest)   latest=1; shift ;;
            --last-secure)
                        last_secure=1;
                        warnings="$(_get_warnings)";
                        shift ;;
            --prev)     prev=1; shift ;;
            --next)     next=1; shift ;;
        esac
    fi 
    [ $# -gt 0 ] || _usage "plugin_versions: please specify a plugin name (from https://updates.jenkins.io/download/plugins/)"

    for plugin in "$@" ; do
        plugin_name="${plugin%%:*}"
        plugin_ver="${plugin#*:}" # warning this becomes 'plugin_name' if ":version" was not included
        plugin_ver="${plugin_ver#* }" # remove "LTS " from plugin_ver

        if [ $last_secure -eq 1 ] ; then
            last_vuln="$(printf "%s\n" "$warnings" | grep -m1 "^$plugin_name:" || true)"
            if [ -z "$last_vuln" ] ; then
                echo "$0: plugin_versions: No known vulnerabilities for plugin '$plugin_name'" >&2
                echo "$plugin"
            else
                last_secure_ver="$(_plugin_versions --next "$last_vuln" | cut -d : -f 2-)"
                # output the user's specified version if it's newer than the last secure version
                if [ $(_version2num "$plugin_ver") -gt $(_version2num "$last_secure_ver") ] ; then
                    echo "$plugin"
                else
                    echo "$plugin_name:$last_secure_ver"
                fi
            fi
            continue
        fi

        plugin_versions="$(_get_plugin_vers "$plugin_name")"
        [ -n "$plugin_versions" ] || _err "plugin_versions: could not find plugin '$plugin_name'"
        # default to latest version
        [ "$(expr index "$plugin" ":")" = "0" ] && plugin_ver="$(printf "%s\n" "$plugin_versions" | head -1)"

        if [ $latest -eq 1 ] ; then
            printf "%s:%s\n" "$plugin_name" "$(printf "%s\n" "$plugin_versions" | head -1)"
        elif [ $prev -eq 1 ] ; then
            printf "%s:%s\n" "$plugin_name" "$(printf "%s\n" "$plugin_versions" | grep -m1 -A1 "$plugin_ver" | tail -1)"
        elif [ $next -eq 1 ] ; then
            printf "%s:%s\n" "$plugin_name" "$(printf "%s\n" "$plugin_versions" | grep -m1 -B1 "$plugin_ver" | head -1)"
        else
            printf "%s\n" "$plugin_versions" | sed -e "s/^/$plugin_name:/g"
        fi
    done
}

# Download plugins
_download_dep () {
    local plugin_name="$1" plugin_ver="$2" plugin_url="$3"
    local plugin_file="$plugindir/$plugin_name:$plugin_ver.hpi"

    [ -d "$plugindir" ] || mkdir -p "$plugindir"

    if [ ! -e "$plugin_file" ] ; then
        echo "$0: Downloading plugin $plugin_url ..." >&2
        curl ${CURL_OPTIONS:--sSfL} --connect-timeout "${CURL_CONNECTION_TIMEOUT:-20}" --retry "${CURL_RETRY:-3}" --retry-delay "${CURL_RETRY_DELAY:-0}" --retry-max-time "${CURL_RETRY_MAX_TIME:-60}" "$plugin_url" -o "$plugin_file"
    fi

    printf "%s\n" "$plugin_file"
}

# Unzip plugin metadata from plugin downloads
_unzip_deps () { unzip -p "$1" META-INF/MANIFEST.MF | tr -d '\r' | tr '\n' '|' | sed -e 's/| //g; s/|/\n/g' | grep ^Plugin-Dependencies: | sed -e 's/^Plugin-Dependencies:[[:space:]]\+//'; }

# Remove the lowest versions for space-separated "name:version" pairs
_remove_dupe () {
    local arg name result="" newlist
    newlist="$(echo "$@" | sed -e 's/ /\n/g' | sort -Vur)"
    for arg in $newlist ; do
        name="${arg%%:*}"
        [ "$(expr match "$result" ".*[[:space:]]$name:")" = "0" ] && \
            result="$result $arg"
    done
    echo "$result" | sed -e 's/^[[:space:]]*//g; s/[[:space:]]*$//g'
}

# Resolve plugin dependencies
_resolve_deps () {
    local nl=0 fix=0
    [ "$1" = "--newlines" ] && nl=1 && shift
    [ "$1" = "--fix" ] && fix=1 && shift

    local found_deps="" parent_deps="" new_deps plugin_deps="" plugin_name plugin_ver plugin_url dep_file dep_name dep_ver dep_opt
    local pinned_deps="$1" already_scanned="$2"
    shift 2

     # Make sure there's a leading space for our expr match later
    expr match "$pinned_deps" "0" >/dev/null || pinned_deps=" $pinned_deps"

    for plugin in "$@" ; do

        # If no version was set, grab the latest
        if [ "$(expr match "$plugin" ".*:")" = "0" ] ; then
            echo "$0: resolve_deps: No version found for plugin '$plugin'; grabbing the latest version" >&2
            plugin="$(_plugin_versions --latest "$plugin")"
        fi

        # Skip a plugin that was already scanned
        [ ! "$(expr match "$already_scanned" ".*[[:space:]]$plugin")" = "0" ] && continue
        plugin_name="${plugin%%:*}"
        plugin_ver="${plugin#*:}" # warning this becomes 'plugin_name' if ":version" was not included
        plugin_ver="${plugin_ver#* }" # remove "LTS " from plugin_ver
        plugin_deps="$plugin_name:$plugin_ver"

        # sample url: https://updates.jenkins-ci.org/download/plugins/active-directory/2.20/active-directory.hpi
        plugin_url="$(_get_baseurl "$plugin_name")""$plugin_ver/$plugin_name.hpi"
        dep_file="$(_download_dep "$plugin_name" "$plugin_ver" "$plugin_url")"
        current_deps="$(_unzip_deps "$dep_file" | sed -e 's/,/\n/g')"

        for dep in $current_deps ; do
            dep_name="${dep%%:*}"
            dep_ver="${dep#*:}"
            dep_opt="${dep_ver#*;}"
            dep_ver="${dep_ver%%;*}" # get rid of ";resolution:=optional"

            # Skip optional dependencies
            [ ! "$(expr match "$dep_opt" '.*resolution:=optional.*')" = "0" ] && continue

            # If the dependency is a pinned dependency, make sure the pinned one is not older
            if [ ! "$(expr match "$pinned_deps" ".*[[:space:]]$dep_name:" )" = "0" ] ; then
                pinned_dep="$(echo "$pinned_deps" | sed -e "s/^.*[[:space:]]\($dep_name:[^[:space:]]\+\)[[:space:]]*.*$/\1/" )"
                pinned_dep_ver="${pinned_dep#*:}"
                if [ $(_version2num "$dep_ver") -gt $(_version2num "$pinned_dep_ver") ] ; then
                    if [ $fix -eq 0 ] ; then
                        _err "resolve_deps: dependency '$dep_name:$dep_ver' is greater than pinned dependency '$pinned_dep'"
                    fi
                fi
            fi

            plugin_deps="$plugin_deps $dep_name:$dep_ver"
        done

        echo "Plugin '$plugin' dependencies: $plugin_deps" >&2
        already_scanned="$already_scanned $plugin"
        parent_deps="$(_remove_dupe $parent_deps $plugin_deps)"

    done

    if [ -n "$parent_deps" ] ; then
        new_deps="$(_resolve_deps "$pinned_deps" "$already_scanned" $parent_deps)"
        found_deps="$(_remove_dupe "$new_deps" "$parent_deps")"
    fi

    if [ $nl -eq 1 ] ; then 
        echo "$found_deps" | sed -e 's/ /\n/g' | sort
    else
        echo "$found_deps"
    fi
}

# Convert a semantic version to an integer
_version2num () { echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }'; }

# Check if a plugin version is vulnerable.
# Note that this function works to find vulnerabilities in Jenkins Core as well.
# The 'name' will be "core", and the version may or may not start with "LTS ".
_is_vulnerable () {
    [ $# -gt 0 ] || _usage "is_vulnerable: please specify a PLUGIN:VERSION"

    local vulnerable_vers="$(_get_warnings)"
    local is_vuln=0

    for plugin in "$@" ; do
        # If we assume no version means "latest", we assume "latest" has no known security vulns
        if [ "$(expr index "$plugin" ":")" = "0" ] ; then
            echo "$0: is_vulnerable: Warning: No version pinned for plugin '$plugin', cannot determine if vulnerable" >&2
            continue
        fi

        plugin_name="${plugin%%:*}"
        plugin_ver="${plugin#*:}"
        plugin_ver="${plugin_ver#* }" # remove "LTS " from plugin_ver

        for vuln in $(echo "$vulnerable_vers" | grep "^$plugin_name:") ; do
            if [ "$(expr index "$vuln" ":")" = "0" ] ; then
                echo "$plugin is vulnerable (all versions are vulnerable! abandon this plugin!!)"
                is_vuln=1
                break
            fi

            vuln_ver="${vuln#*:}"

            if [ $(_version2num "$plugin_ver") -le $(_version2num "$vuln_ver") ] ; then
                echo "$plugin is vulnerable (since version $vuln_ver)"
                is_vuln=1
                break
            fi
        done

    done

    # Exit status is 1 if nothing was vulnerable; 0 if something was
    [ $is_vuln -eq 0 ] && exit 1
}

_err () { echo "Error: $0: $@" >&2 ; exit 1 ; }

_usage () {
    [ $# -gt 0 ] && echo "Error: $0: $@"
    cat <<EOUSAGE
Usage: $0 [OPTIONS] COMMAND [..]

Wrapper for the Jenkins Plugin Installation Manager tool.
Provides some extra features.

Options:
    -f              Force mode (do not die on errors)
    -p DIR          Directory to download plugins to (if needed)
    -h              This screen

Commands:

    run [--download] ARGS [..]
                    Runs 'java -jar plugin-installation-manager-tool.jar ARGS'.
                    If --download is the first argument, the jar file is downloaded.

    run-in-docker [ARGS ..]
                    Runs the plugin installation manager tool from the 'jenkins/jenkins'
                    Docker container. Passes any ARGS you specify.

    plugin-versions PLUGIN [..]
                            Lists all versions of each PLUGIN

    plugin-versions --latest PLUGIN [..]
                            Lists the latest version for PLUGIN

    plugin-versions --last-secure PLUGIN[:VERSION] [..]
                    Lists the oldest version for PLUGIN that has no known security
                    vulnerabilities, or your own VERSION, whichever is newer.
                    If no VERSION was passed and no vulnerability was found, does
                    not return a version.

    plugin-versions --next PLUGIN[:VERSION] [..]
                            Lists the next version of PLUGIN

    plugin-versions --prev PLUGIN[:VERSION] [..]
                            Lists the previous version of PLUGIN

    is-vulnerable PLUGIN:VERSION [..]
                    Returns exit code 0 (success) if VERSION of PLUGIN has a known
                    security vulnerability; otherwise returns exit code 1.
                    Jenkins Core uses "core" as the PLUGIN, and VERSION can be a
                    normal version or prefixed with "LTS ".

    resolve-deps [--fix] PLUGIN[:VERSION] [..]
                    Of a set of PLUGINs, resolves the mandatory dependencies for each
                    PLUGIN and returns them. If VERSION is specified, it is considered
                    'pinned' and no newer one is accepted. Without a VERSION, uses
                    the latest. Uses the global '-p' option. If --fix is specified,
                    will fix any conflicting pinned versions to create an installable
                    plugin list.

For any PLUGIN, you can specify just the plugin name ('git') or you can append a 
version number ('git:1.2.3') which will get stripped off if needed.


Examples:

  Check for security warnings for a plugin:
      $0 run-in-docker --no-download --view-security-warnings --plugins active-directory:2.17

  Get the latest versions of all your plugins:
      $0 plugin-versions --latest \`cat plugins.txt\`

  Download the dependencies for a list of plugins and print them all out:
     $0 -p $HOME/.jenkins-plugins.d resolve-deps \`cat plugins.txt\` > frozen.txt

  Take a frozen plugins.txt and bump any insecure versions to their oldest secure versions.
  Then resolve the resulting dependencies to find any broken pinned items and fix those.
     $0 plugin-versions --last-secure \`cat frozen.txt\` > frozen-secure.txt
     $0 resolve-deps \`cat frozen-secure.txt\` > frozen2.txt

EOUSAGE
    exit 1
}

# Parse command-line options
while getopts "p:fh" args ; do
    case $args in
        h)
                _usage ;;
        f)
                FORCE=1 ;;
        p)
                plugindir="$OPTARG" ;;
        *)
                _usage ;;
    esac
done
shift $(($OPTIND-1))

# Set the plugin download directory
if [ -z "${plugindir:-}" ] ; then
    [ -n "${tmpdir:-}" ] || tmpdir="$(mktemp -d)"
    plugindir="$tmpdir"
fi

[ $# -gt 0 ] || _usage

# Figure out what command to run, run it
cmd="$1"; shift
ret=0
case "$cmd" in 
    run)
                            _run "$@"; ret=$? ;;
    run-in-docker)
                            _run_in_jenkins_container "$@"; ret=$? ;;
    latest-plugin)
                            _find_latest_plugin_ver "$@"; ret=$? ;;
    plugin-versions)
                            _plugin_versions "$@"; ret=$? ;;
    is-vulnerable)
                            _is_vulnerable "$@"; ret=$? ;;
    resolve-deps)
                            if [ "$1" = "--fix" ] ; then
                                shift;
                                _resolve_deps --newlines --fix "$*" "" "$@" ;
                            else
                                _resolve_deps --newlines "$*" "" "$@" ; 
                            fi ; ret=$? ;;
    *)
                            _usage ; ret=$? ;;
esac

exit $ret
