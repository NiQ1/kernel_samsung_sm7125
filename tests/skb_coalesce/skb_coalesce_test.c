// SPDX-License-Identifier: GPL-2.0
/*
 * skb_coalesce_test - exercise skb_try_coalesce() on normal input.
 *
 * skb_try_coalesce() merges one sk_buff into another on the TCP receive
 * path. The Fragnesia fix (apply_security_fixes.sh, "fragnesia") adds one
 * line to it: when paged fragments are moved, the SKBTX_SHARED_FRAG bit of
 * the source is OR'd into the destination.
 *
 * This module does NOT attack anything. It builds a couple of ordinary
 * skbs, coalesces them the way the stack does, and checks that:
 *   - the tailroom-copy path still appends bytes and reports no new truesize;
 *   - the fragment-move path still moves frags and preserves the bytes;
 *   - the shared-frag marker is carried over (the behaviour the fix adds)
 *     and is NOT invented when the source never had it;
 *   - a cloned destination is still refused.
 *
 * Load it on a phone running the kernel under test and read dmesg:
 *   insmod skb_coalesce_test.ko ; dmesg | tail ; rmmod skb_coalesce_test
 *
 * Every assertion but the two marked [fix] passes on a stock kernel too;
 * those two are what tells a patched kernel from an unpatched one.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/gfp.h>
#include <linux/mm.h>
#include <linux/skbuff.h>
#include <linux/slab.h>

#define TAG "skb_coalesce_test: "

static int passed, failed;

static void check(bool ok, const char *what)
{
	if (ok) {
		passed++;
		pr_info(TAG "PASS  %s\n", what);
	} else {
		failed++;
		pr_err(TAG "FAIL  %s\n", what);
	}
}

/* Linear skb of capacity cap with len bytes of data[i] = (u8)(seed + i). */
static struct sk_buff *make_linear(unsigned int cap, unsigned int len, u8 seed)
{
	struct sk_buff *skb = alloc_skb(cap, GFP_KERNEL);
	unsigned int i;
	u8 *p;

	if (!skb)
		return NULL;
	p = skb_put(skb, len);
	for (i = 0; i < len; i++)
		p[i] = (u8)(seed + i);
	return skb;
}

/* Nonlinear skb: empty head, one page fragment of size bytes = (u8)(seed+i). */
static struct sk_buff *make_frag(unsigned int size, u8 seed)
{
	struct sk_buff *skb = alloc_skb(64, GFP_KERNEL);
	struct page *page;
	unsigned int i;
	u8 *vaddr;

	if (!skb)
		return NULL;
	page = alloc_page(GFP_KERNEL);
	if (!page) {
		kfree_skb(skb);
		return NULL;
	}
	vaddr = page_address(page);
	for (i = 0; i < size; i++)
		vaddr[i] = (u8)(seed + i);

	skb_fill_page_desc(skb, 0, page, 0, size);
	skb->len += size;
	skb->data_len += size;
	skb->truesize += PAGE_SIZE;
	return skb;
}

/* Does skb hold len bytes equal to (u8)(seed + i) starting at off? */
static bool bytes_ok(struct sk_buff *skb, unsigned int off, unsigned int len, u8 seed)
{
	u8 *buf = kmalloc(len, GFP_KERNEL);
	bool ok = true;
	unsigned int i;

	if (!buf)
		return false;
	if (skb_copy_bits(skb, off, buf, len) < 0) {
		kfree(buf);
		return false;
	}
	for (i = 0; i < len; i++) {
		if (buf[i] != (u8)(seed + i)) {
			ok = false;
			break;
		}
	}
	kfree(buf);
	return ok;
}

static bool shared(const struct sk_buff *skb)
{
	return skb_shinfo(skb)->tx_flags & SKBTX_SHARED_FRAG;
}

/* from->len fits in to's tailroom: bytes are copied in, no frags move. */
static void test_tailroom_copy(void)
{
	struct sk_buff *to, *from;
	int delta = -1;
	bool fragstolen = true, ret;

	to = make_linear(512, 100, 0x10);
	from = make_linear(64, 60, 0x80);
	if (!to || !from) {
		check(false, "tailroom-copy: setup");
		goto out;
	}
	if (from->len > skb_tailroom(to)) {
		check(false, "tailroom-copy: precondition (from fits in tailroom)");
		goto out;
	}

	ret = skb_try_coalesce(to, from, &fragstolen, &delta);
	check(ret, "tailroom-copy: coalesce succeeds");
	check(!fragstolen, "tailroom-copy: no frags stolen");
	check(delta == 0, "tailroom-copy: delta_truesize is 0");
	check(to->len == 160, "tailroom-copy: combined length");
	check(bytes_ok(to, 0, 100, 0x10), "tailroom-copy: original bytes intact");
	check(bytes_ok(to, 100, 60, 0x80), "tailroom-copy: appended bytes correct");
out:
	/* fragstolen is false here, so from still owns its data. */
	kfree_skb(from);
	kfree_skb(to);
}

