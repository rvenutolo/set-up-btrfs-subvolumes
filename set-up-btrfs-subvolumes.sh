#!/usr/bin/env bash

# TODO update these comments for new location
# $ sudo bash -c "$(wget -qO- 'https://raw.githubusercontent.com/rvenutolo/scripts/main/setup/_post-install/set-up-btrfs-subvolumes.sh')"
# $ sudo bash -c "$(curl -fsLS 'https://raw.githubusercontent.com/rvenutolo/scripts/main/setup/_post-install/set-up-btrfs-subvolumes.sh')"
#
# This is intended to be run after a fresh OS install and from a live image (or
# at least some situation where the relevant btrfs partition is not mounted and
# in-use). Nested subvolumes are not supported. Run this will root privileges.

## TODO support nested output subvols

## TODO instead of moving files, do snapshots

## TODO TEST and detail versions and bios/uefi tested

set -euo pipefail
shopt -s dotglob extglob

readonly id5_mount='/tmp/id5'
readonly fs_mount='/tmp/fs'
readonly temp_all_files_dir='_'
readonly default_mount_options='defaults,noatime,autodefrag,discard=async,commit=120,compress-force=zstd:1'
# shellcheck disable=SC2088
readonly default_subvolumes=(
  # TODO undo @woot
  '/ @woot'
  '/.snapshots @snapshots'
  '/nix @nix'
  '/opt @opt'
  '/root @root'
  '/srv @srv'
  '/swap @swap +C'
  '/tmp @tmp'
  '/usr/local @usr-local'
  '/var @var'
  '/var/cache @var-cache'
  '/var/crash @var-crash'
  '/var/lib/containers @var-lib-containers'
  '/var/lib/docker @var-lib-docker'
  '/var/lib/flatpak @var-lib-flatpak'
  '/var/lib/libvirt/images @var-lib-libvirt-images +C'
  '/var/lib/mailman @var-lib-mailman'
  '/var/lib/machines @var-lib-machines'
  '/var/lib/named @var-lib-named'
  '/var/lib/portables @var-lib-portables'
  '/var/lib/snapd @var-lib-snapd'
  '/var/log @var-log'
  '/var/opt @var-opt'
  '/var/spool @var-spool'
  '/var/tmp @var-tmp'
  '~ @home'
  '~/.cache @home-cache'
  '~/.local @home-local'
  '~/.local/share/containers/storage @home-containers-storage'
  '~/.local/share/flatpak @home-flatpak'
  '~/.local/share/Steam/SteamApps @home-steamapps'
  '~/.var @home-var'
  '~/Code @home-code'
  '~/Downloads @home-downloads'
  '~/Phone @home-home'
  '~/snap @home-snap'
  '~/Temp @home-temp'
)

function log() {
  echo -e "log [$(date +%T)]: $*" >&2
}

function die() {
  echo -e "DIE: $* (at ${BASH_SOURCE[1]}:${FUNCNAME[1]} line ${BASH_LINENO[0]}.)" >&2
  exit 1
}

if [[ "${EUID}" != 0 ]]; then
  die 'You need to run this script with root privileges.'
fi

# $1 = executable
function executable_exists() {
  # executables / no builtins, aliases, or functions
  type -aPf "$1" &> '/dev/null'
}

# $1 = executable
function chroot_executable_exists() {
  chroot "${fs_mount}" bash -c "type -aPf $1" &> '/dev/null'
}

# $1 = question
# $2 = default value (optional)
function prompt_for_value() {
  if [[ "${prompt_user}" == 'y' ]]; then
    REPLY=''
    if [[ "$#" == '2' ]]; then
      read -rp "$1 [$2]: "
      if [[ -z "${REPLY}" ]]; then
        echo "$2"
      else
        echo "${REPLY}"
      fi
    else
      while [[ -z "${REPLY}" ]]; do
        read -rp "$1 : "
      done
    fi
  else
    echo "$2"
  fi
}

