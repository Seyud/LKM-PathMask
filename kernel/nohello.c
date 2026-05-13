// SPDX-License-Identifier: GPL-2.0
/*
 * nohello - hide a given file from all system calls (arm64 Android / GKI)
 *
 * Uses kretprobes to intercept VFS operations and make the target file
 * appear as non-existent.  Identification is via the (inode, dev) pair.
 *
 * Tested on GKI kernels (android12-5.10 through android16-6.12).
 * Only the arm64 architecture is supported.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/cred.h>
#include <linux/fs.h>
#include <linux/namei.h>
#include <linux/version.h>
#include <linux/dirent.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uidgid.h>
#include <linux/uaccess.h>

/* ---------- module parameter ---------- */
#define MAX_HIDE_TARGETS 16
#define MAX_DENY_UIDS 128
#define TARGET_PATHS_LEN 2048
#define UID_LIST_LEN 2048

enum nohello_scope_mode {
	SCOPE_GLOBAL = 0,
	SCOPE_DENY,
};

static char *target_path = "/data/local/tmp/nohello";
module_param(target_path, charp, 0644);
MODULE_PARM_DESC(target_path, "Legacy single absolute path to hide");

static char target_paths[TARGET_PATHS_LEN];
module_param_string(target_paths, target_paths, sizeof(target_paths), 0644);
MODULE_PARM_DESC(target_paths, "Comma-separated absolute paths to hide");

static bool hide_dirents = true;
module_param(hide_dirents, bool, 0644);
MODULE_PARM_DESC(hide_dirents, "Hide target from getdents64 directory listings");

static char scope_mode[16] = "global";
module_param_string(scope_mode, scope_mode, sizeof(scope_mode), 0644);
MODULE_PARM_DESC(scope_mode, "Hide scope: global or deny");

static char deny_uids[UID_LIST_LEN];
module_param_string(deny_uids, deny_uids, sizeof(deny_uids), 0644);
MODULE_PARM_DESC(deny_uids, "Comma-separated UIDs hidden from targets");

/* system-unique target identifiers */
struct hidden_target {
	dev_t dev;
	unsigned long long ino;
};

static struct hidden_target targets[MAX_HIDE_TARGETS];
static unsigned int target_count;
static enum nohello_scope_mode active_scope = SCOPE_GLOBAL;
static uid_t deny_uid_list[MAX_DENY_UIDS];
static unsigned int deny_uid_count;

/* ---------- helper ---------- */
static inline bool is_target_inode(const struct inode *inode)
{
	unsigned int i;

	if (!inode)
		return false;

	for (i = 0; i < target_count; i++) {
		if (inode->i_ino == targets[i].ino &&
		    inode->i_sb->s_dev == targets[i].dev)
			return true;
	}

	return false;
}

static inline bool is_target_ino(__u64 ino)
{
	unsigned int i;

	for (i = 0; i < target_count; i++) {
		if (ino == (__u64)targets[i].ino)
			return true;
	}

	return false;
}

static inline bool is_denied_uid(uid_t uid)
{
	unsigned int i;

	for (i = 0; i < deny_uid_count; i++) {
		if (uid == deny_uid_list[i])
			return true;
	}

	return false;
}

static inline bool should_hide_for_current(void)
{
	uid_t uid;

	if (active_scope == SCOPE_GLOBAL)
		return true;

	uid = __kuid_val(current_fsuid());
	return is_denied_uid(uid);
}

static int parse_scope_mode(void)
{
	if (!strcmp(scope_mode, "global")) {
		active_scope = SCOPE_GLOBAL;
		return 0;
	}

	if (!strcmp(scope_mode, "deny")) {
		active_scope = SCOPE_DENY;
		return 0;
	}

	pr_err("nohello: unsupported scope_mode=%s\n", scope_mode);
	return -EINVAL;
}

static int add_deny_uid(uid_t uid)
{
	if (deny_uid_count >= MAX_DENY_UIDS) {
		pr_warn("nohello: too many deny UIDs, skip %u\n", uid);
		return -ENOSPC;
	}

	if (is_denied_uid(uid))
		return 0;

	deny_uid_list[deny_uid_count++] = uid;
	pr_info("nohello: deny_uid[%u]=%u\n", deny_uid_count - 1, uid);
	return 0;
}

