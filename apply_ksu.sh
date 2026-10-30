#!/usr/bin/env bash
#
# apply_ksu.sh - Add KernelSU-Next to the UN1CA sm7125 kernel tree.
#
# Run it from the top of the kernel tree:
#
#     ./apply_ksu.sh             # download KernelSU-Next and apply the hooks
#     ./apply_ksu.sh --status    # are they applied?
#     ./apply_ksu.sh --revert    # take them out again
#
# What it does:
#   1. Downloads KernelSU-Next into .build/ and checks out KSU_REF on its
#      "legacy" line (the one supporting non-GKI kernels like this 4.14 tree).
#      KernelSU-Next itself is not modified.
#   2. Checks that KernelSU-Next's handlers still have the signatures the
#      hooks call.
#   3. Applies the manual hooks embedded at the end of this script and links
#      drivers/kernelsu to KernelSU-Next's kernel/ directory.
#
# The changes stay in the working tree until --revert. build_kernel.sh builds
# the tree as it is; build_all.sh applies, builds and reverts in one go.
#
# Options:
#   --ksu-ref <ref>   KernelSU-Next commit, tag or branch
#                     (default: the KSU_REF commit pinned below)
#   --status          Print the state; exit 0 if applied, 3 if not
#   --revert          Remove the hooks and the drivers/kernelsu link
#   -h, --help        Show this help

set -euo pipefail

ROOT_DIR="$PWD"
WORK_DIR="$ROOT_DIR/.build"

KSU_REPO="https://github.com/KernelSU-Next/KernelSU-Next"
KSU_BRANCH="legacy"
# KernelSU-Next ref. v3.1.0-legacy: the 3.2.x+ "legacy" line added a strict
# /data/app superblock-magic check in throne_tracker (KSU-Next #1655) that can
# stop the manager being recognized on Android 16 (IncFS-backed dirs). That is
# what 0b17f242 did here: "Unsupported | Not integrated", with reinstalling the
# manager not helping even once. v3.1.0-legacy predates that check and is
# reported working on the same Android 16 legacy (non-GKI) environment.
# Its manual-hook ABI differs slightly: setresuid takes (ruid, euid, suid).
# check_ksu_signatures catches handler-signature drift; verify the build too.
KSU_REF="v3.1.0-legacy"
KSU_DIR="$WORK_DIR/KernelSU-Next"
KSU_LINK="$ROOT_DIR/drivers/kernelsu"
KSU_LINK_TARGET="../.build/KernelSU-Next/kernel"

# Handlers the embedded hooks call, exactly as KernelSU-Next defines them
# (whitespace-normalized). The hooks declare these themselves, so a changed
# signature would still link and only misbehave on the phone.
KSU_SIGNATURES=(
    "int ksu_handle_execveat_ksud(int *fd, struct filename **filename_ptr, struct user_arg_ptr *argv, struct user_arg_ptr *envp, int *flags)"
    "int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *__never_use_argv, void *__never_use_envp, int *__never_use_flags)"
    "int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags)"
    "int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)"
    "void ksu_handle_sys_read(unsigned int fd)"
    "int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value)"
    "int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)"
    "int ksu_handle_slow_avc_audit(u32 *tsid)"
    "int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid)"
)

APPLIED_NOW=0           # set once this run has applied the hooks

log() {
    echo
    echo "==============================================="
    echo "$*"
    echo "==============================================="
}

