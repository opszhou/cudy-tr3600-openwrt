#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Portions derived from OpenWrt package/base-files/files/lib/upgrade/nand.sh.
# Copyright (C) 2014 OpenWrt.org
# Cudy TR3600 v1 dual-slot sysupgrade integration. Sourced by sysupgrade.

# This package is selected by the TR3600 image profile. If it is ever installed
# manually elsewhere, leave that platform's native upgrade hooks untouched.
[ "$(board_name 2>/dev/null)" = cudy,tr3600-v1 ] || return 0

TR3600_SYSUPGRADE_IMAGE=${TR3600_SYSUPGRADE_IMAGE:-}
TR3600_SYSUPGRADE_BYTES=${TR3600_SYSUPGRADE_BYTES:-}
TR3600_SYSUPGRADE_SHA=${TR3600_SYSUPGRADE_SHA:-}
TR3600_IMAGE_KERNEL_BYTES=${TR3600_IMAGE_KERNEL_BYTES:-}
TR3600_IMAGE_KERNEL_SHA=${TR3600_IMAGE_KERNEL_SHA:-}
TR3600_IMAGE_ROOTFS_BYTES=${TR3600_IMAGE_ROOTFS_BYTES:-}
TR3600_IMAGE_ROOTFS_SHA=${TR3600_IMAGE_ROOTFS_SHA:-}
TR3600_IMAGE_ROOTFS_DATA_BYTES=
TR3600_IMAGE_TARGET_SLOT=
BB=/bin/busybox

# Best-effort diagnostics; failure to log never changes upgrade control flow.
TR3600_PHASE_LOG=/tmp/tr3600-dualslot.phases

tr3600_phase()
{
    case "$1" in
        CALL_BEGIN|CALL_RETURN_NONZERO|CALL_RETURN_ZERO|ADAPTER_ENTER|PREMUTATION_PASS|TARGET_INVALID_SET|FLASH_FUNCTION_RETURNED|KERNEL_VERIFIED|ROOTFS_VERIFIED|DATA_CAPACITY_VERIFIED|UPGRADE_SUCCESS_HELPER_ENTER) ;;
        *) return 0 ;;
    esac
    # Diagnostic failure must not alter firmware operation control flow.
    ( printf 'TR3600_PHASE_V1 %s\n' "$1" >> "$TR3600_PHASE_LOG" ) 2>/dev/null || :
    return 0
}

tr3600_uint() { case "$1" in ''|*[!0-9]*) return 1;; 0|[1-9]*) return 0;; *) return 1;; esac; }
tr3600_hash() { "$BB" sha256sum "$1" 2>/dev/null | "$BB" awk '{print $1}'; }

tr3600_exact_file()
{
	[ -f "$1" ] && [ ! -L "$1" ] || return 1
	[ "$("$BB" wc -c < "$1" | "$BB" tr -d ' ')" = "$2" ] || return 1
	[ "$(tr3600_hash "$1")" = "$3" ]
}

tr3600_exact_tar_board_dir()
{
	local tar_file="$1" cmd="${2:-cat}" listing
	listing="$($cmd < "$tar_file" | tar tf -)" || return 1
	[ "$listing" = 'sysupgrade-cudy_tr3600-v1/
sysupgrade-cudy_tr3600-v1/CONTROL
sysupgrade-cudy_tr3600-v1/kernel
sysupgrade-cudy_tr3600-v1/root' ] || return 1
	printf '%s' sysupgrade-cudy_tr3600-v1
}

tr3600_volume_index()
{
	local class_root="$1" wanted="$2" path value count=0 index=
	for path in "$class_root"/ubi0_*/name; do
		[ -f "$path" ] && [ ! -L "$path" ] || continue
		value="$("$BB" cat "$path" 2>/dev/null)" || return 1
		[ "$value" = "$wanted" ] || continue
		count=$((count + 1)); index="${path%/name}"; index="${index##*_}"
	done
	[ "$count" -eq 1 ] && tr3600_uint "$index" || return 1
	printf '%s' "$index"
}

tr3600_volume_dev()
{
	local class_root="$1" wanted="$2" index value
	index="$(tr3600_volume_index "$class_root" "$wanted")" || return 1
	[ -f "$class_root/ubi0_$index/dev" ] && [ ! -L "$class_root/ubi0_$index/dev" ] || return 1
	value="$("$BB" cat "$class_root/ubi0_$index/dev" 2>/dev/null)" || return 1
	case "$value" in
	*:*) tr3600_uint "${value%%:*}" && tr3600_uint "${value#*:}" || return 1;;
	*) return 1;;
	esac
	printf '%s' "$value"
}

