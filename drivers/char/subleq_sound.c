// SPDX-License-Identifier: GPL-2.0
/*
 * Subleq Virtual Machine Sound Driver
 *
 * Exposes the lunatix VM's host-side sound card (Nuked-OPL3 + PCM mixing, run
 * by the VM at native speed) to userspace as two character devices:
 *
 *   /dev/dsp  - an OSS-style PCM sink. write() S16_LE stereo frames; the driver
 *               copies them into a ring in physical RAM and bumps the VM's PCM
 *               producer counter. The VM drains [pcm_read, pcm_write) and mixes.
 *   /dev/opl  - a raw OPL3 register port. write() u32 words, each packed as
 *               (reg << 8) | val; the driver forwards each to the OPL3 chip.
 *
 * The card lives on the HOST side of the VM boundary: the guest never
 * synthesizes audio, it only produces register writes (music) and PCM frames
 * (SFX). See docs/sound-handoff-linux.md. The MMIO registers are supervisor-
 * only and sit at negative effective word indices, so they cannot be poked from
 * userspace nor from a plain C store - all access goes through the raw-.word
 * helpers in arch/subleq/kernel/subleq-sound.S.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/slab.h>
#include <linux/mutex.h>
#include <linux/uaccess.h>
#include <linux/init.h>
#include <linux/soundcard.h>
#include <asm/page.h>

/* MMIO helpers (arch/subleq/kernel/subleq-sound.S) */
extern void subleq_opl_write(unsigned long packed);
extern void subleq_pcm_set_base(unsigned long phys_word_index);
extern void subleq_pcm_set_frames(unsigned long frames);
extern void subleq_pcm_set_write(unsigned long total_frames);
extern void subleq_pcm_set_rate(unsigned long hz);

/*
 * PCM ring capacity in stereo frames. Must be physically contiguous (the VM
 * indexes it as flat physical RAM), so the ring is kmalloc'd. 16384 frames * 4
 * bytes = 64 KiB, ~0.37 s at 44.1 kHz - enough to absorb scheduling jitter
 * without a large allocation. One stereo frame per 32-bit word: low 16 bits =
 * Left, high 16 bits = Right (exactly the S16_LE-stereo byte layout, so a raw
 * copy suffices on this little-endian machine).
 */
#define PCM_RING_FRAMES		16384u
#define PCM_FRAME_BYTES		4u		/* S16 L + S16 R */
#define PCM_RING_BYTES		(PCM_RING_FRAMES * PCM_FRAME_BYTES)
#define PCM_RATE_DEFAULT	11025u

static u32 *pcm_ring;			/* kernel virtual == physical (identity map) */
static u32 pcm_write_total;		/* stereo frames enqueued so far (wraps u32) */
static u32 pcm_rate = PCM_RATE_DEFAULT;
static DEFINE_MUTEX(pcm_lock);		/* serializes /dev/dsp writers + rate ioctl */

/* ------------------------------------------------------------------ /dev/dsp */

static ssize_t dsp_write(struct file *f, const char __user *buf, size_t count,
			 loff_t *ppos)
{
	size_t frames, done_bytes = 0;
	int ret = 0;

	/* Whole stereo frames only. */
	count &= ~(size_t)(PCM_FRAME_BYTES - 1);
	if (count == 0)
		return 0;

	frames = count / PCM_FRAME_BYTES;
	if (frames > PCM_RING_FRAMES)		/* never accept more than one ring */
		frames = PCM_RING_FRAMES;

	mutex_lock(&pcm_lock);

	/*
	 * Copy into the ring at (pcm_write_total % cap), splitting across the
	 * wrap. We overwrite whatever the host has not drained yet; the VM's
	 * consumer tolerates being lapped (it drops the oldest frames), so a
	 * slow drain degrades to dropouts rather than a stall.
	 */
	while (frames) {
		u32 pos = pcm_write_total % PCM_RING_FRAMES;
		u32 chunk = min(frames, (size_t)(PCM_RING_FRAMES - pos));

		if (copy_from_user(pcm_ring + pos, buf + done_bytes,
				   chunk * PCM_FRAME_BYTES)) {
			ret = -EFAULT;
			break;
		}
		pcm_write_total += chunk;
		done_bytes += chunk * PCM_FRAME_BYTES;
		frames -= chunk;
	}

	/* Publish the new producer position to the VM. */
	subleq_pcm_set_write(pcm_write_total);

	mutex_unlock(&pcm_lock);

	if (done_bytes)
		return done_bytes;
	return ret;
}