die() {
    echo >&2
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    sed -n '3,/^set -euo pipefail$/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

check_kernel_tree() {
    [ -f "$ROOT_DIR/build.sh" ] &&
        [ -f "$ROOT_DIR/arch/arm64/configs/vendor/atoll-sec-perf_defconfig" ] ||
        die "$ROOT_DIR is not the sm7125 kernel tree; run this from its top directory"
    command -v git >/dev/null 2>&1 ||
        die "git is missing; install it from the Debian repositories with:
    sudo apt install git"
    git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        die "$ROOT_DIR is not a git checkout (needed to apply and revert the hooks)"
}

hooks_patch() {
    sed -n '/^__KSU_HOOKS_PATCH_BEGIN__$/,/^__KSU_HOOKS_PATCH_END__$/{//!p}' \
        "${BASH_SOURCE[0]}"
}

hooked_files() {
    hooks_patch | sed -n 's|^diff --git a/\(.*\) b/.*|\1|p'
}

# "applied", "unapplied" or "conflict" (neither direction applies).
hooks_state() {
    if hooks_patch | git -C "$ROOT_DIR" apply --reverse --check - 2>/dev/null; then
        echo applied
    elif hooks_patch | git -C "$ROOT_DIR" apply --check - 2>/dev/null; then
        echo unapplied
    else
        echo conflict
    fi
}

link_state() {
    if [ -L "$KSU_LINK" ] && [ "$(readlink "$KSU_LINK")" = "$KSU_LINK_TARGET" ]; then
        echo linked
    elif [ -e "$KSU_LINK" ] || [ -L "$KSU_LINK" ]; then
        echo foreign
    else
        echo missing
    fi
}

# Apply or revert (-R) the hooks, falling back to a 3-way merge when the
# context moved. A 3-way merge stages its result; it is unstaged again so
# the change lives in the working tree only.
patch_tree() {
    local files
    mapfile -t files < <(hooked_files)
    if hooks_patch | git -C "$ROOT_DIR" apply "$@" - 2>/dev/null; then
        return 0
    fi
    git -C "$ROOT_DIR" diff --cached --quiet -- "${files[@]}" || return 1
    if hooks_patch | git -C "$ROOT_DIR" apply --3way "$@" - >/dev/null 2>&1 &&
       git -C "$ROOT_DIR" diff --quiet --diff-filter=U; then
        git -C "$ROOT_DIR" reset -q -- "${files[@]}"
        return 0
    fi
    git -C "$ROOT_DIR" reset -q -- "${files[@]}"
    return 1
}

show_status() {
    local hooks link
    hooks="$(hooks_state)" link="$(link_state)"
    echo "hooks: $hooks"
    echo "drivers/kernelsu: $link"
    if [ -d "$KSU_DIR/.git" ]; then
        echo "KernelSU-Next: $(git -C "$KSU_DIR" log -1 --format='%h (%ad) %s' --date=short)"
    fi
    [ "$hooks" = applied ] && [ "$link" = linked ] || exit 3
}

revert() {
    log "Reverting KernelSU-Next"
    case "$(hooks_state)" in
        applied)
            patch_tree --reverse ||
                die "the hooks could not be reverted; restore these files with git checkout:
$(hooked_files)"
            echo "hooks: reverted"
            ;;
        unapplied) echo "hooks: not applied" ;;
        conflict)
            die "the hooked files changed since the hooks were applied; check them with
    git diff -- $(hooked_files | tr '\n' ' ')"
            ;;
    esac
    case "$(link_state)" in
        linked) rm -f "$KSU_LINK"; echo "drivers/kernelsu: removed" ;;
        missing) ;;
        foreign) echo "WARNING: $KSU_LINK is not ours; left in place" >&2 ;;
    esac
}

setup_kernelsu() {
    log "Setting up KernelSU-Next ($KSU_REF)"
    mkdir -p "$WORK_DIR"
    if [ ! -d "$KSU_DIR/.git" ]; then
        rm -rf "$KSU_DIR"
        # Full history (blobs on demand): Kbuild derives the version code
        # that the manager checks from the commit count.
        git clone --filter=blob:none -b "$KSU_BRANCH" "$KSU_REPO" "$KSU_DIR"
    fi
    # Only a commit hash that is already present can skip the fetch; branch
    # and tag names must always be refreshed.
    if ! { [[ "$KSU_REF" =~ ^[0-9a-f]{40}$ ]] &&
           git -C "$KSU_DIR" cat-file -e "$KSU_REF^{commit}" 2>/dev/null; }; then
        git -C "$KSU_DIR" fetch --tags --force origin \
            "+refs/heads/*:refs/remotes/origin/*"
    fi
    local ref="$KSU_REF"
    if git -C "$KSU_DIR" rev-parse -q --verify "origin/$KSU_REF^{commit}" >/dev/null; then
        ref="origin/$KSU_REF"
    fi
    git -C "$KSU_DIR" checkout -q -f --detach "$ref" ||
        die "KernelSU-Next ref '$KSU_REF' not found"
    echo "KernelSU-Next at $(git -C "$KSU_DIR" log -1 --format='%h (%ad) %s' --date=short)"
}

