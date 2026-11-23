/*
 * imei-tool - read/write the modem IMEI via the SMD DIAG channel.
 *
 * The UFI MF32 / MSM8916 modem stores the IMEI in NV item 550 (0x226).
 * Writes go through the DIAG NV write (opcode 0x27) which creates a file in
 * the EFS2 log-structured journal; a small delay lets the modem's garbage
 * collector commit it so the value survives a reboot.
 *
 * IMEI encoding in NV 550 (9 bytes):
 *   [0] = 0x08                      (length: 8 data bytes follow)
 *   [1] = (digit0 << 4) | 0xA       (first digit + filler nibble A)
 *   [2..8] = remaining 14 digits, TBCD (nibble-swapped pairs)
 *
 *   e.g. 868408030580779 -> 08 8A 86 04 08 03 85 70 97
 *
 * Frame format (verified against the device's diag_nv and the DIAG protocol):
 *   read/write command : cmd(1) + item(2, LE) + data(128)  = 131 bytes
 *   response           : cmd(1) + item(2, LE) + data(128) + status(2, LE)
 *                        status @ [131..132] (0x0000 = NV_DONE_S)
 */

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include <sys/wait.h>

#define DIAG_LOCK	"/var/lock/imei-diag.lock"

#define DIAG_NV_READ_F		0x26
#define DIAG_NV_WRITE_F		0x27

#define NV_ITEM_DATA_SIZE	128
#define NV_ITEM_PKT_SIZE	(1 + 2 + NV_ITEM_DATA_SIZE + 2)

#define NV_ITEM			550
#define NV_ITEM_DESC		"NV 550"

#define IMEI_DATA_LEN		9
#define IMEI_DIGITS		15

#define PERSIST_DELAY_SEC	6

static const char *g_dev = "/dev/rpmsg0";

struct nv_item {
	uint8_t data[NV_ITEM_DATA_SIZE];
	uint16_t status;
};

static int nv_transact(uint8_t cmd_byte, uint16_t item,
		       const uint8_t *data_in, struct nv_item *out)
{
	uint8_t buf[NV_ITEM_PKT_SIZE];
	uint8_t resp[NV_ITEM_PKT_SIZE + 16];
	ssize_t n, r;
	fd_set rfds;
	struct timeval tv;
	int fd, i, ret = -1;

	fd = open(g_dev, O_RDWR | O_NOCTTY);
	if (fd < 0) {
		fprintf(stderr, "open(%s): %s\n", g_dev, strerror(errno));
		return -1;
	}

	memset(buf, 0, sizeof(buf));
	buf[0] = cmd_byte;
	buf[1] = item & 0xFF;
	buf[2] = (item >> 8) & 0xFF;
	if (data_in)
		memcpy(&buf[3], data_in, NV_ITEM_DATA_SIZE);

	n = write(fd, buf, sizeof(buf));
	if (n != (ssize_t)sizeof(buf)) {
		fprintf(stderr, "write: %s\n", strerror(errno));
		close(fd);
		return -1;
	}

	memset(resp, 0, sizeof(resp));
	/* Poll for the reply; DIAG can be busy with other consumers. */
	for (i = 0; i < 20; i++) {
		FD_ZERO(&rfds);
		FD_SET(fd, &rfds);
		tv.tv_sec = 1;
		tv.tv_usec = 0;
		r = select(fd + 1, &rfds, NULL, NULL, &tv);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "select: %s\n", strerror(errno));
			close(fd);
			return -1;
		}
		if (r == 0)
			continue;
		n = read(fd, resp, sizeof(resp));
		if (n < 0) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "read: %s\n", strerror(errno));
			close(fd);
			return -1;
		}
		if (n > 0) {
			break;
		}
	}
	close(fd);

	if (n <= 0 || (size_t)n < NV_ITEM_PKT_SIZE) {
		fprintf(stderr, "%s: no 0x%02x reply (n=%zd)\n",
			NV_ITEM_DESC, cmd_byte, n);
		return -1;
	}
	if (resp[0] != (cmd_byte ^ 1)) {
		fprintf(stderr, "%s: bad reply cmd 0x%02x\n",
			NV_ITEM_DESC, resp[0]);
		return -1;
	}

	if (out) {
		memcpy(out->data, &resp[3], NV_ITEM_DATA_SIZE);
		out->status = resp[3 + NV_ITEM_DATA_SIZE] |
			      (resp[4 + NV_ITEM_DATA_SIZE] << 8);
	}
	return 0;
}