# $1 = question
function prompt_yn() {
  if [[ "${prompt_user}" == 'y' ]]; then
    REPLY=''
    while [[ "${REPLY}" != 'y' && "${REPLY}" != 'n' ]]; do
      read -rp "$1 [Y/n]: "
      if [[ "${REPLY}" == '' || ${REPLY} == [yY] ]]; then
        REPLY='y'
      elif [[ "${REPLY}" == [nN] ]]; then
        REPLY='n'
      fi
    done
    [[ "${REPLY}" == 'y' ]]
  else
    true
  fi
}

function install_jq() {
  if ! executable_exists 'jq'; then
    if executable_exists 'pacman'; then
      pacman --sync --noconfirm 'jq'
    elif executable_exists 'apt'; then
      apt install --yes 'jq'
    elif exectuable_exists 'dnf'; then
      dnf install --assumeyes 'jq'
    elif executable_exists 'zypper'; then
      zypper install --no-confirm 'jq'
    else
      die 'Could not find an expected package manager and cannot install jq.'
    fi
  fi
}

function get_btrfs_partition() {
  local best_guess
  log "$(lsblk --fs)"
  best_guess="$(lsblk --paths --sort size --output NAME,FSTYPE | grep --word-regexp 'btrfs' | tail -1 | cut --delimiter=' ' --fields=1)"
  prompt_for_value 'Mount which Btrfs disk partition?' "${best_guess}"
}

function get_partition_uuid() {
  blkid --output export "${btrfs_partition}" | awk -F '=' '$1 == "UUID" { print $2 }'
}

function check_partition_not_mounted() {
  if grep --quiet --word-regexp "${btrfs_partition}" '/proc/mounts'; then
    die "${btrfs_partition} is already mounted. This script expects that the partition is not mounted."
  fi
}

function get_mount_options() {
  prompt_for_value 'Btrfs mount options?' "${default_mount_options}"
}

# $1 = mount point
# $2 = extra mount options
function mount_btrfs_partition() {
  local mount_options
  log "Creating mount point: $1"
  mkdir --parents "$1"
  if [[ -n "${2-}" ]]; then
    mount_options="${btrfs_mount_options},$2"
  else
    mount_options="${btrfs_mount_options}"
  fi
  log "Mounting: ${btrfs_partition} to: $1 with options: ${mount_options}"
  mount --types 'btrfs' --options "${mount_options}" "${btrfs_partition}" "$1"
}

function get_btrfs_layout() {
  local subvolume_parents distinct_subvolume_parents num_subvolumes_with_parent_id_5
  subvolume_parents="$(btrfs subvolume list -p "${id5_mount}" | cut --delimiter=' ' --fields='6')"
  if [[ -z "${subvolume_parents}" ]]; then
    # Some distros will not create any subvolumes past the ID5 subvolume, like
    # Pop OS.
    echo 'none'
  else
    readarray -t distinct_subvolume_parents <<< "$(echo "${subvolume_parents}" | tr ' ' '\n' | sort --unique --numeric)"
    if [[ "${#distinct_subvolume_parents[@]}" == '1' ]]; then
      if [[ "${distinct_subvolume_parents[0]}" == '5' ]]; then
        echo 'flat'
      else
        die "Unexpected single distinct parent subvolume: ${distinct_subvolume_parents[0]}"
      fi
    else
      num_subvolumes_with_parent_id_5="$(echo "${subvolume_parents}" | tr ' ' '\n' | grep --count '^5$')"
      if [[ "${num_subvolumes_with_parent_id_5}" == '1' ]]; then
        echo 'nested'
      else
        echo 'hybrid'
      fi
    fi
  fi
}

function get_subvolume_from_mount_options() {
  awk -F ',' '{ for (i = 1; i <= NF; ++i) if ( $i ~ "^subvol=" )  print $i }' <<< "$1" | cut --delimiter='=' --fields=2
}