check_ksu_signatures() {
    local sources sig bad=0
    sources="$(find "$KSU_DIR/kernel" -name '*.c' -exec cat {} + | tr '\n\t' '  ' | tr -s ' ')"
    for sig in "${KSU_SIGNATURES[@]}"; do
        if ! grep -qF -- "$sig" <<<"$sources"; then
            echo "  changed or missing: $sig" >&2
            bad=1
        fi
    done
    [ "$bad" -eq 0 ] || die "KernelSU-Next $KSU_REF no longer matches the embedded hooks.
    Update the hooks at the end of this script (and KSU_SIGNATURES) for the
    new handler signatures, or use the previous --ksu-ref."
}

apply_hooks() {
    log "Applying KernelSU-Next manual hooks"
    case "$(hooks_state)" in
        applied) echo "hooks: already applied" ;;
        *)
            patch_tree ||
                die "the hooks no longer apply to this kernel tree; update the patch at the end of this script"
            APPLIED_NOW=1
            echo "hooks: applied"
            ;;
    esac
}

link_kernelsu() {
    case "$(link_state)" in
        foreign) die "$KSU_LINK exists and is not our link to $KSU_LINK_TARGET" ;;
        *) ln -sfn "$KSU_LINK_TARGET" "$KSU_LINK" ;;
    esac
    echo "drivers/kernelsu -> $KSU_LINK_TARGET"
}

# A failed or interrupted run takes out the hooks it applied itself.
on_exit() {
    local status=$?
    if [ "$status" -ne 0 ] && [ "$APPLIED_NOW" -eq 1 ]; then
        set +e
        echo "Undoing the hooks applied by this run" >&2
        patch_tree --reverse || echo "WARNING: could not revert: $(hooked_files | tr '\n' ' ')" >&2
    fi
    exit "$status"
}

action=apply
while [ $# -gt 0 ]; do
    case "$1" in
        --ksu-ref)
            [ $# -ge 2 ] || die "$1 needs a value"
            KSU_REF="$2"
            shift
            ;;
        --status) action=status ;;
        --revert) action=revert ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

check_kernel_tree
case "$action" in
    status) show_status; exit 0 ;;
    revert) revert; exit 0 ;;
esac

trap on_exit EXIT
trap 'exit 130' INT TERM
[ "$(link_state)" != foreign ] || die "$KSU_LINK exists and is not our link to $KSU_LINK_TARGET"
setup_kernelsu
check_ksu_signatures
apply_hooks
link_kernelsu
APPLIED_NOW=0
log "KernelSU-Next applied; build with ./build_kernel.sh, undo with $0 --revert"
exit 0

# Manual hooks for KernelSU-Next legacy on this 4.14 tree (git diff format).
#  - fs/exec.c calls the ksud and sucompat halves separately instead of
#    ksu_handle_execveat(): that wrapper hands the same struct user_arg_ptr *
#    to su logging, which reads it as a kernel char ** and can fault when
#    `su` is executed.
#  - kernel/reboot.c hooks before the CAP_SYS_BOOT check, since the manager
#    is an unprivileged app.
#  - fs/namespace.c, fs/internal.h and include/linux/seccomp.h carry the
#    backports that KernelSU-Next's Kbuild would otherwise sed into the tree
#    during `make`; with them present it leaves the sources alone.
: <<'__KSU_HOOKS_PATCH_END__'
__KSU_HOOKS_PATCH_BEGIN__
diff --git a/drivers/Kconfig b/drivers/Kconfig
index 3c159f046a83..c63ecbf85816 100755
--- a/drivers/Kconfig
+++ b/drivers/Kconfig
@@ -259,4 +259,6 @@ source "drivers/security/samsung/tzic/Kconfig"
 
 source "drivers/spu_verify/Kconfig"
 
