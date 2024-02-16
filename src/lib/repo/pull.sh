#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later

[[ -z ${DEVTOOLS_INCLUDE_REPO_PULL_SH:-} ]] || return 0
DEVTOOLS_INCLUDE_REPO_PULL_SH=1

_DEVTOOLS_LIBRARY_DIR=${_DEVTOOLS_LIBRARY_DIR:-@pkgdatadir@}
# shellcheck source=src/lib/common.sh
source "${_DEVTOOLS_LIBRARY_DIR}"/lib/common.sh
# shellcheck source=src/lib/util/git.sh
source "${_DEVTOOLS_LIBRARY_DIR}"/lib/util/git.sh

source /usr/share/makepkg/util/message.sh

set -e


pkgctl_repo_pull_usage() {
	local -r COMMAND=${_DEVTOOLS_COMMAND:-${BASH_SOURCE[0]##*/}}
	cat <<- _EOF_
		Usage: ${COMMAND} [OPTIONS] [PKGBASE]...

		OPTIONS
		    --discard-changes   Discard changes if index or working tree is dirty
		    -f, --force         An alias for --discard-changes
		    -j, --jobs N        Run up to N jobs in parallel (default: $(nproc))
		    -h, --help          Show this help text

		EXAMPLES
		    $ ${COMMAND} gopass gopass-jsonapi
_EOF_
}

pkgctl_repo_pull() {
	# options
	local paths path pkgbase branch jobs remote
	jobs=$(nproc)
	local command=${_DEVTOOLS_COMMAND:-${BASH_SOURCE[0]##*/}}
	local SHOW_DIFF=0
	local QUIET=0

	while (( $# )); do
		case $1 in
			-h|--help)
				pkgctl_repo_pull_usage
				exit 0
				;;
			-f|--force|--discard-changes)
				GIT_CHECKOUT_OPTIONS+=("--force")
				shift
				;;
			-d|--show-diff)
				SHOW_DIFF=1
				shift
				;;
			--quiet)
				QUIET=1
				shift
				;;
			-j|--jobs)
				(( $# <= 1 )) && die "missing argument for %s" "$1"
				jobs=$2
				shift 2
				;;
			--)
				shift
				break
				;;
			-*)
				die "invalid argument: %s" "$1"
				;;
			*)
				paths=("$@")
				break
				;;
		esac
	done

	# check if invoked without any path from within a packaging repo
	if (( ${#paths[@]} == 0 )); then
		paths=(".")
	fi

	# check if we are only working on one repo and enable
	if (( ${#paths[@]} == 1 )) && (( ! QUIET )); then
		SHOW_DIFF=1
	fi

	# parallelization
	if [[ ${jobs} != 1 ]] && (( ${#paths[@]} > 1 )); then
		if [[ -n ${BOLD} ]]; then
			export DEVTOOLS_COLOR=always
		fi

		# TODO: check if we really need SSH for the given repos
		# warm up ssh connection as it may require user input (key unlock, hostkey verification etc)
		git_warmup_ssh_connection

		# Explicitly set no-show-diff
		if (( ! SHOW_DIFF )); then
			command+=" --quiet"
		fi

		if ! parallel --bar --jobs "${jobs}" "${command}" ::: "${paths[@]}"; then
			die 'Failed to pull some packages, please check the output'
		fi
		exit 0
	fi

	for path in "${paths[@]}"; do
		# skip paths that are not directories
		if [[ ! -d "${path}" ]]; then
			continue
		fi

		if [[ ! -f "${path}/PKGBUILD" ]]; then
			msg_error "  Not a package repository: ${path}"
			continue
		fi

		if [[ ! -d "${path}/.git" ]]; then
			msg_error "  Not a Git repository: ${path}"
			continue
		fi

		pkgbase=$(basename "$(realpath "${path}")")
		pkgbase=${pkgbase%.git}
		msg "Updating ${pkgbase}"

		branch=$(git -C "${path}" symbolic-ref --quiet --short HEAD)
		if [[ ${branch} != main ]]; then
			msg_warn "  Current branch is ${branch}, not updating from canonical upstream: ${pkgbase}"
		fi

		# TODO: allow with --force
		if ! git -C "${path}" diff-files --quiet; then
			msg_error "  Index contains unstaged changes, please stash them before pulling: ${pkgbase}"
			continue
		fi

		# TODO: allow with --force
		if ! git -C "${path}" diff-index --cached --quiet HEAD; then
			msg_error "  Index contains uncommited changes, please commit them before pulling: ${pkgbase}"
			continue
		fi

		remote=$(git -C "${path}" config "branch.${branch}.remote")
		if [[ -z "${remote}" ]]; then
			msg_error "  No upstream tracking branch configured: ${pkgbase}"
			continue
		fi

		if ! git -C "${path}" fetch --quiet "${remote}"; then
			msg_error "  Error while fetching: ${pkgbase}"
			continue
		fi

		if [[ $(git -C "${path}" rev-parse HEAD) == $(git -C "${path}" rev-parse FETCH_HEAD) ]]; then
			msg2 "Repo is up to date, nothing to do"
			continue
		fi

		if (( SHOW_DIFF )) && (( ! QUIET )); then
			git -C "${path}" --no-pager diff --color HEAD..FETCH_HEAD -- ':PKGBUILD'
			git -C "${path}" --no-pager diff --color --stat HEAD..FETCH_HEAD
		fi

		if ! git -C "${path}" rebase --quiet "${remote}/${branch}"; then
			msg_error "  Error while pulling in the changes for ${pkgbase}"
		fi
	done
}