function get_existing_root_subvolume() {
  local subvolume_best_guess fstab_to_read root_mount_options
  log 'Getting existing '/' subvolume'
  if [[ "${btrfs_layout}" == 'nested' ]]; then
    die 'Nested subvolumes are not supported (yet)'
  fi
  if [[ "${btrfs_layout}" == 'none' ]]; then
    echo ''
    return
  fi
  # Some distros may make a Btrfs snapshot as part of installation. Assume that
  # all the fstab files you could find are the same and reading from any of them
  # will produce the same results.
  fstab_to_read="$(find "${id5_mount}" -path '*/etc/fstab' | head --lines='1')"
  root_mount_options="$(grep --invert-match --regexp='^\s*$' --regexp='^\s*#' "${fstab_to_read}" | awk '$2 == "/" { print $4 }')"
  if [[ -z "${root_mount_options}" ]]; then
    die "$(cat "${fstab_to_read}")\nCould not find '/' mount point in: ${fstab_to_read}"
  fi
  if grep --quiet --fixed-strings 'subvol=' <<< "${root_mount_options}"; then
    subvolume_best_guess="$(get_subvolume_from_mount_options "${root_mount_options}")"
  else
    die "$(cat "${fstab_to_read}")\nCould not find existing '/' subvolume"
  fi
  log "Existing subvolumes:\n$(btrfs subvolume list -p "${id5_mount}")"
  log "fstab file:\n$(cat "${fstab_to_read}")"
  prompt_for_value "Btrfs '/' subvolume?" "${subvolume_best_guess}"
}

# $1 = root subvolume
function create_btrfs_fs_mount() {
  if [[ "${btrfs_layout}" == 'nested' ]]; then
    die 'Nested subvolumes are not supported (yet)'
  fi
  if [[ -z "$1" ]]; then
    mount_btrfs_partition "${fs_mount}" 'subvolid=5'
  else
    mount_btrfs_partition "${fs_mount}" "subvol=$1"
  fi
  for dir in '/dev' '/dev/pts' '/sys' '/sys/firmware/efi/efivars' '/proc' '/run'; do
    if [[ -d "${dir}" ]]; then
      mkdir --parents "${fs_mount}${dir}"
      mount --bind "${dir}" "${fs_mount}${dir}"
    fi
  done
  chroot "${fs_mount}" mount --all --verbose
}

function check_os_id() {
  local os_id
  os_id="$(cat "${fs_mount}/etc/os-release" | awk -F '=' '$1 == "ID" { print $2 }')"
  case "${os_id}" in
    ubuntu | debian | fedora | pop) ;;
    *)
      log "Unsupported OS ID: ${os_id}. This script has not been tested on this OS."
      log 'This script will likely work, but this script will NOT attempt to update the bootloader if the '/' subvolume name has changed.'
      if ! prompt_yn 'Continue?'; then
        die 'Exiting.'
      fi
      ;;
  esac
}

function get_username() {
  local username_best_guess
  # shellcheck disable=SC2012
  username_best_guess="$(ls -1 "${fs_mount}/home" | head --lines='1')"
  if [[ -n "${username_best_guess}" ]]; then
    prompt_for_value 'Username?' "${username_best_guess}"
  else
    # Some distros (vanilla Fedora 38) may not create a user during installation
    # and instead create one after first boot.
    log 'No users found. If this script creates a /home/[username] directory or child of that directory, it will be owned by root and you will need to chown it later'
    prompt_for_value 'Username?'
  fi
}

function destroy_btrfs_fs_mount() {
  umount --recursive "${fs_mount}"
}