+source "drivers/kernelsu/Kconfig"
+
 endmenu
diff --git a/drivers/Makefile b/drivers/Makefile
index a15c735e51a5..213259dc4ef0 100755
--- a/drivers/Makefile
+++ b/drivers/Makefile
@@ -224,3 +224,6 @@ obj-$(CONFIG_TZIC)  += security/samsung/tzic/
 
 # SPU signature verify
 obj-$(CONFIG_SPU_VERIFY) += spu_verify/
+
+# KernelSU-Next
+obj-$(CONFIG_KSU) += kernelsu/
diff --git a/drivers/input/input.c b/drivers/input/input.c
index 8b24574fe1f0..0d77d05140e3 100755
--- a/drivers/input/input.c
+++ b/drivers/input/input.c
@@ -379,10 +379,21 @@ static int input_get_disposition(struct input_dev *dev,
 	return disposition;
 }
 
+#ifdef CONFIG_KSU_MANUAL_HOOK
+extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code,
+					 int *value);
+#endif
+
 static void input_handle_event(struct input_dev *dev,
 			       unsigned int type, unsigned int code, int value)
 {
-	int disposition = input_get_disposition(dev, type, code, &value);
+	int disposition;
+
+#ifdef CONFIG_KSU_MANUAL_HOOK
+	ksu_handle_input_handle_event(&type, &code, &value);
+#endif
+
+	disposition = input_get_disposition(dev, type, code, &value);
 
 	if (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)
 		add_input_randomness(type, code, value);
diff --git a/fs/exec.c b/fs/exec.c
index 88c409795554..f3d26e366c77 100755
--- a/fs/exec.c
+++ b/fs/exec.c
@@ -1885,11 +1885,25 @@ static int __do_execve_file(int fd, struct filename *filename,
 	return retval;
 }
 
+#ifdef CONFIG_KSU_MANUAL_HOOK
+extern int ksu_handle_execveat_ksud(int *fd, struct filename **filename_ptr,
+				    struct user_arg_ptr *argv,
+				    struct user_arg_ptr *envp, int *flags);
+extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
+					void *argv, void *envp, int *flags);
+#endif
+
 static int do_execveat_common(int fd, struct filename *filename,
 			      struct user_arg_ptr argv,
 			      struct user_arg_ptr envp,
 			      int flags)
 {
+#ifdef CONFIG_KSU_MANUAL_HOOK
+	if (!IS_ERR(filename)) {
+		ksu_handle_execveat_ksud(&fd, &filename, &argv, &envp, &flags);
+		ksu_handle_execveat_sucompat(&fd, &filename, NULL, NULL, NULL);
+	}
+#endif
 	return __do_execve_file(fd, filename, argv, envp, flags, NULL);
 }
 
diff --git a/fs/internal.h b/fs/internal.h
index 948407a1eecd..b4c60a765f2d 100755
--- a/fs/internal.h
+++ b/fs/internal.h
@@ -76,6 +76,7 @@ extern int finish_automount(struct vfsmount *, struct path *);
 extern int sb_prepare_remount_readonly(struct super_block *);
 
 extern void __init mnt_init(void);
+int path_umount(struct path *path, int flags);
 
 extern int __mnt_want_write(struct vfsmount *);
 extern int __mnt_want_write_file(struct file *);
diff --git a/fs/namespace.c b/fs/namespace.c
index 07fb3e1c9b98..e989ead141b4 100755
--- a/fs/namespace.c
+++ b/fs/namespace.c
@@ -1895,6 +1895,40 @@ SYSCALL_DEFINE1(oldumount, char __user *, name)
 
 #endif
 