tr3600_volume_tuple()
{
	local class_root="$1" name="$2" index base attr value tuple
	index="$(tr3600_volume_index "$class_root" "$name")" || return 1
	base="$class_root/ubi0_$index"
	[ -L "$base" ] || return 1
	tuple="$index"
	for attr in name type data_bytes usable_eb_size reserved_ebs alignment dev upd_marker corrupted; do
		[ -f "$base/$attr" ] && [ ! -L "$base/$attr" ] || return 1
		value="$("$BB" cat "$base/$attr" 2>/dev/null)" || return 1
		case "$attr" in
		name) [ "$value" = "$name" ] || return 1;;
		type) [ "$value" = dynamic ] || return 1;;
		dev) case "$value" in *:*) tr3600_uint "${value%%:*}" && tr3600_uint "${value#*:}" || return 1;; *) return 1;; esac;;
		*) tr3600_uint "$value" || return 1;;
		esac
		tuple="$tuple|$value"
	done
	printf '%s' "$tuple"
}

tr3600_namespace_snapshot()
{
	local class_root="$1" path count=0 name tuple
	for path in "$class_root"/ubi0_*/name; do [ -f "$path" ] && count=$((count + 1)); done
	[ "$count" -eq 6 ] || return 1
	for name in u-boot-env kernel rootfs kernel2 rootfs2 rootfs_data; do
		tuple="$(tr3600_volume_tuple "$class_root" "$name")" || return 1
		case "$tuple" in *'|0|0') :;; *) return 1;; esac
		printf 'volume=%s\n' "$tuple"
	done
}

tr3600_resolve_active_slot()
{
	local sysfs_root="$1" cmdline="$2" mounts="$3" class_root="$4" phase="${5:-pre}"
	local dual boot_slot target_slot boot_kernel boot_root target_kernel target_root
	local token root_token= root_count=0 mount_source= mount_count=0 mount_index root_index root_dev
	dual="$(tr3600_boot_value "$sysfs_root" "dual_boot" "$cmdline")" || return 1
	boot_slot="$(tr3600_boot_value "$sysfs_root" "boot_image_slot" "$cmdline")" || return 1
	target_slot="$(tr3600_boot_value "$sysfs_root" "upgrade_image_slot" "$cmdline")" || return 1
	boot_kernel="$(tr3600_boot_value "$sysfs_root" "boot_kernel_part" "$cmdline")" || return 1
	boot_root="$(tr3600_boot_value "$sysfs_root" "boot_rootfs_part" "$cmdline")" || return 1
	target_kernel="$(tr3600_boot_value "$sysfs_root" "upgrade_kernel_part" "$cmdline")" || return 1
	target_root="$(tr3600_boot_value "$sysfs_root" "upgrade_rootfs_part" "$cmdline")" || return 1
	case "$dual:$boot_slot:$target_slot:$boot_kernel:$boot_root:$target_kernel:$target_root" in
	Y:0:1:kernel:rootfs:kernel2:rootfs2|Y:1:0:kernel2:rootfs2:kernel:rootfs) ;;
	*) return 1;;
	esac
	for token in $("$BB" cat "$cmdline" 2>/dev/null); do
		case "$token" in ubi.rootfs_volume=*) root_count=$((root_count + 1)); root_token="${token#*=}";; esac
	done
	[ "$root_count" -eq 1 ] && [ "$root_token" = "$boot_root" ] || return 1
	root_index="$(tr3600_volume_index "$class_root" "$boot_root")" || return 1
	root_dev="$(tr3600_volume_dev "$class_root" "$boot_root")" || return 1
	# Volume IDs and block majors may change across boot and volume recreation.
	case "$phase" in
	post)
		tr3600_handoff_check "$boot_slot|$target_slot|$boot_kernel|$boot_root|$target_kernel|$target_root|$root_index|$root_dev" "$mounts" || return 1
		printf '%s|%s|%s|%s|%s|%s\n' "$boot_slot" "$target_slot" "$boot_kernel" "$boot_root" "$target_kernel" "$target_root"
		return 0;;
	pre) :;;
	*) return 1;;
	esac
	while IFS=' ' read -r source target fstype rest; do
		[ "$target:$fstype" = "/rom:squashfs" ] || continue
		mount_count=$((mount_count + 1)); mount_source="$source"
	done < "$mounts"
	[ "$mount_count" -eq 1 ] || return 1
	root_index="$(tr3600_volume_index "$class_root" "$boot_root")" || return 1
	case "$mount_source" in
	/dev/ubiblock0_[0-9]*)
		mount_index="${mount_source##*_}"
		tr3600_uint "$mount_index" && [ "$mount_index" = "$root_index" ] || return 1;;
	/dev/root) :;;
	*) return 1;;
	esac
	tr3600_rom_binding "$boot_root" "$root_index" "${6:-/proc/self/mountinfo}" "${7:-/sys/dev/block}" || return 1
	printf '%s|%s|%s|%s|%s|%s\n' "$boot_slot" "$target_slot" "$boot_kernel" "$boot_root" "$target_kernel" "$target_root"
}