function prepare_mounts_edit_file() {
  local btrfs_mounts_only_file subvolume mount_point name chattr_modes btrfs_mounts_edit_file
  btrfs_mounts_only_file="$(mktemp)"
  echo '#<mount_point> <subvolume_name> <chattr_modes>' > "${btrfs_mounts_only_file}"
  for subvolume in "${default_subvolumes[@]/'~'//home/${username}}"; do
    IFS=' ' read -r mount_point name chattr_modes <<< "${subvolume}"
    if [[ "${mount_point}" != '/' ]]; then
      mount_point="${mount_point%/}"
    fi
    echo "${mount_point} ${name} ${chattr_modes}" >> "${btrfs_mounts_only_file}"
  done
  btrfs_mounts_edit_file="$(mktemp)"
  {
    echo '# Edit this file to set desired Btrfs mounts. Save and exit to continue running the script.'
    echo '#'
    echo '# <chattr_modes> is a comma-separated list of modes to apply to the dir at the mount point.'
    echo '# example:'
    echo '#   /var/lib/libvirt/images @var-lib-libvirt-images +C,+m'
    echo '#   would run chattr+C and chattr +m on /var/lib/libvirtd/images'
    echo '#'
  } > "${btrfs_mounts_edit_file}"
  LC_ALL=C sort "${btrfs_mounts_only_file}" | column --table >> "${btrfs_mounts_edit_file}"
  echo "${btrfs_mounts_edit_file}"
}

function cleanup_mounts_file() {
  local btrfs_mounts_file line mount_point name chattr_modes
  # Remove comments, empty lines, sort mounts, remove trailing slashes from
  # mounts, and make into table for convenience later.
  btrfs_mounts_file="$(mktemp)"
  grep --invert-match --regexp='^\s*$' --regexp='^\s*#' "${btrfs_mounts_edit_file}" | while read -r line; do
    IFS=' ' read -r mount_point name chattr_modes <<< "${line}"
    if [[ "${mount_point}" != '/' ]]; then
      mount_point="${mount_point%/}"
    fi
    echo "${mount_point} ${name} ${chattr_modes}"
  done | column --table > "${btrfs_mounts_file}"
  echo "${btrfs_mounts_file}"
}

function check_btrfs_mounts() {
  local dir
  # These dirs should probably exist on the '/' subvolume together.
  for dir in '/bin' '/etc' '/lib' 'lib64' '/sbin' '/usr'; do
    if grep --quiet "^${dir}\s" "${btrfs_mounts_file}"; then
      die "I refuse to move ${dir} to another subvolume."
    fi
  done
  if grep --quiet '$/\s' "${btrfs_mounts_file}"; then
    die "$(cat "${btrfs_mounts_file}")\nNo '/' subvolume defined."
  fi
}

function move_all_files_to_top_level_subvolume() {
  local fstab_to_read fstab_line file_system mount_point type options dump pass subvolume_name
  log 'Moving all files to top-level subvolume'
  if [[ "${btrfs_layout}" == 'nested' ]]; then
    die 'Nested subvolumes are not supported (yet)'
  fi
  if [[ "${btrfs_layout}" == 'none' ]]; then
    # Nothing to do. All files are already in the top-level subvolume.
    return
  fi
  # Some distros may make a Btrfs snapshot as part of installation. Assume that
  # all the fstab files you could find are the same and reading from any of them
  # will produce the same results.
  fstab_to_read="$(find "${id5_mount}" -path '*/etc/fstab' | head --lines='1')"
  mkdir "${id5_mount}/${temp_all_files_dir}"
  while read -r fstab_line; do
    # shellcheck disable=SC2034
    IFS=' ' read -r file_system mount_point type options dump pass <<< "${fstab_line}"
    subvolume_name="$(get_subvolume_from_mount_options "${options}")"
    if [[ -d "${id5_mount}/${subvolume_name}" ]]; then
      if [[ -z "$(ls --almost-all "${id5_mount}/${subvolume_name}")" ]]; then
        log "${id5_mount}/${subvolume_name} is empty -- Not moving files"
      else
        log "Moving files from: ${id5_mount}/${subvolume_name} to: ${id5_mount}/${temp_all_files_dir}${mount_point}"
        mv "${id5_mount}/${subvolume_name}/"* "${id5_mount}/${temp_all_files_dir}${mount_point}"
      fi
    else
      die "${id5_mount}/${subvolume_name} does not exist."
    fi
    log "Deleting subvolume: ${subvolume_name}"
    btrfs subvolume delete "${id5_mount}/${subvolume_name}"
  done < <(grep "^\s*UUID=${btrfs_partition_uuid}" "${fstab_to_read}" | sort --key=2)
  mv "${id5_mount}/${temp_all_files_dir}/"* "${id5_mount}"
  rmdir "${id5_mount}/${temp_all_files_dir}"
}

