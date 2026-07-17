/* SPDX-License-Identifier: GPL-2.0 */
/*
 * User access for Subleq.
 *
 * CONFIG_MMU=n : user and kernel share one address space; access is trivial memcpy.
 * CONFIG_MMU=y : supervisor mode is identity-mapped and cannot dereference user
 *                virtual addresses, so uaccess software-walks current->mm's page table
 *                (mm/uaccess.c). See docs/mmu-port-plan.md step 8.
 */

#ifndef _ASM_SUBLEQ_UACCESS_H
#define _ASM_SUBLEQ_UACCESS_H

#include <linux/string.h>
#include <linux/errno.h>
#include <asm/extable.h>

#ifdef CONFIG_MMU

#include <asm/processor.h>	/* TASK_SIZE */

static inline int __access_ok(const void __user *ptr, unsigned long size)
{
	unsigned long addr = (unsigned long)ptr;

	return size <= TASK_SIZE && addr <= TASK_SIZE - size;
}
#define access_ok(addr, size) __access_ok((addr), (size))

/* Software page-table-walking copies, implemented in arch/subleq/mm/uaccess.c. */
extern unsigned long subleq_copy_from_user(void *to, const void __user *from,
					   unsigned long n);
extern unsigned long subleq_copy_to_user(void __user *to, const void *from,
					 unsigned long n);
extern unsigned long subleq_clear_user(void __user *to, unsigned long n);

static inline __must_check unsigned long
raw_copy_from_user(void *to, const void __user *from, unsigned long n)
{
	return subleq_copy_from_user(to, from, n);
}

static inline __must_check unsigned long
raw_copy_to_user(void __user *to, const void *from, unsigned long n)
{
	return subleq_copy_to_user(to, from, n);
}

static inline __must_check unsigned long __clear_user(void __user *to, unsigned long n)
{
	return subleq_clear_user(to, n);
}

static inline __must_check unsigned long clear_user(void __user *to, unsigned long n)
{
	if (!__access_ok(to, n))
		return n;
	return subleq_clear_user(to, n);
}

#define __get_user(x, ptr)						\
	({								\
		__typeof__(*(ptr)) __gu_val;				\
		unsigned long __gu_err =				\
			subleq_copy_from_user((void *)&__gu_val,	\
					      (const void __user *)(ptr), \
					      sizeof(*(ptr)));		\
		(x) = __gu_val;						\
		__gu_err ? -EFAULT : 0;					\
	})

#define __put_user(x, ptr)						\
	({								\
		__typeof__(*(ptr)) __pu_val = (x);			\
		unsigned long __pu_err =				\
			subleq_copy_to_user((void __user *)(ptr),	\
					    (const void *)&__pu_val,	\
					    sizeof(*(ptr)));		\
		__pu_err ? -EFAULT : 0;					\
	})

#define get_user(x, ptr)						\
	({								\
		int __g_ret;						\
		if (access_ok((ptr), sizeof(*(ptr)))) {			\
			__g_ret = __get_user((x), (ptr));		\
		} else {						\
			(x) = (__typeof__(*(ptr)))0;			\
			__g_ret = -EFAULT;				\
		}							\
		__g_ret;						\
	})

#define put_user(x, ptr)						\
	({								\
		access_ok((ptr), sizeof(*(ptr))) ?			\
			__put_user((x), (ptr)) : -EFAULT;		\
	})

/* Own string helpers (so lib/strncpy_from_user.c etc. are not built). */
#define __HAVE_ARCH_STRNCPY_FROM_USER
#define __HAVE_ARCH_STRNLEN_USER

static inline long strncpy_from_user(char *dst, const char __user *src, long count)
{
	long i;

	for (i = 0; i < count; i++) {
		char c;

		if (subleq_copy_from_user(&c, src + i, 1))
			return -EFAULT;
		dst[i] = c;
		if (!c)
			return i;
	}
	return count;
}

static inline long strnlen_user(const char __user *s, long n)
{
	long i;

	for (i = 0; i < n; i++) {
		char c;

		if (subleq_copy_from_user(&c, s + i, 1))
			return 0;	/* fault */
		if (!c)
			return i + 1;	/* includes the NUL */
	}
	return n + 1;			/* no NUL within n */
}

#else /* !CONFIG_MMU ------------------------------------------------------- */

/* NOMMU: user and kernel share the same address space. */

typedef struct {
	unsigned long seg;
} mm_segment_t;

#define KERNEL_DS ((mm_segment_t){ 0 })
#define USER_DS ((mm_segment_t){ 0 })

#define access_ok(addr, size) (1)

static inline bool __access_ok(const void __user *ptr, unsigned long size)
{
	return true;
}

static inline __must_check unsigned long
raw_copy_from_user(void *to, const void __user *from, unsigned long n)
{
	memcpy(to, (const void __force *)from, n);
	return 0;
}

static inline __must_check unsigned long
raw_copy_to_user(void __user *to, const void *from, unsigned long n)
{
	memcpy((void __force *)to, from, n);
	return 0;
}

#define __get_user(x, ptr)                                  \
	({                                                  \
		(x) = *(__typeof__(*(ptr)) __force *)(ptr); \
		0;                                          \
	})

#define __put_user(x, ptr)                                  \
	({                                                  \
		*(__typeof__(*(ptr)) __force *)(ptr) = (x); \
		0;                                          \
	})

#define get_user(x, ptr) __get_user(x, ptr)
#define put_user(x, ptr) __put_user(x, ptr)

#define __HAVE_ARCH_STRNCPY_FROM_USER
#define __HAVE_ARCH_STRNLEN_USER

static inline long strnlen_user(const char __user *s, long n)
{
	return strnlen((const char __force *)s, n) + 1;
}

static inline long strncpy_from_user(char *dst, const char __user *src,
				     long count)
{
	const char *s = (const char __force *)src;
	long res = 0;
	while (count-- > 0 && *s) {
		*dst++ = *s++;
		res++;
	}
	*dst = '\0';
	return res;
}

static inline __must_check unsigned long __must_check
__clear_user(void __user *to, unsigned long n)
{
	memset((void __force *)to, 0, n);
	return 0;
}

static inline __must_check unsigned long clear_user(void __user *to,
						    unsigned long n)
{
	return __clear_user(to, n);
}

#endif /* CONFIG_MMU */

#define INLINE_COPY_FROM_USER
#define INLINE_COPY_TO_USER

#endif /* _ASM_SUBLEQ_UACCESS_H */
