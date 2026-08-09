// SPDX-License-Identifier: GPL-2.0
/*
 * am335xpm - userspace access to the AM335x control-module pinmux registers
 *
 * Exposes the AM335x pinctrl conf_<pad> register block (control module,
 * physical 0x44e10800..0x44e10a37) to userspace via a /dev/am335xpm character
 * device, so FPP can program pad mux/pull/input-enable at runtime instead of
 * pre-declaring every pin in every mode in the device tree (cape-universal)
 * and switching modes with bone-pinmux-helper / gpio-of-helper.
 *
 * Why a kernel module (and not /dev/mem):
 *   On the AM335x these control-module registers are a hardware-protected
 *   region that only accepts writes from privileged (kernel) bus accesses. A
 *   userspace store -- whether through /dev/mem or an mmap of this device --
 *   is a non-privileged access and is silently dropped. So the write MUST be
 *   executed by the kernel: userspace pwrite()s the value at the register
 *   offset and this driver's write handler performs the iowrite32. For that
 *   reason there is intentionally no mmap() here; it could not work for writes.
 *
 * Coexistence with pinctrl-single:
 *   The register window is mapped with a plain ioremap() and is deliberately
 *   NOT claimed with request_mem_region(), because the kernel's pinctrl-single
 *   driver (am33xx_pinmux: pinmux@800) already owns these same registers. A
 *   second, non-exclusive mapping lets both run side by side during the
 *   migration away from cape-universal. Caveat: for any pad FPP drives through
 *   this device, make sure no active pinctrl-single group still claims it, or
 *   pinctrl-single may overwrite the value.
 *
 * Portability:
 *   The control module is identical on BeagleBone Black and PocketBeagle (both
 *   AM335x), so the single device-tree node under &ocp in am33xx.dtsi binds on
 *   both boards with no per-board changes.
 *
 * Interface:
 *   read()/write() only. The conf_<pad> registers are 32-bit, so access is
 *   restricted to 4-byte aligned, 4-byte-multiple reads/writes
 *   (ioread32/iowrite32). Offset 0 == reg base == 0x44e10800.
 *   Example (set one pad): pwrite(fd, &u32val, 4, pad_offset).
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/device.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#define DEVICE_NAME "am335xpm"

struct am335xpm {
	void __iomem		*base;
	resource_size_t		size;
	int			major;
	struct class		*class;
	struct device		*dev;
};

/* Single SoC instance; set at probe, used by the file ops. */
static struct am335xpm *am335xpm;

static int am335xpm_open(struct inode *inode, struct file *file)
{
	file->private_data = am335xpm;
	return 0;
}

static int am335xpm_release(struct inode *inode, struct file *file)
{
	return 0;
}

static ssize_t am335xpm_read(struct file *file, char __user *buf,
			     size_t count, loff_t *ppos)
{
	struct am335xpm *pm = file->private_data;
	u32 *tmp;
	size_t i;

	if (*ppos >= pm->size)
		return 0;
	if ((*ppos % 4) || (count % 4))
		return -EINVAL;			/* 32-bit register access only */
	if (*ppos + count > pm->size)
		count = pm->size - (*ppos & ~3UL);

	tmp = kmalloc(count, GFP_KERNEL);
	if (!tmp)
		return -ENOMEM;

	for (i = 0; i < count / 4; i++)
		tmp[i] = ioread32(pm->base + *ppos + i * 4);

	if (copy_to_user(buf, tmp, count)) {
		kfree(tmp);
		return -EFAULT;
	}
	kfree(tmp);
	*ppos += count;
	return count;
}

static ssize_t am335xpm_write(struct file *file, const char __user *buf,
			      size_t count, loff_t *ppos)
{
	struct am335xpm *pm = file->private_data;
	u32 *tmp;
	size_t i;

	if (*ppos >= pm->size)
		return -ENOSPC;
	if ((*ppos % 4) || (count % 4))
		return -EINVAL;			/* 32-bit register access only */
	if (*ppos + count > pm->size)
		count = pm->size - *ppos;

	tmp = kmalloc(count, GFP_KERNEL);
	if (!tmp)
		return -ENOMEM;

	if (copy_from_user(tmp, buf, count)) {
		kfree(tmp);
		return -EFAULT;
	}

	for (i = 0; i < count / 4; i++)
		iowrite32(tmp[i], pm->base + *ppos + i * 4);

	kfree(tmp);
	*ppos += count;
	return count;
}

static loff_t am335xpm_llseek(struct file *file, loff_t off, int whence)
{
	struct am335xpm *pm = file->private_data;

	return fixed_size_llseek(file, off, whence, pm->size);
}

static const struct file_operations am335xpm_fops = {
	.owner		= THIS_MODULE,
	.open		= am335xpm_open,
	.release	= am335xpm_release,
	.read		= am335xpm_read,
	.write		= am335xpm_write,
	.llseek		= am335xpm_llseek,
};

static int am335xpm_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct am335xpm *pm;
	struct resource *res;

	pm = devm_kzalloc(dev, sizeof(*pm), GFP_KERNEL);
	if (!pm)
		return -ENOMEM;

	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	if (!res)
		return -EINVAL;
	pm->size = resource_size(res);

	/*
	 * Plain ioremap(), NOT devm_ioremap_resource(): the latter would
	 * request_mem_region() and fail with -EBUSY because pinctrl-single
	 * already owns this window. We intentionally share it.
	 */
	pm->base = ioremap(res->start, pm->size);
	if (!pm->base)
		return -ENOMEM;

	pm->major = register_chrdev(0, DEVICE_NAME, &am335xpm_fops);
	if (pm->major < 0) {
		iounmap(pm->base);
		return pm->major;
	}

	pm->class = class_create(DEVICE_NAME);
	if (IS_ERR(pm->class)) {
		unregister_chrdev(pm->major, DEVICE_NAME);
		iounmap(pm->base);
		return PTR_ERR(pm->class);
	}

	pm->dev = device_create(pm->class, NULL, MKDEV(pm->major, 0), NULL,
				DEVICE_NAME);
	if (IS_ERR(pm->dev)) {
		class_destroy(pm->class);
		unregister_chrdev(pm->major, DEVICE_NAME);
		iounmap(pm->base);
		return PTR_ERR(pm->dev);
	}

	platform_set_drvdata(pdev, pm);
	am335xpm = pm;

	dev_info(dev, "userspace pinmux at %pR via /dev/%s (shares pinctrl-single)\n",
		 res, DEVICE_NAME);
	return 0;
}

static void am335xpm_remove(struct platform_device *pdev)
{
	struct am335xpm *pm = platform_get_drvdata(pdev);

	device_destroy(pm->class, MKDEV(pm->major, 0));
	class_destroy(pm->class);
	unregister_chrdev(pm->major, DEVICE_NAME);
	iounmap(pm->base);
	am335xpm = NULL;
}

static const struct of_device_id am335xpm_of_match[] = {
	{ .compatible = "fpp,am335x-us-pinmux" },
	{ }
};
MODULE_DEVICE_TABLE(of, am335xpm_of_match);

static struct platform_driver am335xpm_driver = {
	.probe	= am335xpm_probe,
	.remove	= am335xpm_remove,
	.driver	= {
		.name		= DEVICE_NAME,
		.of_match_table	= am335xpm_of_match,
	},
};
module_platform_driver(am335xpm_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("JTBrooks; FPP / Daniel Kulp");
MODULE_DESCRIPTION("AM335x userspace pinmux register access (/dev/am335xpm)");