function write_new_fstab_file() {
  local fstab_file fstab_table_file line mount_point name chattr_modes
  log 'Writing new fstab file'
  fstab_file="${id5_mount}/etc/fstab"
  cp "${fstab_file}" "${fstab_file}.orig"
  fstab_table_file="$(mktemp)"
  echo '#<file_system> <mount_point> <type> <options> <dump> <pass>' > "${fstab_table_file}"
  grep --invert-match --regexp='^\s*$' --regexp='^\s*#' --regexp "^\s*UUID=${btrfs_partition_uuid}" "${fstab_file}" >> "${fstab_table_file}"
  while read -r line; do
    IFS=' ' read -r mount_point name chattr_modes <<< "${line}"
    # Currently, Btrfs subvolumes cannot be mounted with different
    # Btrfs-specific options. Only the options for the first subvolume mounted
    # will take effect. So only include the full list of mount options for the
    # '/' subvolume.
    #
    # Subvolumes can be mounted with different filesystem-independent options,
    # such as 'noatime', but that is not supported by this script. Btrfs does
    # plan to allow for some differing Btrfs-specific options like 'compress'
    # and 'autodefrag'.
    if [[ "${mount_point}" == '/' ]]; then
      echo "UUID=${btrfs_partition_uuid} ${mount_point} btrfs ${btrfs_mount_options},subvol=${name} 0 0" >> "${fstab_table_file}"
    else
      echo "UUID=${btrfs_partition_uuid} ${mount_point} btrfs subvol=${name} 0 0" >> "${fstab_table_file}"
    fi
  done < "${btrfs_mounts_file}"
  {
    echo '# /etc/fstab: static file system information.'
    echo '#'
    column --table "${fstab_table_file}"
  } > "${fstab_file}"
}

function move_all_files_into_top_level_tmpdir() {
  log "Moving all files from: ${id5_mount} to: ${id5_mount}/${temp_all_files_dir}"
  # Doing this instead of 'mv "${id5_mount}"/!(foo) ${id5_mount}/foo' as
  # that messes with IntelliJ parsing.
  # shellcheck disable=SC2010
  ls --almost-all --directory "${id5_mount}/"* | grep --invert-match --line-regexp "${id5_mount}/${temp_all_files_dir}" | xargs mv --target-directory="${id5_mount}/${temp_all_files_dir}"
}

function create_dirs_for_mounts() {
  local line mount_point name chattr_modes octal_permissions owner_user_id owner_group_id set_perms_on existing_parent_dir get_perms_from
  log 'Creating directories for mounts'
  while read -r line; do
    IFS=' ' read -r mount_point name chattr_modes <<< "${line}"
    if [[ ! -d "${id5_mount}/${temp_all_files_dir}${mount_point}" ]]; then
      log "Creating dir: ${id5_mount}/${temp_all_files_dir}${mount_point}"
      existing_parent_dir="$(dirname "${id5_mount}/${temp_all_files_dir}${mount_point}")"
      while [[ ! -d "${existing_parent_dir}" ]]; do
        existing_parent_dir="$(dirname "${existing_parent_dir}")"
      done
      mkdir --parents "${id5_mount}/${temp_all_files_dir}${mount_point}"
      if [[ "${existing_parent_dir}" == "${id5_mount}/${temp_all_files_dir}" ]]; then
        get_perms_from="${id5_mount}/${temp_all_files_dir}/usr"
      else
        get_perms_from="${existing_parent_dir}"
      fi
      octal_permissions="$(stat --format='%a' "${get_perms_from}")"
      owner_user_id="$(stat --format='%u' "${get_perms_from}")"
      owner_group_id="$(stat --format='%g' "${get_perms_from}")"
      set_perms_on="${existing_parent_dir}/$(sed --expression "s#${existing_parent_dir}/##" --expression 's#/.*##' <<< "${id5_mount}/${temp_all_files_dir}${mount_point}")"
      log "Setting permissions and owner on: ${set_perms_on} from: ${get_perms_from}"
      chmod -R "${octal_permissions}" "${set_perms_on}"
      chown -R "${owner_user_id}:${owner_group_id}" "${set_perms_on}"
    fi
  done < "${btrfs_mounts_file}"
}