static int nv_read(uint16_t item, struct nv_item *out)
{
	return nv_transact(DIAG_NV_READ_F, item, NULL, out);
}

static int nv_write(uint16_t item, const uint8_t *data, size_t len)
{
	uint8_t buf[NV_ITEM_DATA_SIZE];
	struct nv_item check;

	memset(buf, 0, sizeof(buf));
	if (len > sizeof(buf))
		len = sizeof(buf);
	memcpy(buf, data, len);

	if (nv_transact(DIAG_NV_WRITE_F, item, buf, &check) < 0)
		return -1;
	if (check.status != 0) {
		fprintf(stderr, "%s: write status 0x%04x (SP locked?)\n",
			NV_ITEM_DESC, check.status);
		return -1;
	}

	/* Give the modem's GC time to commit the EFS2 journal. */
	sleep(PERSIST_DELAY_SEC);

	if (nv_read(item, &check) < 0)
		return -1;
	if (memcmp(check.data, data, len) != 0) {
		fprintf(stderr, "%s: verify mismatch\n", NV_ITEM_DESC);
		return -1;
	}
	return 0;
}

/*
 * IMEI <-> 9-byte NV encoding.
 *   enc[0]=0x08, enc[1]=(d0<<4)|0xA, enc[2..8]=TBCD(d1..d14)
 */
static int imei_encode(const char *imei, uint8_t out[IMEI_DATA_LEN])
{
	int len = strlen(imei);
	int i;

	if (len != IMEI_DIGITS) {
		fprintf(stderr, "IMEI must be %d digits, got %d\n",
			IMEI_DIGITS, len);
		return -1;
	}
	for (i = 0; i < len; i++) {
		if (imei[i] < '0' || imei[i] > '9') {
			fprintf(stderr, "IMEI has non-digit '%c'\n", imei[i]);
			return -1;
		}
	}

	memset(out, 0, IMEI_DATA_LEN);
	out[0] = 0x08;
	out[1] = ((imei[0] - '0') << 4) | 0xA;
	/*
	 * TBCD: low nibble is the earlier digit, high nibble the later one.
	 *   enc[2] = (imei[2] << 4) | imei[1]   (positions 2 and 3)
	 *   enc[3] = (imei[4] << 4) | imei[3]   (positions 4 and 5)
	 */
	for (i = 1; i < 15; i += 2) {
		uint8_t hi = imei[i + 1] - '0';
		uint8_t lo = imei[i] - '0';
		out[1 + (i + 1) / 2] = (hi << 4) | lo;
	}
	return 0;
}

static int imei_decode(const uint8_t enc[IMEI_DATA_LEN], char out[IMEI_DIGITS + 1])
{
	int i;

	if (enc[0] != 0x08) {
		fprintf(stderr, "%s: bad length 0x%02x (not an IMEI)\n",
			NV_ITEM_DESC, enc[0]);
		return -1;
	}

	out[0] = '0' + ((enc[1] >> 4) & 0xF);
	for (i = 1; i < 15; i += 2) {
		uint8_t b = enc[1 + (i + 1) / 2];
		out[i] = '0' + (b & 0xF);		/* low nibble first */
		out[i + 1] = '0' + ((b >> 4) & 0xF);
	}
	out[IMEI_DIGITS] = '\0';
	return 0;
}

static int check_imei_valid(const char *imei)
{
	int len = strlen(imei);
	int i, sum = 0, double_flag = 1;

	if (len != IMEI_DIGITS)
		return -1;
	for (i = 0; i < len; i++)
		if (imei[i] < '0' || imei[i] > '9')
			return -1;

	/* Luhn check on the first 14 digits; digit 15 is the check digit. */
	for (i = len - 2; i >= 0; i--) {
		int d = imei[i] - '0';
		if (double_flag) {
			d *= 2;
			if (d > 9)
				d -= 9;
		}
		sum += d;
		double_flag = !double_flag;
	}
	return (sum + (imei[len - 1] - '0')) % 10 == 0 ? 0 : -1;
}

