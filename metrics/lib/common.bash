#!/bin/bash
#
# Copyright (c) 2017,2018 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0

THIS_FILE=$(readlink -f ${BASH_SOURCE[0]})
LIB_DIR=${THIS_FILE%/*}
RESULT_DIR="${LIB_DIR}/../results"

source ${LIB_DIR}/../../lib/common.bash
source ${LIB_DIR}/json.bash

# Set variables to reasonable defaults if unset or empty
DOCKER_EXE="${DOCKER_EXE:-docker}"
RUNTIME="${RUNTIME:-kata-runtime}"

KSM_BASE="/sys/kernel/mm/ksm"
KSM_ENABLE_FILE="${KSM_BASE}/run"
KSM_PAGES_FILE="${KSM_BASE}/pages_to_scan"
KSM_SLEEP_FILE="${KSM_BASE}/sleep_millisecs"

# The settings we use for an 'aggresive' KSM setup
# Scan 1000 pages every 50ms - 20,000 pages/s
KSM_AGGRESIVE_PAGES=1000
KSM_AGGRESIVE_SLEEP=50

# If we fail for any reason, exit through here and we should log that to the correct
# place and return the correct code to halt the run
die(){
	msg="$*"
	echo "ERROR: $msg" >&2
	exit 1
}

# Sometimes we just want to warn about something - let's have a standard
# method for that, so maybe we can make a standard form that can be searched
# for in the logs/tooling
warning(){
	msg="$*"
	echo "WARNING: $msg" >&2
}

# This function checks existence of commands.
# They can be received standalone or as an array, e.g.
#
# cmds=(“cmd1” “cmd2”)
# check_cmds "${cmds[@]}"
check_cmds()
{
	local cmd req_cmds=( "$@" )
	for cmd in "${req_cmds[@]}"; do
		if ! command -v "$cmd" > /dev/null 2>&1; then
			die "command $cmd not available"
			exit 1;
		fi
		echo "command: $cmd: yes"
	done
}

# This function performs a docker pull on the image names
# passed in (notionally as 'about to be used'), to ensure
#  - that we have the most upto date images
#  - that any pull/refresh time (for a first pull) does not
#    happen during the test itself.
#
# The image list can be received standalone or as an array, e.g.
#
# images=(“img1” “img2”)
# check_imgs "${images[@]}"
check_images()
{
	local img req_images=( "$@" )
	for img in "${req_images[@]}"; do
		echo "docker pull'ing: $img"
		if ! docker pull "$img"; then
			die "Failed to docker pull image $img"
			exit 1;
		fi
		echo "docker pull'd: $img"
	done
}

# This function performs a docker build on the image names
# passed in, to ensure that we have the latest changes from
# the dockerfiles
build_dockerfile_image()
{
	local image="$1"
	local dockerfile_path="$2"
	local dockerfile_dir=${2%/*}

	echo "docker building $image"
	if ! docker build --label "$image" --tag "${image}" -f "$dockerfile_path" "$dockerfile_dir"; then
		die "Failed to docker build image $image"
	fi
}

# This function verifies that the dockerfile version is
# equal to the test version in order to build the image or
# just run the test
check_dockerfiles_images()
{
	local image="$1"
	local dockerfile_path="$2"

	if [ -z "$image" ] || [ -z "$dockerfile_path" ]; then
		die "Missing image or dockerfile path variable"
	fi

	# Verify that dockerfile version is equal to test version
	check_image=$(docker images "$image" -q)
	if [ -n "$check_image" ]; then
		# Check image label
		check_image_version=$(docker image inspect $image | grep -w DOCKERFILE_VERSION | head -1 | cut -d '"' -f4)
		if [ -n "$check_image_version" ]; then
			echo "$image is not updated"
			build_dockerfile_image "$image" "$dockerfile_path"
		else
			# Check dockerfile label
			dockerfile_version=$(grep DOCKERFILE_VERSION $dockerfile_path | cut -d '"' -f2)
			if [ "$dockerfile_version" != "$check_image_version" ]; then
				echo "$dockerfile_version is not equal to $check_image_version"
				build_dockerfile_image "$image" "$dockerfile_path"
			fi
		fi
	else
		build_dockerfile_image "$image" "$dockerfile_path"
	fi
}

# A one time (per uber test cycle) init that tries to get the
# system to a 'known state' as much as possible
metrics_onetime_init()
{
	# The onetime init must be called once, and only once
	if [ ! -z "$onetime_init_done" ]; then
		die "onetime_init() called more than once"
	fi

	# Restart services
	sudo systemctl restart docker

	# We want this to be seen in sub shells as well...
	# otherwise init_env() cannot check us
	export onetime_init_done=1
}

# Print a banner to the logs noting clearly which test
# we are about to run
test_banner()
{
	echo -e "\n===== starting test [$1] ====="
}

# Initialization/verification environment. This function makes
# minimal steps for metrics/tests execution.
init_env()
{
	test_banner "${TEST_NAME}"

	cmd=("docker")

	# check dependencies
	check_cmds "${cmd[@]}"

	# Remove all stopped containers
	clean_env

	# This clean up is more aggressive, this is in order to
	# decrease the factors that could affect the metrics results.
	kill_processes_before_start
}

# This function checks if there are containers or
# shim/proxy/hypervisor processes up, if found, they are
# killed to start test with clean environment.
kill_processes_before_start() {
	DOCKER_PROCS=$(${DOCKER_EXE} ps -q)
	[[ -n "${DOCKER_PROCS}" ]] && clean_env
	check_processes
}

# Generate a random name - generally used when creating containers, but can
# be used for any other appropriate purpose
random_name() {
	mktemp -u kata-XXXXXX
}

# Dump diagnostics about our current system state.
# Very useful for diagnosing if we have failed a sanity check
show_system_state() {
	echo "Showing system state:"
	echo " --Docker ps--"
	${DOCKER_EXE} ps -a
	echo " --${RUNTIME} list--"
	local RPATH=$(command -v ${RUNTIME})
	sudo ${RPATH} list

	local processes="kata-proxy kata-shim kata-runtime qemu ksm-throttler"

	for p in ${processes}; do
		echo " --pgrep ${p}--"
		pgrep -a ${p}
	done
}

common_init(){
	case "$RUNTIME" in
		kata-runtime)
			extract_kata_env
			;;
		*)
			warning "Unrecognised runtime ${RUNTIME}"
			;;
	esac
}


# Save the current KSM settings so we can restore them later
save_ksm_settings(){
	echo "saving KSM settings"
	ksm_stored_run=$(cat ${KSM_ENABLE_FILE})
	ksm_stored_pages=$(cat ${KSM_ENABLE_FILE})
	ksm_stored_sleep=$(cat ${KSM_ENABLE_FILE})
}

set_ksm_aggressive(){
	echo "setting KSM to aggressive mode"
	# Flip the run off/on to ensure a restart/rescan
	sudo bash -c "echo 0 > ${KSM_ENABLE_FILE}"
	sudo bash -c "echo ${KSM_AGGRESIVE_PAGES} > ${KSM_PAGES_FILE}"
	sudo bash -c "echo ${KSM_AGGRESIVE_SLEEP} > ${KSM_SLEEP_FILE}"
	sudo bash -c "echo 1 > ${KSM_ENABLE_FILE}"
}

restore_ksm_settings(){
	echo "restoring KSM settings"
	# First turn off the run to ensure if we are then re-enabling
	# that any changes take effect
	sudo bash -c "echo 0 > ${KSM_ENABLE_FILE}"
	sudo bash -c "echo ${ksm_stored_pages} > ${KSM_PAGES_FILE}"
	sudo bash -c "echo ${ksm_stored_sleep} > ${KSM_SLEEP_FILE}"
	sudo bash -c "echo ${ksm_stored_run} > ${KSM_ENABLE_FILE}"
}

disable_ksm(){
	echo "disabling KSM"
	sudo bash -c "echo 0 > ${KSM_ENABLE_FILE}"
}

common_init