+static int can_umount(const struct path *path, int flags)
+{
+	struct mount *mnt = real_mount(path->mnt);
+
+	if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
+		return -EINVAL;
+	if (!may_mount())
+		return -EPERM;
+	if (path->dentry != path->mnt->mnt_root)
+		return -EINVAL;
+	if (!check_mnt(mnt))
+		return -EINVAL;
+	if (mnt->mnt.mnt_flags & MNT_LOCKED)
+		return -EINVAL;
+	if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
+		return -EPERM;
+	return 0;
+}
+
+/* caller must hold a reference to path; it is dropped here */
+int path_umount(struct path *path, int flags)
+{
+	struct mount *mnt = real_mount(path->mnt);
+	int ret;
+
+	ret = can_umount(path, flags);
+	if (!ret)
+		ret = do_umount(mnt, flags);
+
+	dput(path->dentry);
+	mntput_no_expire(mnt);
+	return ret;
+}
+
 static bool is_mnt_ns_file(struct dentry *dentry)
 {
 	/* Is this a proxy for a mount namespace? */
diff --git a/fs/open.c b/fs/open.c
index e0857ce70187..c1c03688f1cc 100755
--- a/fs/open.c
+++ b/fs/open.c
@@ -359,6 +359,11 @@ SYSCALL_DEFINE4(fallocate, int, fd, int, mode, loff_t, offset, loff_t, len)
  * We do this by temporarily clearing all FS-related capabilities and
  * switching the fsuid/fsgid around to the real ones.
  */
+#ifdef CONFIG_KSU_MANUAL_HOOK
+extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
+				int *mode, int *flags);
+#endif
+
 SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
 {
 	const struct cred *old_cred;
@@ -369,6 +374,10 @@ SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
 	int res;
 	unsigned int lookup_flags = LOOKUP_FOLLOW;
 
+#ifdef CONFIG_KSU_MANUAL_HOOK
+	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
+#endif
+
 	if (mode & ~S_IRWXO)	/* where's F_OK, X_OK, W_OK, R_OK? */
 		return -EINVAL;
 
diff --git a/fs/read_write.c b/fs/read_write.c
index 82ecadc17a28..7d96ba66451d 100755
--- a/fs/read_write.c
+++ b/fs/read_write.c
@@ -589,11 +589,20 @@ static inline void file_pos_write(struct file *file, loff_t pos)
 		file->f_pos = pos;
 }
 