function create_subvolumes() {
  local line mount_point name chattr_modes octal_permissions owner_user_id owner_group_id get_perms_from
  log 'Creating subvolumes'
  while read -r line; do
    IFS=' ' read -r mount_point name chattr_modes <<< "${line}"
    log "Creating subvolume: ${name}"
    btrfs subvolume create "${id5_mount}/${name}"
    if [[ "${mount_point}" == '/' ]]; then
      get_perms_from="${id5_mount}/${temp_all_files_dir}/usr"
    else
      get_perms_from="${id5_mount}/${temp_all_files_dir}${mount_point}"
    fi
    log "Setting permissions and owner on: ${id5_mount}/${name} from: ${get_perms_from}"
    octal_permissions="$(stat --format='%a' "${get_perms_from}")"
    owner_user_id="$(stat --format='%u' "${get_perms_from}")"
    owner_group_id="$(stat --format='%g' "${get_perms_from}")"
    chmod "${octal_permissions}" "${id5_mount}/${name}"
    chown "${owner_user_id}:${owner_group_id}" "${id5_mount}/${name}"
    if [[ -n "${chattr_modes}" ]]; then
      IFS=',' read -r -a mode_array <<< "${chattr_modes}"
      for mode in "${mode_array[@]}"; do
        log "Applying file attribute change: ${mode} to: ${id5_mount}/${name}"
        chattr "${mode}" "${id5_mount}/${name}"
      done
    fi
  done < "${btrfs_mounts_file}"
}

function populate_subvolumes() {
  local line mount_point name chattr_modes
  log 'Populating subvolumes'
  while read -r line; do
    IFS=' ' read -r mount_point name chattr_modes <<< "${line}"
    log "Moving files from: ${id5_mount}/${temp_all_files_dir}${mount_point} to: ${id5_mount}/${name}"
    if [[ -d "${id5_mount}/${temp_all_files_dir}${mount_point}" ]]; then
      if [[ -z "$(ls --almost-all "${id5_mount}/${temp_all_files_dir}${mount_point}")" ]]; then
        log "${id5_mount}/${temp_all_files_dir}${mount_point} is empty -- Not moving files"
      else
        mv "${id5_mount}/${temp_all_files_dir}${mount_point}/"* "${id5_mount}/${name}"
      fi
    else
      die "${id5_mount}/${temp_all_files_dir}${mount_point} does not exist."
    fi
  done < <(tac "${btrfs_mounts_file}")
}

function get_new_root_subvolume() {
  local root_subvolume
  root_subvolume="$(awk '$1 == "/" { print $2 }' "${btrfs_mounts_file}")"
  if [[ -z "${root_subvolume}" ]]; then
    die "$(cat "${btrfs_mounts_file}")\nCould not find root subvolume name."
  fi
  echo "${root_subvolume}"
}

function update_debian_ubuntu_uefi_bootloader() {
  local fs device
  fs="$(df --output='source' "${fs_mount}" | sed '1d')"
  device="$(lsblk --noheadings --paths --output 'PKNAME' "${fs}")"
  chroot "${fs_mount}" grub-install "${device}" --target='x86_64-efi'
  chroot "${fs_mount}" grub-mkconfig --output='/boot/grub/grub.cfg'
}

function update_ubuntu_uefi_bootloader() {
  log 'Updating Ubuntu GRUB UEFI bootloader'
  update_debian_ubuntu_uefi_bootloader
}

