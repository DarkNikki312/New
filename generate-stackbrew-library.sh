#!/usr/bin/env bash
set -Eeuo pipefail

declare -A aliases=(
	[5.0]='5 latest'
	[4.2]='4'
)

self="$(basename "$BASH_SOURCE")"
cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( */ )
versions=( "${versions[@]%/}" )

# sort version numbers with highest first
IFS=$'\n'; versions=( $(echo "${versions[*]}" | sort -rV) ); unset IFS

# get the most recent commit which modified any of "$@"
fileCommit() {
	git log -1 --format='format:%H' HEAD -- "$@"
}

# get the most recent commit which modified "$1/Dockerfile" or any file COPY'd from "$1/Dockerfile"
dirCommit() {
	local dir="$1"; shift
	(
		cd "$dir"
		fileCommit \
			Dockerfile \
			$(git show HEAD:./Dockerfile | awk '
				toupper($1) == "COPY" {
					for (i = 2; i < NF; i++) {
						print $i
					}
				}
			')
	)
}

getArches() {
	local repo="$1"; shift
	local officialImagesUrl='https://github.com/docker-library/official-images/raw/master/library/'

	eval "declare -g -A parentRepoToArches=( $(
		find -name 'Dockerfile' -exec awk '
				toupper($1) == "FROM" && $2 !~ /^('"$repo"'|scratch|.*\/.*)(:|$)/ {
					print "'"$officialImagesUrl"'" $2
				}
			' '{}' + \
			| sort -u \
			| xargs bashbrew cat --format '[{{ .RepoName }}:{{ .TagName }}]="{{ join " " .TagEntry.Architectures }}"'
	) )"
}
getArches 'redmine'

cat <<-EOH
# this file is generated via https://github.com/docker-library/redmine/blob/$(fileCommit "$self")/$self

Maintainers: Tianon Gravi <admwiggin@gmail.com> (@tianon),
             Joseph Ferguson <yosifkit@gmail.com> (@yosifkit)
GitRepo: https://github.com/docker-library/redmine.git
EOH

# prints "$2$1$3$1...$N"
join() {
	local sep="$1"; shift
	local out; printf -v out "${sep//%/%%}%s" "$@"
	echo "${out#$sep}"
}

for version in "${versions[@]}"; do
	# normally this would be down in the other loop, but "passenger" doesn't have it, so this is the simplest option (we just can't ever have "alpine" be out of sync, so we should remove it instead if it ever needs to be out of sync)
	commit="$(dirCommit "$version")"
	fullVersion="$(git show "$commit":"$version/Dockerfile" | awk '$1 == "ENV" && $2 == "REDMINE_VERSION" { print $3; exit }')"

	versionAliases=(
		$fullVersion
		$version
		${aliases[$version]:-}
	)

	for variant in '' passenger alpine; do
		dir="$version${variant:+/$variant}"
		[ -f "$dir/Dockerfile" ] || continue

		commit="$(dirCommit "$dir")"

		if [ -n "$variant" ]; then
			variantAliases=( "${versionAliases[@]/%/-$variant}" )
			variantAliases=( "${variantAliases[@]//latest-/}" )
		else
			variantAliases=( "${versionAliases[@]}" )
		fi

		variantParent="$(awk 'toupper($1) == "FROM" { print $2 }' "$dir/Dockerfile")"

		suite="${variantParent#*:}" # "ruby:2.7-slim-bullseye", "2.7-alpine3.15"
		suite="${suite##*-}" # "bullseye", "alpine3.15"
		suite="${suite#alpine}" # "bullseye", "3.15"

		case "$variant" in
			alpine)
				suite="alpine$suite" # "alpine3.8"
				suiteAliases=( "${versionAliases[@]/%/-$suite}" )
				;;
			passenger)
				# the "passenger" variant doesn't get any extra aliases (sorry)
				suiteAliases=()
				;;
			*)
				suiteAliases=( "${variantAliases[@]/%/-$suite}" )
				;;
		esac
		suiteAliases=( "${suiteAliases[@]//latest-/}" )
		variantAliases+=( "${suiteAliases[@]}" )

		case "$variant" in
			passenger) variantArches='amd64' ;; # https://github.com/docker-library/redmine/pull/87#issuecomment-323877678
			*) variantArches="${parentRepoToArches[$variantParent]}" ;;
		esac

		if [ "$variant" != 'alpine' ]; then
			# the "gosu" Debian package isn't available on mips64le
			variantArches="$(sed <<<" $variantArches " -e 's/ mips64le / /g')"
		fi

		echo
		cat <<-EOE
			Tags: $(join ', ' "${variantAliases[@]}")
			Architectures: $(join ', ' $variantArches)
			GitCommit: $commit
			Directory: $dir
		EOE
	done
done