+#ifdef CONFIG_KSU_MANUAL_HOOK
+extern void ksu_handle_sys_read(unsigned int fd);
+#endif
+
 SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
 {
-	struct fd f = fdget_pos(fd);
+	struct fd f;
 	ssize_t ret = -EBADF;
 
+#ifdef CONFIG_KSU_MANUAL_HOOK
+	ksu_handle_sys_read(fd);
+#endif
+
+	f = fdget_pos(fd);
 	if (f.file) {
 		loff_t pos = file_pos_read(f.file);
 		ret = vfs_read(f.file, buf, count, &pos);
diff --git a/fs/stat.c b/fs/stat.c
index 0fda4b6b8fb2..7cc17be8034e 100755
--- a/fs/stat.c
+++ b/fs/stat.c
@@ -163,6 +163,11 @@ EXPORT_SYMBOL(vfs_statx_fd);
  *
  * 0 will be returned on success, and a -ve error code if unsuccessful.
  */
+#ifdef CONFIG_KSU_MANUAL_HOOK
+extern int ksu_handle_stat(int *dfd, const char __user **filename_user,
+			   int *flags);
+#endif
+
 int vfs_statx(int dfd, const char __user *filename, int flags,
 	      struct kstat *stat, u32 request_mask)
 {
@@ -170,6 +175,10 @@ int vfs_statx(int dfd, const char __user *filename, int flags,
 	int error = -EINVAL;
 	unsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;
 
+#ifdef CONFIG_KSU_MANUAL_HOOK
+	ksu_handle_stat(&dfd, &filename, &flags);
+#endif
+
 	if ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |
 		       AT_EMPTY_PATH | KSTAT_QUERY_FLAGS)) != 0)
 		return -EINVAL;
diff --git a/include/linux/seccomp.h b/include/linux/seccomp.h
index a9d5c52de4ea..4adb3b100d70 100755
--- a/include/linux/seccomp.h
+++ b/include/linux/seccomp.h
@@ -11,6 +11,7 @@
 #ifdef CONFIG_SECCOMP
 
 #include <linux/thread_info.h>
+#include <linux/atomic.h>
 #include <asm/seccomp.h>
 
 struct seccomp_filter;
@@ -27,6 +28,7 @@ struct seccomp_filter;
  */
 struct seccomp {
 	int mode;
+	atomic_t filter_count;
 	struct seccomp_filter *filter;
 };
 
diff --git a/kernel/reboot.c b/kernel/reboot.c
index 671341d76288..4ff76d4c885c 100755
--- a/kernel/reboot.c
+++ b/kernel/reboot.c
@@ -282,6 +282,11 @@ static DEFINE_MUTEX(reboot_mutex);
  *
  * reboot doesn't sync: do that yourself before calling this.
  */
+#ifdef CONFIG_KSU_MANUAL_HOOK
+extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,
+				 void __user **arg);
+#endif
+
 SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
 		void __user *, arg)
 {
@@ -289,6 +294,10 @@ SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
 	char buffer[256];
 	int ret = 0;
 
+#ifdef CONFIG_KSU_MANUAL_HOOK
+	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
+#endif
+
 	/* We only trust the superuser with rebooting the system. */
 	if (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))
 		return -EPERM;
diff --git a/security/selinux/avc.c b/security/selinux/avc.c
index e275e0c46280..c39b8071ec13 100755
--- a/security/selinux/avc.c
+++ b/security/selinux/avc.c
@@ -761,6 +761,10 @@ static void avc_audit_post_callback(struct audit_buffer *ab, void *a)
 	}
 }
 
+#ifdef CONFIG_KSU_MANUAL_HOOK
+extern int ksu_handle_slow_avc_audit(u32 *tsid);
+#endif
+
 /* This is the slow part of avc audit with big stack footprint */
 noinline int slow_avc_audit(struct selinux_state *state,
 			    u32 ssid, u32 tsid, u16 tclass,
@@ -771,6 +775,10 @@ noinline int slow_avc_audit(struct selinux_state *state,
 	struct common_audit_data stack_data;
 	struct selinux_audit_data sad;
 
+#ifdef CONFIG_KSU_MANUAL_HOOK
+	ksu_handle_slow_avc_audit(&tsid);
+#endif
+
 	if (!a) {
 		a = &stack_data;
 		a->type = LSM_AUDIT_DATA_NONE;
diff --git a/kernel/sys.c b/kernel/sys.c
index 3241bcd026ef..1a9ef6ffeaba 100755
--- a/kernel/sys.c
+++ b/kernel/sys.c
@@ -595,6 +595,10 @@ error:
  * This function implements a generic ability to update ruid, euid,
  * and suid.  This allows you to implement the 4.4 compatible seteuid().
  */
+#ifdef CONFIG_KSU_MANUAL_HOOK
+extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
+#endif
+
 SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)
 {
 	struct user_namespace *ns = current_user_ns();
@@ -603,6 +607,10 @@ SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)
 	int retval;
 	kuid_t kruid, keuid, ksuid;
 
+#ifdef CONFIG_KSU_MANUAL_HOOK
+	ksu_handle_setresuid(ruid, euid, suid);
+#endif
+
 	kruid = make_kuid(ns, ruid);
 	keuid = make_kuid(ns, euid);
 	ksuid = make_kuid(ns, suid);
__KSU_HOOKS_PATCH_END__