function update_debian_uefi_bootloader() {
  log 'Updating Debian GRUB UEFI bootloader'
  update_debian_ubuntu_uefi_bootloader
}

function update_fedora_uefi_bootloader() {
  log 'Updating Fedora GRUB UEFI bootloader'
  chroot "${fs_mount}" dnf reinstall --assumeyes 'grub2-efi' 'grub2-efi-modules' 'shim'
  chroot "${fs_mount}" grub2-mkconfig --output='/boot/grub2/grub.cfg'
}

function update_pop_uefi_bootloader() {
  local target_rootflags_option conf_file existing_options new_options kernelstub_conf_file existing_rootflags_option
  log 'Updating Pop OS systemd-boot UEFI bootloader'
  install_jq
  target_rootflags_option="rootflags=subvol=${root_subvolume}"
  for conf_file in "${fs_mount}/boot/efi/loader/entries/"*'.conf'; do
    existing_options="$(grep '^\s*options\s*' "${conf_file}")"
    if ! grep --quiet --word-regexp "root=${btrfs_partition_uuid}" "${conf_file}"; then
      # This conf file doesn't have 'root=<partition_uuid>', so don't touch it.
      continue
    fi
    if grep --quiet --word-regexp "${target_rootflags_option}" "${conf_file}"; then
      # This conf file already has the desired rootflags.
      continue
    fi
    log "Adding '${target_rootflags_option}' to: ${conf_file}"
    mv "${conf_file}" "${conf_file}.orig"
    new_options="$(sed --expression 's/\s*rootflags=subvolume=\S*//' --expression "s/$/ ${target_rootflags_option}/" <<< "${existing_options}")"
    sed "s|^${existing_options}$|${new_options}|" "${conf_file}.orig" > "${conf_file}"
  done
  kernelstub_conf_file="${fs_mount}/etc/kernelstub/configuration"
  existing_rootflags_option="$(jq --raw-output '.user.kernel_options[] | select(startswith("rootflags=subvolume="))' "${kernelstub_conf_file}")"
  if [[ "${existing_rootflags_option}" != "${target_rootflags_option}" ]]; then
    log "Adding '${target_rootflags_option}' to: ${kernelstub_conf_file}"
    mv "${kernelstub_conf_file}" "${kernelstub_conf_file}.orig"
    jq ".user.kernel_options -= [\"${existing_rootflags_option}\"] | .user.kernel_options += [\"${target_rootflags_option}\"]" "${kernelstub_conf_file}.orig" > "${kernelstub_conf_file}"
  fi
  chroot "${fs_mount}" update-initramfs -c -k 'all'
}

function update_debian_ubuntu_bios_bootloader() {
  local fs device
  fs="$(df --output='source' "${fs_mount}" | sed '1d')"
  device="$(lsblk --noheadings --paths --output 'PKNAME' "${fs}")"
  chroot "${fs_mount}" grub-install "${device}" --target='i386-pc'
  chroot "${fs_mount}" grub-mkconfig --output='/boot/grub/grub.cfg'
}

function update_ubuntu_bios_bootloader() {
  log 'Updating Ubuntu GRUB BIOS bootloader'
  update_debian_ubuntu_bios_bootloader
}

function update_debian_bios_bootloader() {
  log 'Updating Debian GRUB BIOS bootloader'
  update_debian_ubuntu_bios_bootloader
}

function update_fedora_bios_bootloader() {
  log 'Updating Fedora GRUB BIOS bootloader'
  chroot "${fs_mount}" grub2-mkconfig --output='/boot/grub2/grub.cfg'
}

