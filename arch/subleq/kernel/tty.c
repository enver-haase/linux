// SPDX-License-Identifier: GPL-2.0
/*
 * Subleq TTY driver
 *
 * Minimal TTY driver that provides /dev/console support using
 * the Subleq VM's putchar/getchar intrinsics.
 */

#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/tty.h>
#include <linux/tty_driver.h>
#include <linux/tty_flip.h>
#include <linux/console.h>
#include <linux/serial_core.h>
#include <linux/timer.h>
#include <linux/jiffies.h>

#define SUBLEQ_TTY_MAJOR 5 /* Same as /dev/console */
#define SUBLEQ_TTY_MINOR 1
#define SUBLEQ_TTY_NAME "console"

/* No polling - keyboard.c handles input */

/* External I/O intrinsics from compiler */
extern void __subleq_putchar(int c);
extern int __subleq_getchar(void);

/* Forward declarations */
void subleq_tty_inject_char(unsigned char c);
void subleq_tty_push(void);

static struct tty_driver *subleq_tty_driver;
static struct tty_port subleq_tty_port;
static struct tty_struct *subleq_tty_current;

/*
 * Inject a character from keyboard.c into the TTY layer.
 * Does NOT push the flip buffer — caller must call subleq_tty_push()
 * once after injecting a batch of characters.
 */
void subleq_tty_inject_char(unsigned char c)
{
	if (subleq_tty_current)
		tty_insert_flip_char(&subleq_tty_port, c, TTY_NORMAL);
}

/*
 * Flush the TTY flip buffer after a batch of injected characters.
 * Called once per keyboard poll cycle, not per character.
 */
void subleq_tty_push(void)
{
	if (subleq_tty_current)
		tty_flip_buffer_push(&subleq_tty_port);
}



/*
 * TTY operations
 */
static int subleq_tty_open(struct tty_struct *tty, struct file *filp)
{
	return tty_port_open(&subleq_tty_port, tty, filp);
}

static void subleq_tty_close(struct tty_struct *tty, struct file *filp)
{
	tty_port_close(&subleq_tty_port, tty, filp);
}

static ssize_t subleq_tty_write(struct tty_struct *tty, const u8 *buf,
				size_t count)
{
	/* n_tty already handles OPOST/ONLCR; expanding here would double \r */
	for (size_t i = 0; i < count; i++)
		__subleq_putchar(buf[i]);

	return count;
}

static unsigned int subleq_tty_write_room(struct tty_struct *tty)
{
	/* We can always accept more data */
	return 65536;
}

static void subleq_tty_hangup(struct tty_struct *tty)
{
	tty_port_hangup(&subleq_tty_port);
}

static const struct tty_operations subleq_tty_ops = {
	.open = subleq_tty_open,
	.close = subleq_tty_close,
	.write = subleq_tty_write,
	.write_room = subleq_tty_write_room,
	.hangup = subleq_tty_hangup,
};

/*
 * TTY port operations
 */
static int subleq_tty_port_activate(struct tty_port *port,
				    struct tty_struct *tty)
{
	/* Save reference to current TTY for input injection */
	subleq_tty_current = tty;
	return 0;
}

static void subleq_tty_port_shutdown(struct tty_port *port)
{
	/* Clear TTY reference */
	subleq_tty_current = NULL;
}

static const struct tty_port_operations subleq_tty_port_ops = {
	.activate = subleq_tty_port_activate,
	.shutdown = subleq_tty_port_shutdown,
};

/*
 * Console operations - allows this driver to be used as the console
 */
static void subleq_console_write(struct console *co, const char *s,
				 unsigned int count)
{
	while (count--) {
		if (*s == '\n')
			__subleq_putchar('\r');
		__subleq_putchar(*s);
		s++;
	}
}

static struct tty_driver *subleq_console_device(struct console *co, int *index)
{
	*index = 0;
	return subleq_tty_driver;
}

static int subleq_console_setup(struct console *co, char *options)
{
	return 0;
}

static struct console subleq_console = {
	.name = "ttyS",
	.write = subleq_console_write,
	.device = subleq_console_device,
	.setup = subleq_console_setup,
	.flags = CON_PRINTBUFFER,
	.index = 0,
};

/*
 * Driver initialization
 */
static int __init subleq_tty_init(void)
{
	int ret;

	pr_info("subleq_tty: initializing\n");

	/* Allocate TTY driver */
	subleq_tty_driver = tty_alloc_driver(1, TTY_DRIVER_REAL_RAW);
	if (IS_ERR(subleq_tty_driver)) {
		pr_err("subleq_tty: failed to allocate driver\n");
		return PTR_ERR(subleq_tty_driver);
	}

	/* Initialize TTY port */
	tty_port_init(&subleq_tty_port);
	subleq_tty_port.ops = &subleq_tty_port_ops;

	/* Configure driver */
	subleq_tty_driver->driver_name = "subleq_tty";
	subleq_tty_driver->name = "ttyS";
	subleq_tty_driver->major = 4; /* TTY_MAJOR - for serial ports */
	subleq_tty_driver->minor_start = 64; /* ttyS0 starts at minor 64 */
	subleq_tty_driver->type = TTY_DRIVER_TYPE_SERIAL;
	subleq_tty_driver->subtype = SERIAL_TYPE_NORMAL;
	subleq_tty_driver->init_termios = tty_std_termios;
	subleq_tty_driver->init_termios.c_cflag = B9600 | CS8 | CREAD | HUPCL |
						  CLOCAL;

	tty_set_operations(subleq_tty_driver, &subleq_tty_ops);
	tty_port_link_device(&subleq_tty_port, subleq_tty_driver, 0);

	/* Register driver */
	ret = tty_register_driver(subleq_tty_driver);
	if (ret) {
		pr_err("subleq_tty: failed to register driver: %d\n", ret);
		tty_driver_kref_put(subleq_tty_driver);
		tty_port_destroy(&subleq_tty_port);
		return ret;
	}

	/* Register console */
	register_console(&subleq_console);

	/*
	 * Both consoles write to the same place (__subleq_putchar -> the host's stdout), so only
	 * one of them may be live. Which one depends on the command line: register_console()
	 * enables this console only if it was asked for (console=ttyS0). With console=tty0 it
	 * stays disabled, and muting the early console then takes every later printk off the host
	 * channel -- boot logs used to end at "subleq_tty: initializing", so a fault report after
	 * boot was visible only on the framebuffer, in a screenshot.
	 */
	if (subleq_console.flags & CON_ENABLED) {
		extern int subleq_early_disabled;
		subleq_early_disabled = 1;
	}

	pr_info("subleq_tty: registered, device ttyS0\n");
	return 0;
}

/*
 * Use device_initcall to ensure it runs early enough
 */
device_initcall(subleq_tty_init);
