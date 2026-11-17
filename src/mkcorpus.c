/*
 * mkcorpus: write resident anonymous pages of running processes to a file,
 * for zbench to replay.  Benchmarking compression on made-up data says
 * little; this takes the bytes real programs keep in memory.
 *
 *   mkcorpus -o file [-n total_pages] [-p pages_per_process] [-P pid]...
 *   mkcorpus -o file [-n total_pages] -i file_or_block_device
 *
 * Only pages pagemap reports present are read, so nothing is swapped back in
 * for it.  Each process gives at most -p pages (default 2048), taken evenly
 * across its private writable anonymous mappings, until -n pages (default
 * 32768) are written.  -P limits it to the given processes.  Run as root.
 *
 * -i takes the pages from a file or a block device instead: a dump of a zram
 * device, or the live system zram itself (/dev/block/zram0), whose pages are
 * the ones reclaim actually chose to swap out.  Same-filled pages, which zram
 * does not compress, and the empty slots of a device, which read back as
 * zeros, are left out.  The pages are taken evenly across the whole source;
 * when too few of them are usable, the gaps are filled in on later passes.
 * A device is read with O_DIRECT, so that its page cache stays as it was.
 *
 * The file holds other programs' memory: passwords, messages, keys.  It is
 * created readable by root only.  Keep it on the device and delete it after.
 */
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

static size_t pg;

struct vec {
	uint64_t *v;
	size_t n, cap;
};

static void push(struct vec *a, uint64_t x)
{
	if (a->n == a->cap) {
		a->cap = a->cap ? a->cap * 2 : 4096;
		a->v = realloc(a->v, a->cap * sizeof(*a->v));
		if (!a->v) {
			fprintf(stderr, "mkcorpus: out of memory\n");
			exit(1);
		}
	}
	a->v[a->n++] = x;
}

static int cmp_u64(const void *a, const void *b)
{
	uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;

	return x < y ? -1 : x > y;
}

static int same_filled(const void *p)
{
	const unsigned long *w = p;

	for (size_t i = 1; i < pg / sizeof(*w); i++)
		if (w[i] != w[0])
			return 0;
	return 1;
}

/* Addresses of the present pages in @pid's private anonymous memory. */
static void present_pages(int pid, struct vec *out)
{
	char path[64], line[1024];
	uint64_t ent[4096];
	FILE *maps;
	int pm;

	out->n = 0;
	snprintf(path, sizeof(path), "/proc/%d/maps", pid);
	maps = fopen(path, "r");
	if (!maps)
		return;
	snprintf(path, sizeof(path), "/proc/%d/pagemap", pid);
	pm = open(path, O_RDONLY);
	if (pm < 0) {
		fclose(maps);
		return;
	}
	while (fgets(line, sizeof(line), maps)) {
		unsigned long lo, hi;
		char perms[8], *name;
		int pos = 0;

		if (sscanf(line, "%lx-%lx %7s %*s %*s %*s %n", &lo, &hi, perms,
			   &pos) < 3 || !pos)
			continue;
		if (perms[1] != 'w' || perms[3] != 'p')
			continue;
		name = line + pos;
		name[strcspn(name, "\n")] = 0;
		if (*name && strncmp(name, "[anon", 5) &&
		    strcmp(name, "[heap]") && strcmp(name, "[stack]"))
			continue;
		for (uint64_t a = lo; a < hi; ) {
			size_t want = (hi - a) / pg;
			ssize_t r;

			if (want > 4096)
				want = 4096;
			r = pread(pm, ent, want * 8, (off_t)(a / pg) * 8);
			if (r <= 0)
				break;
			for (size_t i = 0; i < (size_t)r / 8; i++)
				if (ent[i] >> 63)
					push(out, a + i * pg);
			a += (uint64_t)(r / 8) * pg;
		}
	}
	close(pm);
	fclose(maps);
}

#ifndef BLKGETSIZE64
#define BLKGETSIZE64 _IOR(0x12, 114, size_t)
#endif

