// SPDX-License-Identifier: GPL-2.0
/*
 * Subleq Virtual Machine host-file (WAD) driver
 *
 * Exposes a file held by the VM's host as read-only character devices:
 *
 *   /dev/wad      - the file itself (in Vaadoom: the IWAD the browser fetched)
 *   /dev/wadname  - the file name the host suggests for it, e.g. "doom2.wad"
 *
 * Both support read() and llseek(), which is all vanilla DOOM's W_AddFile()
 * needs: for a name ending in "wad" it only open()s, read()s the header, and
 * lseek()s to the lump directory - it never fstat()s the file. So /root/doom's
 * IWAD can simply be a symlink to /dev/wad and DOOM plays a WAD that never
 * exists as a file anywhere in the guest.
 *
 * The transfer itself is done BY THE HOST: the driver points the device at a
 * bounce page (a physical word index), rings the doorbell, and the host memcpy's
 * that slice of the file into guest RAM at native speed. The emulated CPU only
 * pays for the copy_to_user() - the same cost it would pay reading from a
 * ramfs, which matters a great deal on a machine that executes one instruction.
 *
 * The MMIO registers are ordinary zero-page words, so a VM without this device
 * just leaves them at zero: subleq_hf_get_size() returns 0, the driver reports
 * "no host file", and the guest falls back to the WAD in its own initramfs.
 *
 * See arch/subleq/kernel/subleq-wad.S and the Vaadoom engine's em_devices.h.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/slab.h>
#include <linux/mutex.h>
#include <linux/uaccess.h>
#include <linux/init.h>
#include <asm/page.h>

/* MMIO helpers (arch/subleq/kernel/subleq-wad.S) */
extern void subleq_hf_set_sel(unsigned long sel);
extern void subleq_hf_set_dest(unsigned long phys_word_index);
extern void subleq_hf_set_off(unsigned long byte_offset);
extern void subleq_hf_transfer(unsigned long bytes);
extern unsigned long subleq_hf_get_size(void);
extern long subleq_hf_get_done(void);

#define HF_SEL_DATA	0UL
#define HF_SEL_NAME	1UL
#define WAD_BOUNCE_BYTES	PAGE_SIZE

static void *wad_bounce;		/* physically contiguous staging buffer */
static DEFINE_MUTEX(wad_lock);		/* the device has one set of registers */

/* Size of one stream, as the host currently reports it. */
static u32 wad_stream_size(unsigned long sel)
{
	u32 size;

	mutex_lock(&wad_lock);
	subleq_hf_set_sel(sel);
	size = (u32)subleq_hf_get_size();
	mutex_unlock(&wad_lock);
	return size;
}

static ssize_t wad_read_stream(unsigned long sel, char __user *buf, size_t count,
			       loff_t *ppos)
{
	size_t done = 0;
	u32 size;
	int ret = 0;

	if (*ppos < 0)
		return -EINVAL;

	mutex_lock(&wad_lock);

	subleq_hf_set_sel(sel);
	size = (u32)subleq_hf_get_size();
	if (!size) {
		mutex_unlock(&wad_lock);
		return 0;			/* no host file: EOF at offset 0 */
	}
	if (*ppos >= size) {
		mutex_unlock(&wad_lock);
		return 0;
	}
	if (count > size - (u32)*ppos)
		count = size - (u32)*ppos;

	while (count) {
		size_t chunk = min(count, (size_t)WAD_BOUNCE_BYTES);
		long got;

		subleq_hf_set_dest((unsigned long)__pa(wad_bounce) >> 2);
		subleq_hf_set_off((unsigned long)(*ppos + done));
		subleq_hf_transfer(chunk);	/* the host copies it in */
		got = subleq_hf_get_done();
		if (got <= 0) {
			ret = done ? 0 : -EIO;
			break;
		}
		if (copy_to_user(buf + done, wad_bounce, got)) {
			ret = done ? 0 : -EFAULT;
			break;
		}
		done += got;
		count -= got;
	}

	mutex_unlock(&wad_lock);

	if (done) {
		*ppos += done;
		return done;
	}
	return ret;
}

static loff_t wad_llseek_stream(unsigned long sel, struct file *f, loff_t off, int whence)
{
	return fixed_size_llseek(f, off, whence, wad_stream_size(sel));
}

/* ------------------------------------------------------------------ /dev/wad */

static ssize_t wad_read(struct file *f, char __user *buf, size_t count, loff_t *ppos)
{
	return wad_read_stream(HF_SEL_DATA, buf, count, ppos);
}

static loff_t wad_llseek(struct file *f, loff_t off, int whence)
{
	return wad_llseek_stream(HF_SEL_DATA, f, off, whence);
}

static const struct file_operations wad_fops = {
	.owner	= THIS_MODULE,
	.read	= wad_read,
	.llseek	= wad_llseek,
};

static struct miscdevice wad_dev = {
	.minor	= MISC_DYNAMIC_MINOR,
	.name	= "wad",
	.fops	= &wad_fops,
	.mode	= 0444,
};

/* -------------------------------------------------------------- /dev/wadname */

static ssize_t wadname_read(struct file *f, char __user *buf, size_t count, loff_t *ppos)
{
	return wad_read_stream(HF_SEL_NAME, buf, count, ppos);
}

static loff_t wadname_llseek(struct file *f, loff_t off, int whence)
{
	return wad_llseek_stream(HF_SEL_NAME, f, off, whence);
}

static const struct file_operations wadname_fops = {
	.owner	= THIS_MODULE,
	.read	= wadname_read,
	.llseek	= wadname_llseek,
};

static struct miscdevice wadname_dev = {
	.minor	= MISC_DYNAMIC_MINOR,
	.name	= "wadname",
	.fops	= &wadname_fops,
	.mode	= 0444,
};

/* ---------------------------------------------------------------- init/exit */

static int __init subleq_wad_init(void)
{
	u32 size;
	int ret;

	wad_bounce = kzalloc(WAD_BOUNCE_BYTES, GFP_KERNEL);
	if (!wad_bounce)
		return -ENOMEM;

	ret = misc_register(&wad_dev);
	if (ret)
		goto err_bounce;

	ret = misc_register(&wadname_dev);
	if (ret)
		goto err_wad;

	size = wad_stream_size(HF_SEL_DATA);
	if (size)
		pr_info("subleq_wad: /dev/wad ready (host file, %u bytes)\n", size);
	else
		pr_info("subleq_wad: /dev/wad ready (no host file supplied)\n");
	return 0;

err_wad:
	misc_deregister(&wad_dev);
err_bounce:
	kfree(wad_bounce);
	wad_bounce = NULL;
	return ret;
}

static void __exit subleq_wad_exit(void)
{
	misc_deregister(&wadname_dev);
	misc_deregister(&wad_dev);
	kfree(wad_bounce);
	wad_bounce = NULL;
}

device_initcall(subleq_wad_init);
module_exit(subleq_wad_exit);

MODULE_DESCRIPTION("Subleq Virtual Machine host-file (WAD) driver");
MODULE_LICENSE("GPL");