tr3600_assert_adapter_is_last()
{
	local path last= count=0
	for path in /lib/upgrade/*.sh; do
		[ -f "$path" ] && [ ! -L "$path" ] || return 1
		last="$path"; count=$((count + 1))
	done
	[ "$count" -gt 1 ] && [ "$last" = /lib/upgrade/zz-tr3600-dualslot.sh ]
}

tr3600_rootfs_data_capacity()
{
	local index base value
	index="$(tr3600_volume_index /sys/class/ubi rootfs_data)" || return 1
	base="/sys/class/ubi/ubi0_$index"
	[ "$(cat "$base/type" 2>/dev/null)" = dynamic ] || return 1
	[ "$(cat "$base/upd_marker" 2>/dev/null)" = 0 ] || return 1
	[ "$(cat "$base/corrupted" 2>/dev/null)" = 0 ] || return 1
	value="$(cat "$base/data_bytes" 2>/dev/null)" || return 1
	tr3600_uint "$value" && [ "$value" -gt 0 ] || return 1
	printf '%s' "$value"
}

# This transition requires the already attached running ubi0; never attach/format.
tr3600_attached_ubi()
{
    local expected actual
    expected="$(find_mtd_index ubi)" || return 1
    actual="$(cat /sys/class/ubi/ubi0/mtd_num 2>/dev/null)" || return 1
    tr3600_uint "$expected" && tr3600_uint "$actual" || return 1
    [ "$expected" = "$actual" ] || return 1
    printf '%s' ubi0
}

# Check pure image properties before target invalidation, using the vendor tools.
tr3600_image_preflight()
{
    local image="$1" board kernel root kind
    board="$(tr3600_exact_tar_board_dir "$image")" || return 1
    kernel="$(tar xOf "$image" "$board/kernel" | wc -c)" || return 1
    root="$(tar xOf "$image" "$board/root" | wc -c)" || return 1
    kind="$(identify_tar "$image" cat "$board/root")" || return 1
    [ "$kernel:$root:$kind" = "$TR3600_IMAGE_KERNEL_BYTES:$TR3600_IMAGE_ROOTFS_BYTES:squashfs" ]
}

# Exact-size clean reset. No rootfs_data_max lookup/write and no -m fallback.
nand_upgrade_prepare_ubi()
{
	local rootfs_length="$1" rootfs_type="$2" kernel_length="$3" has_env="${4:-0}"
	local ubidev kern root data
	[ "$rootfs_type" = squashfs ] || return 1
	tr3600_uint "$TR3600_IMAGE_ROOTFS_DATA_BYTES" && [ "$TR3600_IMAGE_ROOTFS_DATA_BYTES" -gt 0 ] || return 1
	case "$TR3600_IMAGE_TARGET_SLOT:$CI_UBIPART:$CI_KERNPART:$CI_ROOTPART" in
	0:ubi:kernel:rootfs|1:ubi:kernel2:rootfs2) ;;
	*) return 1;;
	esac
	ubidev="$(tr3600_attached_ubi)" || return 1
	kern="$(nand_find_volume "$ubidev" "$CI_KERNPART")"
	root="$(nand_find_volume "$ubidev" "$CI_ROOTPART")"
	data="$(nand_find_volume "$ubidev" rootfs_data)"
	[ -n "$kern" ] && [ -n "$root" ] && [ -n "$data" ] || return 1
	nand_remove_ubiblock "$kern" || return 1
	nand_remove_ubiblock "$root" || return 1
	nand_remove_ubiblock "$data" || return 1
	ubirmvol "/dev/$ubidev" -N "$CI_KERNPART" || return 1
	ubirmvol "/dev/$ubidev" -N "$CI_ROOTPART" || return 1
	ubirmvol "/dev/$ubidev" -N rootfs_data || return 1
	ubimkvol "/dev/$ubidev" -N "$CI_KERNPART" -s "$kernel_length" || return 1
	ubimkvol "/dev/$ubidev" -N "$CI_ROOTPART" -s "$rootfs_length" || return 1
	ubimkvol "/dev/$ubidev" -N rootfs_data -s "$TR3600_IMAGE_ROOTFS_DATA_BYTES" || return 1
}

# OpenWrt NAND tar flow restricted to the validated dual-slot UBI layout.
# Slot environment updates occur only in the verified upgrade orchestrator.
nand_upgrade_tar()
{
	local tar_file="$1" cmd="${2:-cat}" board_dir kernel_mtd kernel_length rootfs_length rootfs_type
	local ubi_kernel_length ubidev root_ubivol kern_ubivol
	[ "$CI_UBIPART" = ubi ] || return 1
	board_dir="$(tr3600_exact_tar_board_dir "$tar_file" "$cmd")" || return 1
	kernel_mtd="$(find_mtd_index "$CI_KERNPART")"
	[ -z "$kernel_mtd" ] || return 1
	kernel_length=$( ($cmd < "$tar_file" | tar xOf - "$board_dir/kernel" | wc -c) 2>/dev/null) || return 1
	rootfs_length=$( ($cmd < "$tar_file" | tar xOf - "$board_dir/root" | wc -c) 2>/dev/null) || return 1
	[ "$kernel_length:$rootfs_length" = "$TR3600_IMAGE_KERNEL_BYTES:$TR3600_IMAGE_ROOTFS_BYTES" ] || return 1
	rootfs_type="$(identify_tar "$tar_file" "$cmd" "$board_dir/root")" || return 1
	[ "$rootfs_type" = squashfs ] || return 1
	ubi_kernel_length="$kernel_length"
	nand_upgrade_prepare_ubi "$rootfs_length" "$rootfs_type" "$ubi_kernel_length" 0 || return 1
	ubidev="$(nand_find_ubi "$CI_UBIPART")" || return 1
	root_ubivol="$(nand_find_volume "$ubidev" "$CI_ROOTPART")" || return 1
	kern_ubivol="$(nand_find_volume "$ubidev" "$CI_KERNPART")" || return 1
	$cmd < "$tar_file" | tar xOf - "$board_dir/root" | ubiupdatevol "/dev/$root_ubivol" -s "$rootfs_length" - || return 1
	$cmd < "$tar_file" | tar xOf - "$board_dir/kernel" | ubiupdatevol "/dev/$kern_ubivol" -s "$kernel_length" - || return 1
}

tr3600_verify_component()
{
	local name="$1" bytes="$2" hash="$3" index dev actual base type data usable expected upd corrupted
	index="$(tr3600_volume_index /sys/class/ubi "$name")" || return 1
	base="/sys/class/ubi/ubi0_$index"
	type="$(cat "$base/type" 2>/dev/null)" || return 1
	data="$(cat "$base/data_bytes" 2>/dev/null)" || return 1
	usable="$(cat "$base/usable_eb_size" 2>/dev/null)" || return 1
	upd="$(cat "$base/upd_marker" 2>/dev/null)" || return 1
	corrupted="$(cat "$base/corrupted" 2>/dev/null)" || return 1
	tr3600_uint "$data" && tr3600_uint "$usable" && [ "$usable" -gt 0 ] || return 1
	expected=$(( ((bytes + usable - 1) / usable) * usable ))
	[ "$type:$data:$upd:$corrupted" = "dynamic:$expected:0:0" ] || return 1
	dev="/dev/ubi0_$index"; [ -c "$dev" ] && [ ! -L "$dev" ] || return 1
	{
		actual="$("$BB" head -c "$bytes" <&8 | "$BB" sha256sum | "$BB" awk '{print $1}')" || return 1
	} 8<"$dev" || return 1
	[ "$actual" = "$hash" ]
}

tr3600_verify_component_twice()
{
	tr3600_verify_component "$1" "$2" "$3" || return 1
	tr3600_verify_component "$1" "$2" "$3"
}

tr3600_preflight_snapshot()
{
	local binding data_bytes current current_invalid target_invalid boot_slot target_slot rest namespace available leb
	tr3600_attached_ubi >/dev/null || return 1
	# The shipped environment config binds volume zero; never reinterpret it.
	[ "$(tr3600_volume_index /sys/class/ubi u-boot-env)" = 0 ] || return 1
	binding="$(tr3600_resolve_active_slot /sys/module/boot_param/parameters /proc/cmdline /proc/mounts /sys/class/ubi "${1:-post}")" || return 1
	IFS='|' read -r boot_slot target_slot rest <<EOF
$binding
EOF
	current="$(fw_printenv -n dual_boot.current_slot 2>/dev/null)" || return 1
	current_invalid="$(fw_printenv -n "dual_boot.slot_${boot_slot}_invalid" 2>/dev/null)" || return 1
	target_invalid="$(fw_printenv -n "dual_boot.slot_${target_slot}_invalid" 2>/dev/null)" || return 1
	[ "$current:$current_invalid:$target_invalid" = "$boot_slot:0:0" ] || return 1
	data_bytes="$(tr3600_rootfs_data_capacity)" || return 1
	namespace="$(tr3600_namespace_snapshot /sys/class/ubi)" || return 1
	available="$(cat /sys/class/ubi/ubi0/avail_eraseblocks 2>/dev/null)" || return 1
	leb="$(cat /sys/class/ubi/ubi0/eraseblock_size 2>/dev/null)" || return 1
	tr3600_uint "$available" && tr3600_uint "$leb" && [ "$leb" -gt 0 ] || return 1
	printf 'binding=%s\ncurrent=%s\ncurrent_invalid=%s\ntarget_invalid=%s\nrootfs_data_bytes=%s\navailable_eraseblocks=%s\neraseblock_size=%s\n%s\n' \
		"$binding" "$current" "$current_invalid" "$target_invalid" "$data_bytes" "$available" "$leb" "$namespace"
}

tr3600_snapshot_value()
{
	printf '%s\n' "$1" | "$BB" sed -n "s/^$2=//p"
}

tr3600_capacity_check()
{
	local snapshot="$1" available leb released=0 tuple index name type data usable reserved alignment dev upd corrupted
	available="$(tr3600_snapshot_value "$snapshot" available_eraseblocks)"
	leb="$(tr3600_snapshot_value "$snapshot" eraseblock_size)"
	tr3600_uint "$available" && tr3600_uint "$leb" && [ "$leb" -gt 0 ] || return 1
	while IFS= read -r tuple; do
		case "$tuple" in volume=*) tuple="${tuple#volume=}";; *) continue;; esac
		IFS='|' read -r index name type data usable reserved alignment dev upd corrupted <<EOF
$tuple
EOF
		[ "$usable" = "$leb" ] && [ "$data" -eq $((usable * reserved)) ] || return 1
		case "$name" in kernel|kernel2|rootfs|rootfs2|rootfs_data)
			case "$name:$TR3600_IMAGE_TARGET_SLOT" in kernel:0|rootfs:0|kernel2:1|rootfs2:1|rootfs_data:*) released=$((released + data));; esac;;
		esac
	done <<EOF
$snapshot
EOF
	[ $((released + available * leb)) -ge $(( ((TR3600_IMAGE_KERNEL_BYTES + leb - 1) / leb) * leb + ((TR3600_IMAGE_ROOTFS_BYTES + leb - 1) / leb) * leb + TR3600_IMAGE_ROOTFS_DATA_BYTES )) ]
}

cudy_tr3600_dualslot_upgrade()
{
	local image="$1" snapshot_a snapshot_b binding boot_slot target_slot boot_kernel boot_root target_kernel target_root
	local env_line=
	tr3600_phase ADAPTER_ENTER
	[ "$(board_name 2>/dev/null)" = cudy,tr3600-v1 ] || return 1
	[ "$image" = "$TR3600_SYSUPGRADE_IMAGE" ] || return 1
	tr3600_exact_file "$image" "$TR3600_SYSUPGRADE_BYTES" "$TR3600_SYSUPGRADE_SHA" || return 1
	tr3600_assert_adapter_is_last || return 1
	[ ! -e /tmp/sysupgrade.tgz ] || return 1
	snapshot_a="$(tr3600_preflight_snapshot)" || return 1
	snapshot_b="$(tr3600_preflight_snapshot)" || return 1
	[ "$snapshot_a" = "$snapshot_b" ] || return 1
	binding="$(tr3600_snapshot_value "$snapshot_a" binding)" || return 1
	IFS='|' read -r boot_slot target_slot boot_kernel boot_root target_kernel target_root <<EOF
$binding
EOF
	[ -f /etc/fw_env.config ] && [ ! -L /etc/fw_env.config ] && {
		{ IFS= read -r env_line || [ -n "$env_line" ]; } &&
		[ "$env_line" = '/dev/ubi0_0 0 0x80000 0x80000 1' ] && ! IFS= read -r env_line
	} < /etc/fw_env.config || return 1
	TR3600_IMAGE_ROOTFS_DATA_BYTES="$(tr3600_snapshot_value "$snapshot_a" rootfs_data_bytes)" || return 1
	TR3600_IMAGE_TARGET_SLOT="$target_slot"
	tr3600_capacity_check "$snapshot_a" || return 1
	tr3600_image_preflight "$image" || return 1
	tr3600_phase PREMUTATION_PASS
	CI_UBIPART=ubi; CI_KERNPART="$target_kernel"; CI_ROOTPART="$target_root"
	sync; mkdir -p /var/lock && touch /var/lock/fw_printenv.lock || return 1
	fw_setenv "dual_boot.slot_${target_slot}_invalid" 1 || return 1
	tr3600_phase TARGET_INVALID_SET
	nand_do_flash_file "$image" && tr3600_phase FLASH_FUNCTION_RETURNED || { nand_do_upgrade_failed; return 1; }
	tr3600_verify_component_twice "$target_kernel" "$TR3600_IMAGE_KERNEL_BYTES" "$TR3600_IMAGE_KERNEL_SHA" && tr3600_phase KERNEL_VERIFIED || { nand_do_upgrade_failed; return 1; }
	tr3600_verify_component_twice "$target_root" "$TR3600_IMAGE_ROOTFS_BYTES" "$TR3600_IMAGE_ROOTFS_SHA" && tr3600_phase ROOTFS_VERIFIED || { nand_do_upgrade_failed; return 1; }
	[ "$(tr3600_rootfs_data_capacity)" = "$TR3600_IMAGE_ROOTFS_DATA_BYTES" ] && tr3600_phase DATA_CAPACITY_VERIFIED || { nand_do_upgrade_failed; return 1; }
	fw_setenv -s - <<EOF || { nand_do_upgrade_failed; return 1; }
dual_boot.slot_${target_slot}_invalid 0
dual_boot.current_slot ${target_slot}
EOF
	tr3600_phase UPGRADE_SUCCESS_HELPER_ENTER
	nand_do_upgrade_success
	exit 1
}

platform_do_upgrade()
{
	cudy_tr3600_dualslot_upgrade "$1" || { nand_do_upgrade_failed; exit 1; }
}

# Readiness is exported by the pre-pivot hook, never inferred in stage2.
TR3600_HANDOFF=/tmp/tr3600-dualslot.handoff

tr3600_uuid()
{
    printf '%s\n' "$1" | "$BB" grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

tr3600_handoff_check()
{
    local identity="$1" mounts="$2" version nonce boot saved image adapter extra source target kind rest
    [ "${TR3600_HANDOFF_READY:-0}" = 1 ] || return 1
    tr3600_uuid "${TR3600_HANDOFF_NONCE:-}" || return 1
    [ -f "$TR3600_HANDOFF" ] && [ ! -L "$TR3600_HANDOFF" ] || return 1
    {
        IFS= read -r version && IFS= read -r nonce && IFS= read -r boot &&
        IFS= read -r saved && IFS= read -r image && IFS= read -r adapter &&
        ! IFS= read -r extra && [ -z "$extra" ]
    } < "$TR3600_HANDOFF" || return 1
    [ "$version" = TR3600_PHASE_V1 ] && [ "$nonce" = "$TR3600_HANDOFF_NONCE" ] || return 1
    tr3600_uuid "$boot" && [ "$boot" = "$("$BB" cat /proc/sys/kernel/random/boot_id)" ] || return 1
    [ "$saved" = "$identity" ] && [ "$image" = "$TR3600_SYSUPGRADE_SHA" ] || return 1
    [ "$adapter" = "$(tr3600_hash /lib/upgrade/zz-tr3600-dualslot.sh)" ] || return 1
    # This negative phase condition is used only with positive same-hook evidence.
    while IFS=' ' read -r source target kind rest; do
        case "$target" in /rom|/mnt|/mnt/*) return 1;; esac
    done < "$mounts"
}

platform_pre_upgrade()
{
    local image="$1" nonce boot first second binding b t k r tk tr index dev
    export TR3600_HANDOFF_READY=0 TR3600_HANDOFF_NONCE=
    [ "$(board_name)" = cudy,tr3600-v1 ] || return 1
    # procd forwards backup presence, not the front-end SAVE_CONFIG variable.
    [ "${FORCE:-0}" = 0 ] && [ "${SAVE_CONFIG:-0}" = 0 ] &&
        [ -z "${UPGRADE_BACKUP:-}" ] || return 1
    tr3600_bind_image "$image" || return 1
    tr3600_exact_file "$image" "$TR3600_SYSUPGRADE_BYTES" "$TR3600_SYSUPGRADE_SHA" || return 1
    tr3600_assert_adapter_is_last || return 1
    [ ! -e "$TR3600_HANDOFF" ] && [ ! -L "$TR3600_HANDOFF" ] || return 1
    nonce="$("$BB" cat /proc/sys/kernel/random/uuid)" || return 1
    boot="$("$BB" cat /proc/sys/kernel/random/boot_id)" || return 1
    tr3600_uuid "$nonce" && tr3600_uuid "$boot" || return 1
    first="$(tr3600_preflight_snapshot pre)" || return 1
    second="$(tr3600_preflight_snapshot pre)" || return 1
    [ "$first" = "$second" ] || return 1
    binding="$(tr3600_snapshot_value "$first" binding)"
    IFS='|' read -r b t k r tk tr <<EOF
$binding
EOF
    case "$b:$t:$k:$r:$tk:$tr" in
        0:1:kernel:rootfs:kernel2:rootfs2|1:0:kernel2:rootfs2:kernel:rootfs) ;;
        *) return 1;;
    esac
    index="$(tr3600_volume_index /sys/class/ubi "$r")" || return 1
    dev="$(tr3600_volume_dev /sys/class/ubi "$r")" || return 1
    ( umask 077; set -C
      printf '%s\n' TR3600_PHASE_V1 "$nonce" "$boot" "$binding|$index|$dev" \
          "$TR3600_SYSUPGRADE_SHA" "$(tr3600_hash /lib/upgrade/zz-tr3600-dualslot.sh)" > "$TR3600_HANDOFF"
    ) || return 1
    export TR3600_HANDOFF_NONCE="$nonce" TR3600_HANDOFF_READY=1
}

# Bind the mounted squashfs block device to the named UBI volume, not its alias.
tr3600_rom_binding()
{
    local expected="$1" index="$2" info="$3" block_root="$4"
    local id parent dev root mount rest count=0 actual= resolved
    while IFS=' ' read -r id parent dev root mount rest; do
        [ "$mount" = /rom ] || continue
        count=$((count + 1)); actual="$dev"
        case "$rest" in *" - squashfs "*) :;; *) return 1;; esac
    done < "$info"
    [ "$count" -eq 1 ] || return 1
    case "$actual" in
        *:*) tr3600_uint "${actual%%:*}" && tr3600_uint "${actual#*:}" || return 1;;
        *) return 1;;
    esac
    resolved="$("$BB" readlink -f "$block_root/$actual")" || return 1
    case "$resolved" in */ubi0_$index/ubiblock0_$index) :;; *) return 1;; esac
    [ "$("$BB" cat "${resolved%/*}/name" 2>/dev/null)" = "$expected" ]
}


# Bootloader cmdline is available on both upstream and vendor kernels.
tr3600_boot_value()
{
    local sysfs="$1" key="$2" cmdline="$3" token value= count=0 observed
    for token in $("$BB" cat "$cmdline"); do
        case "$token" in
            boot_param.$key=*) value="${token#*=}"; count=$((count+1));;
            boot_param.dual_boot) [ "$key" != dual_boot ] || { value=Y; count=$((count+1)); };;
        esac
    done
    [ "$count" -eq 1 ] || return 1
    if [ -e "$sysfs/$key" ]; then
        observed="$("$BB" cat "$sysfs/$key")" || return 1
        [ "$observed" = "$value" ] || return 1
    fi
    printf '%s' "$value"
}

tr3600_metadata_check()
(
    local image="$1" meta key value target abi_count=0
    [ "${FORCE:-0}" = 0 ] || return 1
    [ "$(board_name)" = cudy,tr3600-v1 ] || return 1
    meta="$(fwtool -q -i - "$image")" || return 1
    . /usr/share/libubox/jshn.sh || return 1
    json_load "$meta" || return 1
    json_select supported_devices || return 1
    json_get_keys keys || return 1
    for key in $keys; do
        json_get_var value "$key"
        [ "$value" = cudy,tr3600-v1-dualslot-v1 ] && abi_count=$((abi_count + 1))
    done
    [ "$abi_count" -eq 1 ] || return 1
    json_select .. || return 1
    json_select version || return 1
    json_get_var target board
    [ "$target" = cudy_tr3600-v1 ] || return 1
    REQUIRE_IMAGE_METADATA=1
    fwtool_check_image "$image"
)

tr3600_bind_image()
{
	local image="$1" board before after kernel_size root_size kernel_hash root_hash
	[ -f "$image" ] && [ ! -L "$image" ] || return 1
	nand_do_platform_check cudy,tr3600-v1 "$image" || return 1
	before="$(tr3600_hash "$image")" || return 1
    tr3600_metadata_check "$image" || return 1
    board="$(tr3600_exact_tar_board_dir "$image")" || return 1
    [ "$(identify_tar "$image" cat "$board/root")" = squashfs ] || return 1
    [ "$(identify_tar "$image" cat "$board/kernel")" = fit ] || return 1
    kernel_size="$(tar xOf "$image" "$board/kernel" | wc -c)" || return 1
    root_size="$(tar xOf "$image" "$board/root" | wc -c)" || return 1
    tr3600_uint "$kernel_size" && tr3600_uint "$root_size" || return 1
    [ "$kernel_size" -gt 0 ] && [ "$root_size" -gt 0 ] || return 1
    kernel_hash="$(tar xOf "$image" "$board/kernel" | "$BB" sha256sum | "$BB" awk '{print $1}')" || return 1
    root_hash="$(tar xOf "$image" "$board/root" | "$BB" sha256sum | "$BB" awk '{print $1}')" || return 1
    after="$(tr3600_hash "$image")" || return 1
    [ "$before" = "$after" ] || return 1
    export TR3600_SYSUPGRADE_IMAGE="$image" TR3600_SYSUPGRADE_SHA="$after"
    export TR3600_SYSUPGRADE_BYTES="$("$BB" wc -c < "$image" | "$BB" tr -d ' ')"
    export TR3600_IMAGE_KERNEL_BYTES="$kernel_size" TR3600_IMAGE_KERNEL_SHA="$kernel_hash"
    export TR3600_IMAGE_ROOTFS_BYTES="$root_size" TR3600_IMAGE_ROOTFS_SHA="$root_hash"
}

platform_check_image()
(
    # LuCI's validation phase may run before its keep-settings choice.
    tr3600_bind_image "$1"
)