/* Up to @total pages of @in that are not same-filled, to @fd. */
static int from_source(const char *in, int fd, const char *out, size_t total)
{
	size_t pages, step, done = 0, read_ = 0, same = 0;
	uint64_t bytes = 0;
	struct stat st;
	void *page;
	int src;

	src = open(in, O_RDONLY | O_DIRECT);
	if (src < 0)
		src = open(in, O_RDONLY);
	if (src < 0 || fstat(src, &st)) {
		perror(in);
		return 1;
	}
	if (S_ISBLK(st.st_mode)) {
		if (ioctl(src, BLKGETSIZE64, &bytes)) {
			perror(in);
			return 1;
		}
	} else {
		bytes = st.st_size;
	}
	pages = bytes / pg;
	if (posix_memalign(&page, pg, pg)) {
		fprintf(stderr, "mkcorpus: out of memory\n");
		return 1;
	}
	step = pages / total > 1 ? pages / total : 1;
	/* Pass k reads pages k, k + step, k + 2 * step, ... */
	for (size_t k = 0; k < step && done < total; k++) {
		for (size_t i = k; i < pages && done < total; i += step) {
			if (pread(src, page, pg, (off_t)i * pg) != (ssize_t)pg)
				continue;
			read_++;
			if (same_filled(page)) {
				same++;
				continue;
			}
			if (write(fd, page, pg) != (ssize_t)pg) {
				perror(out);
				return 1;
			}
			done++;
		}
	}
	close(src);
	if (close(fd)) {
		perror(out);
		return 1;
	}
	printf("mkcorpus: wrote %zu pages of %zu bytes from %s (%zu pages, %zu read, %zu same-filled left out) to %s\n",
	       done, pg, in, pages, read_, same, out);
	if (!done) {
		fprintf(stderr, "mkcorpus: no usable page in %s\n", in);
		return 1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	size_t total = 32768, per = 2048, done = 0, procs = 0, same = 0;
	struct vec pids = { 0 }, only = { 0 }, addrs = { 0 };
	const char *out = NULL, *in = NULL;
	struct dirent *de;
	char *page;
	int opt, fd;
	DIR *d;

	pg = sysconf(_SC_PAGESIZE);
	while ((opt = getopt(argc, argv, "o:n:p:P:i:")) != -1) {
		switch (opt) {
		case 'o': out = optarg; break;
		case 'n': total = strtoul(optarg, NULL, 0); break;
		case 'p': per = strtoul(optarg, NULL, 0); break;
		case 'P': push(&only, strtoul(optarg, NULL, 0)); break;
		case 'i': in = optarg; break;
		default: out = NULL; optind = argc; break;
		}
	}
	if (!out || optind != argc || !total || !per) {
		fprintf(stderr, "usage: mkcorpus -o file [-n total_pages] [-p pages_per_process] [-P pid]...\n"
				"       mkcorpus -o file [-n total_pages] -i file_or_block_device\n");
		return 1;
	}

	if (in) {
		struct stat a, b;

		/* O_TRUNC below would empty the source first. */
		if (!stat(in, &a) && !stat(out, &b) && a.st_dev == b.st_dev &&
		    a.st_ino == b.st_ino) {
			fprintf(stderr, "mkcorpus: %s is the source itself\n", out);
			return 1;
		}
	} else if (only.n) {
		pids = only;
	} else {
		d = opendir("/proc");
		if (!d) {
			perror("/proc");
			return 1;
		}
		while ((de = readdir(d)))
			if (isdigit((unsigned char)de->d_name[0]))
				push(&pids, strtoul(de->d_name, NULL, 10));
		closedir(d);
	}
	qsort(pids.v, pids.n, sizeof(*pids.v), cmp_u64);

	/* Never through a link someone left there, never readable by others. */
	fd = open(out, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
	if (fd < 0 || fchmod(fd, 0600)) {
		perror(out);
		return 1;
	}
	if (in)
		return from_source(in, fd, out, total);
	page = malloc(pg);
	for (size_t i = 0; i < pids.n && done < total; i++) {
		int pid = pids.v[i], mem;
		size_t want, got = 0;
		char path[64];

		if (pid == getpid())
			continue;
		present_pages(pid, &addrs);
		if (!addrs.n)
			continue;
		snprintf(path, sizeof(path), "/proc/%d/mem", pid);
		mem = open(path, O_RDONLY);
		if (mem < 0)
			continue;
		want = addrs.n < per ? addrs.n : per;
		if (want > total - done)
			want = total - done;
		for (size_t k = 0; k < want; k++) {
			uint64_t a = addrs.v[(uint64_t)k * addrs.n / want];

			if (pread(mem, page, pg, (off_t)a) != (ssize_t)pg)
				continue;
			if (write(fd, page, pg) != (ssize_t)pg) {
				perror(out);
				return 1;
			}
			same += same_filled(page);
			got++;
		}
		close(mem);
		if (got) {
			procs++;
			done += got;
		}
	}
	if (close(fd)) {
		perror(out);
		return 1;
	}
	printf("mkcorpus: wrote %zu pages (%zu same-filled) of %zu bytes from %zu processes to %s\n",
	       done, same, pg, procs, out);
	if (!done) {
		fprintf(stderr, "mkcorpus: no page could be read; run as root, and check any -P pid\n");
		return 1;
	}
	return 0;
}
