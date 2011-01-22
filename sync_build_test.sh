#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to sync your checkout, build a Chromium OS image, and test it all
# with one command.  Can also check out a new Chromium OS checkout and
# perform a subset of the above operations.
#
# Here are some example runs:
#
# sync_build_test.sh
#   syncs, recreates local repo and chroot, builds, and masters an
#   image in the checkout based on your current directory, or if you
#   are not in a checkout, based on the top level directory the script
#   is run from.
#
# sync_build_test.sh --image_to_usb=/dev/sdb -i
#   same as above but then images USB device /dev/sdb with the image.
#   Also prompt the user in advance of the steps we'll take to make
#   sure they agrees.
#
# sync_build_test.sh --top=~/foo --nosync --remote 192.168.1.2
#   builds and masters an image in ~/foo, and live updates the machine
#   at 192.168.1.2 with that image.
#
# sync_build_test.sh --top=~/newdir --test "Pam BootPerfServer" \
#      --remote=192.168.1.2
#   creates a new checkout in ~/newdir, builds and masters an image
#   which is live updated to 192.168.1.2 and then runs
#   two tests (Pam and BootPerfServer) against that machine.
#
# sync_build_test.sh --grab_buildbot=LATEST --test Pam --remote=192.168.1.2
#   grabs the latest build from the buildbot, properly modifies it,
#   reimages 192.168.1.2, and runs the given test on it.
#
# Environment variables that may be useful:
#   BUILDBOT_URI - default value for --buildbot_uri
#   CHROMIUM_REPO - default value for --repo
#   CHRONOS_PASSWD - default value for --chronos_passwd
#

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"
# Allow remote access (for learning board type)
. "$(dirname "$0")/remote_access.sh"

DEFINE_string board "" "Board setting"
DEFINE_boolean build ${FLAGS_TRUE} \
    "Build all code (but not necessarily master image)"
DEFINE_boolean build_autotest ${FLAGS_FALSE} "Build autotest"
DEFINE_string buildbot_uri "${BUILDBOT_URI}" \
    "Base URI to buildbot build location which contains LATEST file"
DEFINE_string chrome_gold ${FLAGS_TRUE} \
    "Build Chrome using gold if it is installed and supported."
DEFINE_string chrome_root "" \
    "The root of your chrome browser source. Should contain a 'src' subdir. \
If this is set, chrome browser will be built from source."
DEFINE_string chronos_passwd "${CHRONOS_PASSWD}" \
    "Use this as the chronos user passwd (defaults to \$CHRONOS_PASSWD)"
DEFINE_string chroot "" "Chroot to build/use"
DEFINE_boolean enable_rootfs_verification ${FLAGS_FALSE} \
    "Enable rootfs verification when building image"
DEFINE_boolean force_make_chroot ${FLAGS_FALSE} "Run make_chroot indep of sync"
DEFINE_string grab_buildbot "" \
    "Instead of building, grab this full image.zip URI generated by the \
buildbot"
DEFINE_boolean ignore_remote_test_failures ${FLAGS_FALSE} \
    "Ignore any remote tests that failed and don't return failure"
DEFINE_boolean image_to_live ${FLAGS_FALSE} \
    "Put the resulting image on live instance (requires --remote)"
DEFINE_boolean image_to_vm ${FLAGS_FALSE} "Create a VM image"
DEFINE_string image_to_usb "" \
    "Treat this device as USB and put the image on it after build"
# You can set jobs > 1 but then your build may break and you may need
# to retry.  Setting it to 1 is best for non-interactive sessions.
DEFINE_integer jobs -1 "Concurrent build jobs"
DEFINE_boolean master ${FLAGS_TRUE} "Master an image from built code"
DEFINE_boolean minilayout ${FLAGS_FALSE} "Use minimal code checkout"
DEFINE_boolean mod_image_for_test ${FLAGS_FALSE} "Modify the image for testing"
DEFINE_boolean official ${FLAGS_FALSE} "Sync/Build/Test official Chrome OS"
DEFINE_boolean oldchromebinary ${FLAGS_TRUE} "Always use chrome binary package"
DEFINE_string repo "${CHROMIUMOS_REPO}" "gclient repo for chromiumos"
DEFINE_boolean sync ${FLAGS_TRUE} "Sync the checkout"
DEFINE_string test "" \
    "Test the built image with the given params to run_remote_tests"