static long dsp_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	int __user *p = (int __user *)arg;
	int val;

	switch (cmd) {
	case SNDCTL_DSP_SPEED:
		if (get_user(val, p))
			return -EFAULT;
		if (val > 0) {
			mutex_lock(&pcm_lock);
			pcm_rate = val;
			subleq_pcm_set_rate(pcm_rate);
			mutex_unlock(&pcm_lock);
		}
		val = pcm_rate;
		return put_user(val, p);

	case SNDCTL_DSP_SETFMT:
		/* Only S16_LE is supported; report it regardless of request. */
		val = AFMT_S16_LE;
		return put_user(val, p);

	case SNDCTL_DSP_GETFMTS:
		val = AFMT_S16_LE;
		return put_user(val, p);

	case SNDCTL_DSP_STEREO:
		val = 1;			/* always stereo */
		return put_user(val, p);

	case SNDCTL_DSP_CHANNELS:
		val = 2;			/* always 2 channels */
		return put_user(val, p);

	case SNDCTL_DSP_GETBLKSIZE:
		val = PCM_RING_BYTES / 4;	/* a reasonable fragment size */
		return put_user(val, p);

	case SNDCTL_DSP_GETOSPACE: {
		/*
		 * We cannot see the VM's consumer position, so advertise the
		 * whole ring as free. This keeps callers non-blocking; the VM
		 * drops the oldest frames if we run ahead.
		 */
		struct audio_buf_info info = {
			.fragments   = 4,
			.fragstotal  = 4,
			.fragsize    = PCM_RING_BYTES / 4,
			.bytes       = PCM_RING_BYTES,
		};
		if (copy_to_user((void __user *)arg, &info, sizeof(info)))
			return -EFAULT;
		return 0;
	}

	case SNDCTL_DSP_RESET:
	case SNDCTL_DSP_SYNC:
	case SNDCTL_DSP_POST:
		return 0;			/* nothing buffered on our side */

	default:
		return -EINVAL;
	}
}

static const struct file_operations dsp_fops = {
	.owner		= THIS_MODULE,
	.write		= dsp_write,
	.unlocked_ioctl	= dsp_ioctl,
};

static struct miscdevice dsp_dev = {
	.minor	= MISC_DYNAMIC_MINOR,
	.name	= "dsp",
	.fops	= &dsp_fops,
	.mode	= 0666,
};

/* ------------------------------------------------------------------ /dev/opl */

static ssize_t opl_write(struct file *f, const char __user *buf, size_t count,
			 loff_t *ppos)
{
	size_t done = 0;

	count &= ~(size_t)3;			/* whole u32 words only */
	if (count == 0)
		return 0;

	while (done < count) {
		u32 packed;

		if (get_user(packed, (const u32 __user *)(buf + done)))
			return done ? (ssize_t)done : -EFAULT;
		subleq_opl_write(packed);
		done += 4;
	}
	return done;
}

static const struct file_operations opl_fops = {
	.owner		= THIS_MODULE,
	.write		= opl_write,
};

static struct miscdevice opl_dev = {
	.minor	= MISC_DYNAMIC_MINOR,
	.name	= "opl",
	.fops	= &opl_fops,
	.mode	= 0666,
};

/* ---------------------------------------------------------------- init/exit */

static int __init subleq_sound_init(void)
{
	int ret;

	pcm_ring = kzalloc(PCM_RING_BYTES, GFP_KERNEL);
	if (!pcm_ring)
		return -ENOMEM;

	/*
	 * Program the card, then arm the ring LAST so the host never drains a
	 * half-configured buffer. pcm_write starts at 0 => nothing to drain
	 * until the first write().
	 */
	pcm_write_total = 0;
	subleq_pcm_set_rate(pcm_rate);
	subleq_pcm_set_frames(PCM_RING_FRAMES);
	subleq_pcm_set_write(0);
	subleq_pcm_set_base((unsigned long)__pa(pcm_ring) >> 2);

	ret = misc_register(&dsp_dev);
	if (ret)
		goto err_ring;

	ret = misc_register(&opl_dev);
	if (ret)
		goto err_dsp;

	pr_info("subleq_sound: /dev/dsp + /dev/opl ready (PCM ring %u frames @ %u Hz)\n",
		PCM_RING_FRAMES, pcm_rate);
	return 0;

err_dsp:
	misc_deregister(&dsp_dev);
err_ring:
	subleq_pcm_set_base(0);			/* disarm */
	kfree(pcm_ring);
	pcm_ring = NULL;
	return ret;
}

static void __exit subleq_sound_exit(void)
{
	subleq_pcm_set_base(0);			/* disarm the ring first */
	misc_deregister(&opl_dev);
	misc_deregister(&dsp_dev);
	kfree(pcm_ring);
	pcm_ring = NULL;
}

device_initcall(subleq_sound_init);
module_exit(subleq_sound_exit);

MODULE_DESCRIPTION("Subleq Virtual Machine Sound Driver (OPL3 + PCM)");
MODULE_LICENSE("GPL");