static int qmi_get_imei(char *out, size_t outsz)
{
	FILE *fp;
	char line[256];
	char *p;
	int found = 0;

	fp = popen("qmicli -d /dev/wwan0qmi0 -p --dms-get-ids 2>&1", "r");
	if (!fp)
		return -1;
	while (fgets(line, sizeof(line), fp)) {
		if ((p = strstr(line, "IMEI:")) != NULL) {
			size_t len;
			p += 5;
			while (*p == ' ' || *p == '\t' || *p == '\'' ||
			       *p == '"')
				p++;
			len = strcspn(p, "'\"\r\n \t");
			if (len >= outsz)
				len = outsz - 1;
			memcpy(out, p, len);
			out[len] = '\0';
			found = 1;
			break;
		}
	}
	pclose(fp);
	return found ? 0 : -1;
}

static int cmd_get(void)
{
	struct nv_item item;
	char imei[IMEI_DIGITS + 1];

	if (nv_read(NV_ITEM, &item) < 0)
		return 1;
	if (item.status != 0) {
		printf("%s status=0x%04x (not active)\n", NV_ITEM_DESC,
		       item.status);
		return 1;
	}
	if (imei_decode(item.data, imei) < 0) {
		printf("%s data not an IMEI: ", NV_ITEM_DESC);
		for (int i = 0; i < 9; i++)
			printf("%02x", item.data[i]);
		printf("\n");
		return 1;
	}
	printf("%s\n", imei);
	return 0;
}

static int cmd_set(const char *imei)
{
	uint8_t enc[IMEI_DATA_LEN];
	struct nv_item check;
	char dec[IMEI_DIGITS + 1];

	if (check_imei_valid(imei) < 0) {
		fprintf(stderr, "IMEI failed Luhn check\n");
		return 1;
	}
	if (imei_encode(imei, enc) < 0)
		return 1;

	if (nv_write(NV_ITEM, enc, sizeof(enc)) < 0)
		return 1;

	if (nv_read(NV_ITEM, &check) < 0)
		return 1;
	if (check.status != 0 || imei_decode(check.data, dec) < 0) {
		fprintf(stderr, "%s: read-back failed\n", NV_ITEM_DESC);
		return 1;
	}

	printf("IMEI written and persisted: %s\n", dec);
	if (qmi_get_imei(dec, sizeof(dec)) == 0)
		printf("QMI reports: %s", dec);
	return 0;
}

static int cmd_verify(void)
{
	struct nv_item item;
	char nv[IMEI_DIGITS + 1];
	char qmi[IMEI_DIGITS + 4];

	if (nv_read(NV_ITEM, &item) < 0)
		return 1;
	if (item.status != 0 || imei_decode(item.data, nv) < 0) {
		printf("%s: no IMEI stored\n", NV_ITEM_DESC);
		return 1;
	}
	printf("NV 550: %s\n", nv);
	if (qmi_get_imei(qmi, sizeof(qmi)) == 0)
		printf("QMI:    %s", qmi);
	else
		printf("QMI:    (unavailable)\n");
	return 0;
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"Usage: %s {get | set <imei> | verify}\n"
		"\n"
		"Read or write the modem IMEI (NV item %d) via %s.\n"
		"\n"
		"Commands:\n"
		"  get              Print the stored IMEI\n"
		"  set <imei>       Write IMEI (Luhn-validated) and persist it\n"
		"  verify           Show NV IMEI and the QMI-reported IMEI\n"
		"\n"
		"Requires the DIAG bridge: run 'diag-bind' first (or the\n"
		"diag-bind service) so /dev/rpmsg0 exists.\n"
		"IMEI is stored in NV item %d (0x%x).\n",
		prog, NV_ITEM, g_dev, NV_ITEM, NV_ITEM);
}

int main(int argc, char **argv)
{
	int lfd;

	if (argc < 2) {
		usage(argv[0]);
		return 1;
	}

	/*
	 * Serialize DIAG users: /dev/rpmsg0 is exclusive-open and a second
	 * concurrent instance would block indefinitely.  The lock is held for
	 * the whole run; the kernel releases it if we crash.
	 */
	lfd = open(DIAG_LOCK, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
	if (lfd >= 0) {
		flock(lfd, LOCK_EX);
		ftruncate(lfd, 0);
		dprintf(lfd, "%d\n", (int)getpid());
	}

	if (!strcmp(argv[1], "get"))
		return cmd_get();
	if (!strcmp(argv[1], "set") && argc >= 3)
		return cmd_set(argv[2]);
	if (!strcmp(argv[1], "verify"))
		return cmd_verify();

	usage(argv[0]);
	return 1;
}