DEFINE_string top "" \
    "Root directory of your checkout (defaults to determining from your cwd)"
DEFINE_string vm_options "--no_graphics" "VM options"
DEFINE_boolean withdev ${FLAGS_TRUE} "Build development packages"
DEFINE_boolean usepkg ${FLAGS_TRUE} "Use binary packages"
DEFINE_boolean unittest ${FLAGS_TRUE} "Run unit tests"
DEFINE_boolean yes ${FLAGS_FALSE} "Reply yes to all prompts" y

# Returns a heuristic indicating if we believe this to be a google internal
# development environment.
# Returns:
#   0 if so, 1 otherwise
function is_google_environment() {
  hostname | egrep -q .google.com\$
  return $?
}


# Validates parameters and sets "intelligent" defaults based on other
# parameters.
function validate_and_set_param_defaults() {
  TMP=$(mktemp -d "/tmp/sync_build_test.XXXX")

  if [[ -z "${FLAGS_top}" ]]; then
    local test_dir=$(pwd)
    while [[ "${test_dir}" != "/" ]]; do
      if [[ -d "${test_dir}/src/platform/dev" ]]; then
        FLAGS_top="${test_dir}"
        break
      fi
      test_dir=$(dirname "${test_dir}")
    done
  fi

  if [[ -z "${FLAGS_top}" ]]; then
    # Use the top directory based on where this script runs from
    FLAGS_top=$(dirname $(dirname $(dirname $0)))
  fi

  # Canonicalize any symlinks
  if [[ -d "${FLAGS_top}" ]]; then
    FLAGS_top=$(readlink -f "${FLAGS_top}")
  fi

  if [[ -z "${FLAGS_chroot}" ]]; then
    FLAGS_chroot="${FLAGS_top}/chroot"
  fi

  # If chroot does not exist, force making it
  if [[ ! -d "${FLAGS_chroot}" ]]; then
    FLAGS_force_make_chroot=${FLAGS_TRUE}
  fi
  # If chrome_root option passed, set as option for ./enter_chroot
  if [[ -n "${FLAGS_chrome_root}" ]]; then
    chroot_options="--chrome_root=${FLAGS_chrome_root}"
  fi

  if [[ -n "${FLAGS_test}" ]]; then
    # If you specify that tests should be run, we assume the image
    # is modified to run tests.
    FLAGS_mod_image_for_test=${FLAGS_TRUE}
    if [[ -n "${FLAGS_remote}" ]]; then
      # If you specify that tests should be run, we assume you want
      # to live update the image.
      FLAGS_image_to_live=${FLAGS_TRUE}
    else
      # Otherwise we assume you want to run the VM tests.
      FLAGS_image_to_vm=${FLAGS_TRUE}
    fi
  fi

  # If they gave us a remote host, then we assume they want us to do a live
  # update.
  if [[ -n "${FLAGS_remote}" ]]; then
    FLAGS_image_to_live=${FLAGS_TRUE}
    remote_access_init
  fi

  # Figure out board.
  if [[ -z "${FLAGS_board}" ]]; then
    if [[ -n "${FLAGS_remote}" ]]; then
      learn_board
    else
      get_default_board
      [[ -z "${DEFAULT_BOARD}" ]] && DEFAULT_BOARD="x86-generic"
      FLAGS_board="${DEFAULT_BOARD}"
    fi
  fi

  if [[ ${FLAGS_build} -eq ${FLAGS_TRUE} ]]; then
    if [[ -n "${FLAGS_chrome_root}" ]]; then
      if [ ! -d "${FLAGS_chrome_root}" ]; then
        die "Cannot find ${FLAGS_chrome_root} (tildes not expanded)"
      fi
      if [ ! -d "${FLAGS_chrome_root}/src/third_party/cros" ]; then
        die "You need to add .gclient lines for Chrome on Chrome OS"
      fi
    fi
  fi

  # Grabbing a buildbot build is exclusive with syncing and building
  if [[ -n "${FLAGS_grab_buildbot}" ]]; then
    if [[ "${FLAGS_grab_buildbot}" == "LATEST" ]]; then
      if [[ -z "${FLAGS_buildbot_uri}" ]]; then
        die "--grab_buildbot=LATEST requires --buildbot_uri or setting \
BUILDBOT_URI"
        exit 1
      fi
    fi
    FLAGS_sync=${FLAGS_FALSE}
    FLAGS_build=${FLAGS_FALSE}
    FLAGS_unittest=${FLAGS_FALSE}
    FLAGS_master=${FLAGS_FALSE}
  fi

  if [[ ${FLAGS_image_to_live} -eq ${FLAGS_TRUE} ]]; then
    if [[ ${FLAGS_mod_image_for_test} -eq ${FLAGS_FALSE} ]]; then
      warn "You have specified to live reimage a machine with"
      warn "an image that is not modified for test (so it cannot be"
      warn "later live reimaged)"
    fi
    if [[ -n "${FLAGS_image_to_usb}" ]]; then
      warn "You have specified to both live reimage a machine and"
      warn "write a USB image.  Is this what you wanted?"
    fi
    if [[ -z "${FLAGS_remote}" ]]; then
      die "Please specify --remote with --image_to_live"
    fi
  fi

  if [[ ${FLAGS_mod_image_for_test} -eq ${FLAGS_TRUE} ]]; then
    # Override any specified chronos password with the test one
    FLAGS_chronos_passwd="test0000"
    # If you're modding for test, you also want developer packages.
    FLAGS_withdev=${FLAGS_TRUE}
  fi

  if [[ -n "${FLAGS_image_to_usb}" ]]; then
    local device=${FLAGS_image_to_usb#/dev/}
    if [[ -z "${device}" ]]; then
      die "Expected --image_to_usb option of /dev/* format"
    fi
    local is_removable=$(cat /sys/block/${device}/removable)
    if [[ "${is_removable}" != "1" ]]; then
      die "Could not verify that ${device} for image_to_usb is removable"
    fi
  fi
}

function has_board_directory() {
  [[ -d "${FLAGS_top}/chroot/build/${FLAGS_board}" ]]
}

# Prints a description of what we are doing or did
function describe_steps() {
  if [[ ${FLAGS_sync} -eq ${FLAGS_TRUE} ]]; then
    local is_official=""
    [ ${FLAGS_official} -eq ${FLAGS_TRUE} ] && is_official=" (official)"
    info " * Sync client (repo sync)${is_official} (disable using --nosync)"
  fi
  if [[ ${FLAGS_force_make_chroot} -eq ${FLAGS_TRUE} ]]; then
    info " * Rebuild chroot (make_chroot) in ${FLAGS_chroot}"
  fi
  local set_passwd=${FLAGS_FALSE}
  if ! has_board_directory; then
    info " * Setup new board ${FLAGS_board} (setup_board)"
  fi
  if [[ ${FLAGS_build} -eq ${FLAGS_TRUE} ]]; then
    local extra_build=""
    if [[ ${FLAGS_withdev} -eq ${FLAGS_TRUE} ]]; then
      extra_build=" with dev packages"
    fi
    if [[ ${FLAGS_oldchromebinary} -eq ${FLAGS_TRUE} ]]; then
      extra_build=" (but pull Chrome binary)"
    fi
    info " * Build packages${extra_build} (build_packages) \
(disable using --nobuild)"
    set_passwd=${FLAGS_TRUE}
    if [[ ${FLAGS_build_autotest} -eq ${FLAGS_TRUE} ]]; then
      info " * Cross-build autotest client tests (build_autotest)"
    fi
    if [[ -n "${FLAGS_chrome_root}" ]]; then
      info " * After Chrome builds in build_packages, building Chrome from \
sources at ${FLAGS_chrome_root}"
    fi
  fi
  if [[ ${FLAGS_master} -eq ${FLAGS_TRUE} ]]; then
    info " * Master image (build_image) (disable using --nomaster)"
  fi
  if [[ -n "${FLAGS_grab_buildbot}" ]]; then
    if [[ "${FLAGS_grab_buildbot}" == "LATEST" ]]; then
      info " * Grab latest buildbot image under ${FLAGS_buildbot_uri}"
    else
      info " * Grab buildbot image zip at URI ${FLAGS_grab_buildbot}"
    fi
  fi
  if [[ ${FLAGS_unittest} -eq ${FLAGS_TRUE} ]]; then
    info " * Run cros_run_unit_tests to run all unit tests \
(disable using --nounittest)"
  fi
  if [[ ${FLAGS_mod_image_for_test} -eq ${FLAGS_TRUE} ]]; then
    if [[ -n "${FLAGS_grab_buildbot}" ]]; then
      info " * Use the prebuilt image modded for test (rootfs_test.image)"
      info " * Install prebuilt cross-compiled autotests in chroot"
    else
      info " * Make image able to run tests (mod_image_for_test)"
    fi
    set_passwd=${FLAGS_TRUE}
  else
    info " * Not modifying image for test (enable using --mod_image_for_test)"
  fi
  if [[ ${set_passwd} -eq ${FLAGS_TRUE} ]]; then
    if [[ -n "${FLAGS_chronos_passwd}" ]]; then
      info " * Set chronos password to ${FLAGS_chronos_passwd}"
    else
      info " * Set chronos password randomly"
    fi
  fi
  if [[ -n "${FLAGS_image_to_usb}" ]]; then
    info " * Write the image to USB device ${FLAGS_image_to_usb}"
  fi
  if [[ ${FLAGS_image_to_live} -eq ${FLAGS_TRUE} ]]; then
    info " * Reimage live test Chromium OS instance at ${FLAGS_remote}"
  fi
  if [[ ${FLAGS_image_to_vm} -eq ${FLAGS_TRUE} ]]; then
    info " * Copy off a separate VM image"
  fi
  if [[ -n "${FLAGS_test}" ]]; then
    if [[ -n "${FLAGS_remote}" ]]; then
      info " * Run (and build) tests (${FLAGS_test}) on machine at \
${FLAGS_remote}"
    else
      info " * Start a VM locally and run (and build) tests (${FLAGS_test}) \
on it"
    fi
  else
    info " * Not running any autotests (pass --test=suite_Smoke for instance \
to change)"
  fi
}

# Prompt user Y/N to continue
function prompt_to_continue() {
  if [ ${FLAGS_yes} -eq ${FLAGS_TRUE} ]; then
    info "Continuing without prompting since you passed --yes"
    return
  fi
  echo ""
  read -p "Are you sure (y/N)? " SURE
  echo "(Pass -y to skip this prompt)"
  echo ""
  # Get just the first character
  if [[ "${SURE:0:1}" != "y" ]]; then
    die "Ok, better safe than sorry."
  fi
}

# Get user's permission on steps to take
function interactive() {
  echo ""
  info "Planning these steps on ${FLAGS_top} for ${FLAGS_board}:"
  describe_steps
  prompt_to_continue
}

# Changes to a directory relative to the top/root directory of
# the checkout.
# Arguments:
#   $1 - relative path
function chdir_relative() {
  local dir=$1
  info "Running: cd ${dir}"
  # Allow use of .. before the innermost directory of FLAGS_top exists
  if [[ "${dir}" == ".." ]]; then
    dir=$(dirname "${FLAGS_top}")
  else
    dir="${FLAGS_top}/${dir}"
  fi
  cd "${dir}"
}


function info_div {
  info "#############################################################"
}

# Describe to the user that a phase is running (and make it obviously when
# scrolling through lots of output).
# Arguments:
#   $1 - phase description
function describe_phase() {
  local desc="$1"
  echo ""
  info_div
  info "${desc}"
}

function cleanup() {
  [ -n "${TMP}" ] && rm -rf "${TMP}"
  cleanup_remote_access
}

# Called when there is a failure and we exit early
function failure() {
  trap - EXIT
  # Clear these out just in case.
  export GSDCURL_USERNAME=""
  export GSDCURL_PASSWORD=""
  describe_phase "Failure during: ${LAST_PHASE}"
  show_duration
  info_div
  cleanup
}


# Runs a phase, describing it first, and also updates the sudo timeout
# afterwards.
# Arguments:
#   $1 - phase description
#   $2.. - command/params to run
function run_phase() {
  local desc="$1"
  shift
  LAST_PHASE="${desc}"
  describe_phase "${desc}"
  local line="Running: "
  line+=$@
  info "${line}"
  info_div
  echo ""
  "$@"
  sudo true
}


# Runs a phase, similar to run_phase, but runs within the chroot.
# Arguments:
#   $1 - phase description
#   $2.. - command/params to run in chroot
function run_phase_in_chroot() {
  local desc="$1"
  shift
  run_phase "${desc}" ./enter_chroot.sh "--chroot=${FLAGS_chroot}" \
    ${chroot_options} -- "$@"
}


# Record start time.
function set_start_time() {
  START_TIME=$(date '+%s')
}


# Display duration
function show_duration() {
  local current_time=$(date '+%s')
  local duration=$((${current_time} - ${START_TIME}))
  local minutes_duration=$((${duration} / 60))
  local seconds_duration=$((${duration} % 60))
  info "$(printf "Total time: %d:%02ds\n" "${minutes_duration}" \
                 "${seconds_duration}")"
}

# Runs repo init on a new checkout directory.
function config_new_repo_checkout() {
  mkdir -p "${FLAGS_top}"
  cd "${FLAGS_top}"
  local minilayout=""
  [ ${FLAGS_minilayout} -eq ${FLAGS_TRUE} ] && minilayout="-m minilayout.xml"
  local git_uri="http://git.chromium.org/git/manifest"
  if [ ${FLAGS_official} -eq ${FLAGS_TRUE} ]; then
    git_uri="ssh://git@gitrw.chromium.org:9222/manifest-internal"
  fi
  repo init -u "${git_uri}" ${minilayout}
}

# Configures/initializes a new checkout
function config_new_checkout() {
  info "Checking out ${FLAGS_top}"
  config_new_repo_checkout
}

# Runs gclient sync, setting up .chromeos_dev and preparing for
# local repo setup
function sync() {
  # cd to the directory below
  chdir_relative .
  run_phase "Synchronizing client" repo sync
  # Change to a directory that is definitely a git repo
  chdir_relative src/third_party/chromiumos-overlay
  git cl config "file://$(pwd)/../../../codereview.settings"
  chdir_relative .
}


# Downloads a buildbot image
function grab_buildbot() {
  read -p "Username [${LOGNAME}]: " GSDCURL_USERNAME
  export GSDCURL_USERNAME
  read -s -p "Password: " GSDCURL_PASSWORD
  export GSDCURL_PASSWORD
  CURL="$(dirname $0)/bin/cros_gsdcurl.py"
  if [[ "${FLAGS_grab_buildbot}" == "LATEST" ]]; then
    local latest=$(${CURL} "${FLAGS_buildbot_uri}/LATEST")
    if [[ -z "${latest}" ]]; then
      die "Error finding latest."
    fi
    FLAGS_grab_buildbot="${FLAGS_buildbot_uri}/${latest}/image.zip"
  fi
  local dl_dir="${TMP}/image"
  mkdir -p "${dl_dir}"

  info "Grabbing image from ${FLAGS_grab_buildbot} to ${dl_dir}"
  run_phase "Downloading image" ${CURL} "${FLAGS_grab_buildbot}" \
    -o "${dl_dir}/image.zip"
  # Clear out the credentials so they can't be used later.
  export GSDCURL_USERNAME=""
  export GSDCURL_PASSWORD=""

  cd "${dl_dir}"
  unzip image.zip
  local image_basename=$(basename $(dirname "${FLAGS_grab_buildbot}"))
  local image_base_dir="${FLAGS_top}/src/build/images/${FLAGS_board}"
  local image_dir="${image_base_dir}/${image_basename}"
  info "Copying in build image to ${image_dir}"
  rm -rf "${image_dir}"
  mkdir -p "${image_dir}"
  if [[ ${FLAGS_mod_image_for_test} -eq ${FLAGS_TRUE} ]]; then
    run_phase "Installing buildbot test modified image" \
      mv chromiumos_test_image.bin "${image_dir}/chromiumos_image.bin"
    FLAGS_mod_image_for_test=${FLAGS_FALSE}
  else
    run_phase "Installing buildbot base image" \
    mv chromiumos_base_image.bin "${image_dir}/chromiumos_image.bin"
  fi

  if [[ -n "${FLAGS_test}" ]]; then
    if [[ ! -d "${FLAGS_top}/chroot/build/${FLAGS_board}" ]]; then
      die "To run tests on a buildbot image, run setup_board first."
    fi
    if [[ -e "autotest.tgz" || -e "autotest.tar.bz2" ]]; then
      # pull in autotest
      local dir="${FLAGS_chroot}/build/${FLAGS_board}/usr/local"
      local tar_args="xzf"
      local tar_name="${dl_dir}/autotest.tgz"
      if [[ -e "autotest.tar.bz2" ]]; then
        tar_args="xjf"
        tar_name="${dl_dir}/autotest.tar.bz2"
      fi
      sudo rm -rf "${dir}/autotest"
      # Expand in temp directory as current user, then move it as
      # root to keep local user ownership
      run_phase "Unpacking buildbot autotest cross-compiled binaries" \
        tar ${tar_args} "${tar_name}"
      run_phase "Installing buildbot autotest cross-compiled binaries" \
        sudo mv autotest ${dir}
    fi
  fi
  chdir_relative .
  run_phase "Removing downloaded image" rm -rf "${dl_dir}"
}


function main() {
  assert_outside_chroot
  assert_not_root_user

  # Parse command line
  FLAGS "$@" || exit 1
  eval set -- "${FLAGS_ARGV}"

  # Die on any errors.
  set -e

  validate_and_set_param_defaults

  # Cache up sudo status
  sudo true

  interactive

  set_start_time
  trap failure EXIT

  local withdev_param=""
  if [[ ${FLAGS_withdev} -eq ${FLAGS_TRUE} ]]; then
    withdev_param="--withdev"
  fi

  local jobs_param=""
  if [[ ${FLAGS_jobs} -gt 1 ]]; then
    jobs_param="--jobs=${FLAGS_jobs}"
  fi

  local board_param="--board=${FLAGS_board}"

  if [[ ! -e "${FLAGS_top}" ]]; then
    config_new_checkout
  fi

  if [[ ${FLAGS_sync} -eq ${FLAGS_TRUE} ]]; then
    sync
  fi

  if [[ -n "${FLAGS_grab_buildbot}" ]]; then
    grab_buildbot
  fi

  if [[ ${FLAGS_force_make_chroot} -eq ${FLAGS_TRUE} ]]; then
    chdir_relative src/scripts
    run_phase "Replacing chroot" ./make_chroot --replace \
        "--chroot=${FLAGS_chroot}" ${jobs_param}
  fi

  if [[ ${FLAGS_build} -eq ${FLAGS_TRUE} ]]; then
    # It's necessary to enable localaccount for BVT tests to pass.
    chdir_relative src/scripts
    run_phase "Enable local account" \
        ./enable_localaccount.sh chronos "${FLAGS_chroot}"

    local pkg_param=""
    if [[ ${FLAGS_usepkg} -eq ${FLAGS_FALSE} ]]; then
      pkg_param="--nousepkg"
    fi

    chdir_relative src/scripts
    # Only setup board target if the directory does not exist
    if ! has_board_directory; then
      run_phase_in_chroot "Setting up board target" \
          ./setup_board ${pkg_param} "${board_param}"
    fi
    local build_autotest_param=""
    if [[ ${FLAGS_build_autotest} -eq ${FLAGS_TRUE} ]]; then
      build_autotest_param="--withautotest"
    fi
    if [[ ${FLAGS_oldchromebinary} -eq ${FLAGS_TRUE} ]]; then
      pkg_param="${pkg_param} --oldchromebinary"
    fi

    run_phase_in_chroot "Building packages" \
        ./build_packages "${board_param}" \
        ${withdev_param} ${build_autotest_param} \
        ${pkg_param}
  fi

  if [[ ${FLAGS_chrome_root} ]]; then
    chdir_relative src/scripts
    # You can always pass USE=gold, the ebuild will only really use
    # gold if x86 and the binaries are found.
    local chrome_use=""
    if [ ${FLAGS_chrome_gold} -eq ${FLAGS_TRUE} ]; then
      chrome_use="${chrome_use} gold"
    fi
    if [ ${FLAGS_official} -eq ${FLAGS_TRUE} ]; then
      chrome_use="${chrome_use} internal"
    fi
    [ -z "${FLAGS_test}" ] && chrome_use="${chrome_use} -build_tests"
    run_phase_in_chroot "Building Chromium browser" env \
      BOARD="${FLAGS_board}" USE="${chrome_use}" FEATURES="-usersandbox" \
      CHROME_ORIGIN=LOCAL_SOURCE emerge-${FLAGS_board} chromeos-chrome
  fi

  if [[ ${FLAGS_unittest} -eq ${FLAGS_TRUE} ]] && \
     [[ "${FLAGS_board}" == "x86-generic" ]] ; then
    chdir_relative src/scripts
    run_phase_in_chroot "Running unit tests" ./cros_run_unit_tests \
      ${board_param}
  fi

  if [[ ${FLAGS_master} -eq ${FLAGS_TRUE} ]]; then
    chdir_relative src/scripts
    if [[ -n "${FLAGS_chronos_passwd}" ]]; then
      run_phase_in_chroot "Setting default chronos password" \
          sh -c "echo '${FLAGS_chronos_passwd}' | \
          ~/trunk/src/scripts/set_shared_user_password.sh"
    fi
    local other_params="--enable_rootfs_verification"
    if [[ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_FALSE} ]]; then
      other_params="--noenable_rootfs_verification"
    fi
    run_phase_in_chroot "Mastering image" ./build_image \
        "${board_param}" --replace ${withdev_param} \
        ${jobs_param} ${other_params}
  fi

  if [[ ${FLAGS_mod_image_for_test} -eq ${FLAGS_TRUE} ]]; then
    chdir_relative src/scripts
    run_phase_in_chroot "Modifying image for test" \
        "./mod_image_for_test.sh" "${board_param}" --yes
  fi

  if [[ -n "${FLAGS_image_to_usb}" ]]; then
    chdir_relative src/scripts
    run_phase "Installing image to USB" \
        ./image_to_usb.sh --yes "--to=${FLAGS_image_to_usb}" "${board_param}"
  fi

  if [[ ${FLAGS_image_to_live} -eq ${FLAGS_TRUE} ]]; then
    chdir_relative src/scripts
    run_phase "Re-imaging live Chromium OS machine ${FLAGS_remote}" \
      ./image_to_live.sh "--remote=${FLAGS_remote}" --update_known_hosts
  fi

  if [[ ${FLAGS_image_to_vm} -eq ${FLAGS_TRUE} ]]; then
    chdir_relative src/scripts
    run_phase_in_chroot "Creating VM image from existing image" \
        ./image_to_vm.sh "--board=${FLAGS_board}"
  fi

  if [[ -n "${FLAGS_test}" ]]; then
    chdir_relative src/scripts
    if [[ -z "${FLAGS_remote}" ]]; then
      # Launch remote machine and run tests.  We need first to
      # figure out what IP to use.
      if ! run_phase "Running VM tests locally" \
        ./bin/cros_run_vm_test "--board=${FLAGS_board}" \
        "--test_case=${FLAGS_test}" ${FLAGS_vm_options}; then
        if [[ ${FLAGS_ignore_remote_test_failures} -eq ${FLAGS_FALSE} ]]; then
          die "VM tests failed and --ignore_remote_test_failures not passed"
        fi
      fi
    else
      # We purposefully do not quote FLAGS_test below as we expect it may
      # have multiple parameters
      if ! run_phase "Running tests on Chromium OS machine ${FLAGS_remote}" \
        ./run_remote_tests.sh "--remote=${FLAGS_remote}" ${FLAGS_test} \
        "${board_param}" --build; then
        if [[ ${FLAGS_ignore_remote_test_failures} -eq ${FLAGS_FALSE} ]]; then
          die "Remote tests failed and --ignore_remote_test_failures not passed"
        fi
      fi
    fi
  fi

  trap cleanup EXIT
  echo ""
  info_div
  info "Successfully used ${FLAGS_top} to:"
  describe_steps
  show_duration
  info_div
}

main "$@"