/* from does not fit in tailroom: its page frag is moved into to. The source
 * has no shared-frag marker, so the destination must not gain one. */
static void test_frag_move(void)
{
	struct sk_buff *to, *from;
	int delta = -1;
	bool fragstolen = true, ret;

	to = make_frag(256, 0x20);
	from = make_frag(2048, 0xA0);
	if (!to || !from) {
		check(false, "frag-move: setup");
		goto out;
	}
	if (from->len <= skb_tailroom(to)) {
		check(false, "frag-move: precondition (from exceeds tailroom)");
		goto out;
	}

	ret = skb_try_coalesce(to, from, &fragstolen, &delta);
	check(ret, "frag-move: coalesce succeeds");
	check(skb_shinfo(to)->nr_frags == 2, "frag-move: frag was moved over");
	check(to->len == 256 + 2048, "frag-move: combined length");
	check(delta > 0, "frag-move: delta_truesize accounted");
	check(bytes_ok(to, 0, 256, 0x20), "frag-move: destination bytes intact");
	check(bytes_ok(to, 256, 2048, 0xA0), "frag-move: moved bytes correct");
	check(!shared(to), "frag-move: no shared marker invented [fix]");
out:
	kfree_skb(from);
	kfree_skb(to);
}

/* Same as frag-move, but the source carries SKBTX_SHARED_FRAG (as a page a
 * zero-copy/sendpage sender contributed would). The marker must survive. */
static void test_shared_marker(void)
{
	struct sk_buff *to, *from;
	int delta = -1;
	bool fragstolen = true, ret;

	to = make_frag(256, 0x30);
	from = make_frag(2048, 0xB0);
	if (!to || !from) {
		check(false, "shared-marker: setup");
		goto out;
	}
	skb_shinfo(from)->tx_flags |= SKBTX_SHARED_FRAG;

	ret = skb_try_coalesce(to, from, &fragstolen, &delta);
	check(ret, "shared-marker: coalesce succeeds");
	check(bytes_ok(to, 256, 2048, 0xB0), "shared-marker: moved bytes correct");
	check(shared(to), "shared-marker: marker carried to destination [fix]");
out:
	kfree_skb(from);
	kfree_skb(to);
}

/* A cloned destination must be refused: its data is shared and cannot grow. */
static void test_cloned_refused(void)
{
	struct sk_buff *to, *from, *clone = NULL;
	int delta = -1;
	bool fragstolen = true, ret;

	to = make_frag(256, 0x40);
	from = make_frag(2048, 0xC0);
	if (!to || !from) {
		check(false, "cloned-refused: setup");
		goto out;
	}
	clone = skb_clone(to, GFP_KERNEL);
	if (!clone) {
		check(false, "cloned-refused: clone");
		goto out;
	}

	ret = skb_try_coalesce(to, from, &fragstolen, &delta);
	check(!ret, "cloned-refused: coalesce refused");
	check(skb_shinfo(to)->nr_frags == 1, "cloned-refused: destination untouched");
	check(from->len == 2048, "cloned-refused: source untouched");
out:
	kfree_skb(from);
	kfree_skb(clone);
	kfree_skb(to);
}

static int __init skb_coalesce_test_init(void)
{
	pr_info(TAG "starting\n");
	test_tailroom_copy();
	test_frag_move();
	test_shared_marker();
	test_cloned_refused();
	pr_info(TAG "done: %d passed, %d failed\n", passed, failed);

	/* Non-zero unloads the module right away and makes insmod report the
	 * failure; zero keeps it loaded so you can rmmod it yourself. */
	return failed ? -EINVAL : 0;
}

static void __exit skb_coalesce_test_exit(void)
{
}

module_init(skb_coalesce_test_init);
module_exit(skb_coalesce_test_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Normal-path functional test for skb_try_coalesce()");