static int parse_deny_uids(void)
{
	char *buf, *cursor, *item;
	int ret = 0;

	if (!deny_uids[0])
		return 0;

	buf = kstrdup(deny_uids, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	cursor = buf;
	while ((item = strsep(&cursor, ",")) != NULL) {
		unsigned int uid;

		item = strim(item);
		if (!*item)
			continue;

		ret = kstrtouint(item, 10, &uid);
		if (ret) {
			pr_warn("nohello: invalid deny uid %s\n", item);
			continue;
		}

		add_deny_uid((uid_t)uid);
	}

	kfree(buf);

	if (active_scope == SCOPE_DENY && !deny_uid_count)
		pr_warn("nohello: scope_mode=deny but deny_uids is empty\n");

	return 0;
}

static int add_target_path(const char *path_name)
{
	struct path path;
	struct inode *inode;
	int ret;

	if (target_count >= MAX_HIDE_TARGETS) {
		pr_warn("nohello: too many targets, skip %s\n", path_name);
		return -ENOSPC;
	}

	ret = kern_path(path_name, 0, &path);
	if (ret) {
		pr_warn("nohello: %s not found (err=%d), skip\n", path_name,
			ret);
		return ret;
	}

	inode = d_inode(path.dentry);
	targets[target_count].ino = inode->i_ino;
	targets[target_count].dev = inode->i_sb->s_dev;
	pr_info("nohello: target[%u] %s ino=%llu dev=%u:%u\n",
		target_count, path_name, targets[target_count].ino,
		MAJOR(targets[target_count].dev),
		MINOR(targets[target_count].dev));
	target_count++;
	path_put(&path);

	return 0;
}

static int resolve_target_paths(const char *paths)
{
	char *buf, *cursor, *item;
	int ret = -ENOENT;

	buf = kstrdup(paths, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	cursor = buf;
	while ((item = strsep(&cursor, ",")) != NULL) {
		item = strim(item);
		if (!*item)
			continue;

		ret = add_target_path(item);
		if (ret && target_count == 0)
			continue;
	}

	kfree(buf);

	if (!target_count)
		return ret;

	return 0;
}

/* ---------- security_inode_permission ---------- */
static struct kretprobe kp_inode_perm;

struct inode_perm_data {
	unsigned long matched;
};

static int perm_inode_entry(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct inode_perm_data *d = (struct inode_perm_data *)ri->data;
	struct inode *inode = (struct inode *)regs->regs[0]; /* x0 */

	d->matched = should_hide_for_current() && is_target_inode(inode);
	return 0;
}

static int perm_exit(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct inode_perm_data *d = (struct inode_perm_data *)ri->data;

	if (d->matched)
		regs_set_return_value(regs, -ENOENT);
	return 0;
}

/* ---------- security_inode_getattr ---------- */
static struct kretprobe kp_inode_getattr;

static int getattr_entry(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct inode_perm_data *d = (struct inode_perm_data *)ri->data;
	struct path *path = (struct path *)regs->regs[0]; /* x0 */
	struct inode *inode = d_inode(path->dentry);

	d->matched = should_hide_for_current() && is_target_inode(inode);
	return 0;
}

static int getattr_exit(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct inode_perm_data *d = (struct inode_perm_data *)ri->data;

	if (d->matched)
		regs_set_return_value(regs, -ENOENT);
	return 0;
}

/* ---------- __arm64_sys_getdents64 ---------- */
#define GETDENTS_BUF_LIMIT 65536u

static struct kretprobe kp_getdents;
static bool getdents_registered;

struct getdents_cb_data {
	struct linux_dirent64 __user *dirent;
	void *kbuf;
	size_t kbuf_len;
	bool scoped;
};

/*
 * Entry: __arm64_sys_getdents64(const struct pt_regs *syscall_regs)
 *   syscall_regs->regs[1] = user buffer (dirent)
 *   syscall_regs->regs[2] = count
 */
static int getdents_entry(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct getdents_cb_data *d = (struct getdents_cb_data *)ri->data;
	struct pt_regs *user_regs = (struct pt_regs *)regs->regs[0];
	unsigned int count;

	d->dirent = NULL;
	d->kbuf = NULL;
	d->kbuf_len = 0;
	d->scoped = should_hide_for_current();

	if (!d->scoped)
		return 0;

	if (!user_regs)
		return 0;

	count = (unsigned int)user_regs->regs[2];
	d->dirent = (struct linux_dirent64 __user *)user_regs->regs[1];

	/* Guard against excessively large allocations */
	count = min(count, GETDENTS_BUF_LIMIT);
	if (!count)
		return 0;

	d->kbuf = kmalloc(count, GFP_KERNEL);
	if (d->kbuf)
		d->kbuf_len = count;
	return 0;
}

static int getdents_exit(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct getdents_cb_data *d = (struct getdents_cb_data *)ri->data;
	long ret = regs->regs[0]; /* return value = bytes written */
	struct linux_dirent64 *kbuf, *prev, *cur;
	long bpos, new_len;
	const size_t hdr_off = offsetof(struct linux_dirent64, d_name);
	const size_t min_reclen = offsetof(struct linux_dirent64, d_name) + 1;
	bool modified = false;

	if (ret <= 0 || !d->scoped || !d->dirent || !d->kbuf)
		goto out;

	if ((size_t)ret > d->kbuf_len) {
		pr_debug_ratelimited("nohello: getdents return too large "
				     "(%ld > %zu), skip filtering\n",
				     ret, d->kbuf_len);
		goto out;
	}

	if (copy_from_user(d->kbuf, d->dirent, ret))
		goto out;

	kbuf = d->kbuf;
	prev = NULL;
	bpos = 0;
	new_len = ret;

	while (bpos + (long)hdr_off < new_len) {
		unsigned short reclen;

		cur = (struct linux_dirent64 *)((char *)kbuf + bpos);
		reclen = cur->d_reclen;

		if (reclen < min_reclen || reclen > new_len - bpos)
			break;

		if (is_target_ino(cur->d_ino)) {
			modified = true;
			if (prev) {
				if ((unsigned int)prev->d_reclen + reclen <=
				    65535u) {
					prev->d_reclen += reclen;
					bpos += reclen;
					continue;
				}
			}

			new_len -= reclen;
			if (new_len > bpos)
				memmove(cur, (char *)cur + reclen,
					new_len - bpos);
			continue;
		}

		prev = cur;
		bpos += reclen;
	}

	if (modified) {
		if (copy_to_user(d->dirent, kbuf, new_len))
			pr_warn_ratelimited("nohello: copy_to_user failed, "
					    "directory may leak\n");
		else
			regs->regs[0] = new_len;
	}

out:
	kfree(d->kbuf);
	d->kbuf = NULL;
	d->kbuf_len = 0;
	return 0;
}

/* ---------- module init / exit ---------- */
static int __init nohello_init(void)
{
	const char *paths = target_paths[0] ? target_paths : target_path;
	int ret;

	ret = parse_scope_mode();
	if (ret)
		return ret;

	ret = parse_deny_uids();
	if (ret)
		return ret;

	ret = resolve_target_paths(paths);
	if (ret) {
		pr_err("nohello: no valid targets (err=%d)\n", ret);
		return ret;
	}

	/* security_inode_permission */
	kp_inode_perm.kp.symbol_name = "security_inode_permission";
	kp_inode_perm.entry_handler = perm_inode_entry;
	kp_inode_perm.handler = perm_exit;
	kp_inode_perm.data_size = sizeof(struct inode_perm_data);
	kp_inode_perm.maxactive = 40;
	ret = register_kretprobe(&kp_inode_perm);
	if (ret) {
		pr_err("nohello: register_kretprobe(security_inode_permission) "
		       "failed: %d\n", ret);
		return ret;
	}
	pr_info("nohello: hooked security_inode_permission\n");

	/* security_inode_getattr */
	kp_inode_getattr.kp.symbol_name = "security_inode_getattr";
	kp_inode_getattr.entry_handler = getattr_entry;
	kp_inode_getattr.handler = getattr_exit;
	kp_inode_getattr.data_size = sizeof(struct inode_perm_data);
	kp_inode_getattr.maxactive = 40;
	ret = register_kretprobe(&kp_inode_getattr);
	if (ret) {
		pr_err("nohello: register_kretprobe(security_inode_getattr) "
		       "failed: %d\n", ret);
		unregister_kretprobe(&kp_inode_perm);
		return ret;
	}
	pr_info("nohello: hooked security_inode_getattr\n");

	if (hide_dirents) {
		/* __arm64_sys_getdents64 */
		kp_getdents.kp.symbol_name = "__arm64_sys_getdents64";
		kp_getdents.entry_handler = getdents_entry;
		kp_getdents.handler = getdents_exit;
		kp_getdents.data_size = sizeof(struct getdents_cb_data);
		kp_getdents.maxactive = 20;
		ret = register_kretprobe(&kp_getdents);
		if (ret) {
			pr_warn("nohello: register_kretprobe(__arm64_sys_getdents64) "
				"failed: %d; file visible in listings but still "
				"hidden from direct access\n",
				ret);
		} else {
			getdents_registered = true;
			pr_info("nohello: hooked __arm64_sys_getdents64\n");
		}
	} else {
		pr_info("nohello: hide_dirents=0, directory listings are "
			"not filtered\n");
	}

	pr_info("nohello: loaded -- %u target(s) hidden, scope=%s, "
		"deny_uid_count=%u\n",
		target_count, scope_mode, deny_uid_count);
	return 0;
}

static void __exit nohello_exit(void)
{
	unregister_kretprobe(&kp_inode_perm);
	unregister_kretprobe(&kp_inode_getattr);
	if (getdents_registered) {
		unregister_kretprobe(&kp_getdents);
		getdents_registered = false;
	}

	pr_info("nohello: unloaded -- %u target(s) visible again\n",
		target_count);
}

module_init(nohello_init);
module_exit(nohello_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("lkm-build");
MODULE_DESCRIPTION("Hide a file by intercepting VFS operations via kprobes");
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)
MODULE_IMPORT_NS("VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver");
#else
MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);
#endif