function update_bootloader() {
  local os_id
  os_id="$(awk -F '=' '$1 == "ID" { print $2 }' "${fs_mount}/etc/os-release")"
  if [[ -d '/sys/firmware/efi' ]]; then
    case "${os_id}" in
      ubuntu | debian | fedora | pop)
        # shellcheck disable=SC2086
        update_${os_id}_uefi_bootloader
        ;;
      *)
        log "Unsupported UEFI + OS ID: ${os_id}. Bootloader will not be updated."
        log "Refer to the distro's documentation to update the bootloader for a new '/' subvolume."
        ;;
    esac
  else
    case "${os_id}" in
      ubuntu | debian | fedora)
        # shellcheck disable=SC2086
        update_${os_id}_bios_bootloader
        ;;
      *)
        log "Unsupported BIOS + OS ID: ${os_id}. Bootloader will not be updated."
        log "Refer to the distro's documentation to update the bootloader for a new '/' subvolume."
        ;;
    esac
  fi
}

function set_selinux_autorelabel() {
  echo '-F -M -T 0' > "${fs_mount}/.autorelabel"
  log 'SELinux will relabel files on next boot.'
}

function main() {

  if [[ -n "${1-}" ]]; then
    if [[ "$1" == 'auto' ]]; then
      prompt_user='n'
    else
      die "Unexpected argument: '$1'"
    fi
  else
    prompt_user='y'
  fi
  readonly prompt_user

  btrfs_partition="$(get_btrfs_partition)"
  readonly btrfs_partition

  btrfs_partition_uuid="$(get_partition_uuid)"
  readonly btrfs_partition_uuid

  check_partition_not_mounted

  btrfs_mount_options="$(get_mount_options)"
  readonly btrfs_mount_options
  mount_btrfs_partition "${id5_mount}" 'subvolid=5'

  btrfs_layout="$(get_btrfs_layout)"
  readonly btrfs_layout

  orig_root_subvolume="$(get_existing_root_subvolume)"
  readonly orig_root_subvolume

  create_btrfs_fs_mount "${orig_root_subvolume}"

  check_os_id

  username="$(get_username)"
  readonly username

  destroy_btrfs_fs_mount

  btrfs_mounts_edit_file="$(prepare_mounts_edit_file)"
  readonly btrfs_mounts_edit_file
  if [[ "${prompt_user}" == 'y' ]]; then
    nano "${btrfs_mounts_edit_file}"
  fi
  btrfs_mounts_file="$(cleanup_mounts_file)"
  readonly btrfs_mounts_file
  check_btrfs_mounts

  log "Btrfs partition: ${btrfs_partition}"
  log "Btrfs partition UUID: ${btrfs_partition_uuid}"
  log "Btrfs layout: ${btrfs_layout}"
  log "Btrfs mount options: ${btrfs_mount_options}"
  log "Btrfs original '/' subvolume: ${orig_root_subvolume}"
  log "Username: ${username}"
  log "Btrfs mounts:\n$(cat "${btrfs_mounts_file}")"

  if ! prompt_yn 'Continue? (No changes have been applied)'; then
    die 'Exiting'
  fi

  move_all_files_to_top_level_subvolume

  write_new_fstab_file

  mkdir "${id5_mount}/${temp_all_files_dir}"
  move_all_files_into_top_level_tmpdir
  create_dirs_for_mounts
  create_subvolumes
  populate_subvolumes
  rmdir "${id5_mount}/${temp_all_files_dir}"

  root_subvolume="$(get_new_root_subvolume)"
  readonly root_subvolume

  create_btrfs_fs_mount "${root_subvolume}"

  if [[ "${orig_root_subvolume}" != "${root_subvolume}" ]]; then
    if prompt_yn 'Update bootloader? (the Btrfs root subvolume has changed)'; then
      update_bootloader
    fi
  fi

  if chroot_executable_exists 'fixfiles'; then
    set_selinux_autorelabel
  fi

  log "Btrfs subvolumes:\n$(btrfs subvolume list -t "${id5_mount}")"
  log "fstab file:\n$(cat "${fs_mount}/etc/fstab")"

  log "To chroot into the Btrfs file system, run: chroot ${fs_mount}"
  log "To unmount the Btrfs partition, run: umount --all-targets --recursive ${id5_mount}"

}

main "$@"
