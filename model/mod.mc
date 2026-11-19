// model — task records, filter/sort (idiomatic %C: char[..], receivers).
import "str";

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "host_time.h"

enum {
	TaskIdCap = 40,
	TaskTitleCap = 256,
	TaskCcCap = 160,
	StoreMaxTasks = 4096,
	FilterTextCap = 128,
	VisibleMax = StoreMaxTasks,
	AttnNamesMax = 64,
	AttnNameCap = 40
};

struct Task {
	char[..] id;
	char[..] status;
	char[..] title;
	char[..] cc;
	char[..] updated;
};

struct TaskStore {
	Task tasks[StoreMaxTasks];
	int count;
	int next_id;
	bool dirty;
};

struct ViewFilter {
	char[..] cc;
	char[..] text;
	bool show_complete;
};

/* Fixed status vocabulary. Set only via cycle / complete. */
static const char *g_statuses[] = {
	"A:Now",
	"B:Soon",
	"C:Later",
	"D:Waiting",
	"E:Complete",
	"F:Someday",
};

int model_status_count() {
	return (int)(sizeof(g_statuses) / sizeof(g_statuses[0]));
}

const char *model_status_at(int i) {
	if (i < 0 || i >= model_status_count()) {
		return "";
	}
	return g_statuses[i];
}

bool model_status_ok(const char[..] s) {
	if (len(s) == 0) {
		return false;
	}
	for (int i = 0; i < model_status_count(); i++) {
		if (str_eq_cstr(s, g_statuses[i])) {
			return true;
		}
	}
	return false;
}

int model_status_index(const char[..] s) {
	if (len(s) == 0) {
		return -1;
	}
	for (int i = 0; i < model_status_count(); i++) {
		if (str_eq_cstr(s, g_statuses[i])) {
			return i;
		}
	}
	return -1;
}

static bool field_set(char[..]* dst, const char[..] src) {
	return str_set(dst, src);
}

static bool field_set_cstr(char[..]* dst, const char *src) {
	return str_set(dst, str_from_cstr(src != NULL ? src : ""));
}

void (Task *t).clear() {
	str_free(&t.id);
	str_free(&t.status);
	str_free(&t.title);
	str_free(&t.cc);
	str_free(&t.updated);
}

void (Task *t).touch() {
	char buf[40] = {0};
	int64_t now = time(NULL);
	struct Q2Tm *tm = gmtime(&now);
	if (tm == NULL) {
		(void)field_set_cstr(&t.updated, "0");
		return;
	}
	snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02dZ",
		tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
		tm.tm_hour, tm.tm_min, tm.tm_sec);
	(void)field_set_cstr(&t.updated, buf);
}

/* Deep-copy src into dst (dst must be empty or cleared). */
static bool task_copy_into(Task *dst, const Task *src) {
	if (!field_set(&dst.id, src.id) ||
		!field_set(&dst.status, src.status) ||
		!field_set(&dst.title, src.title) ||
		!field_set(&dst.cc, src.cc) ||
		!field_set(&dst.updated, src.updated)) {
		dst.clear();
		return false;
	}
	return true;
}

void (TaskStore *store).init() {
	for (int i = 0; i < store.count; i++) {
		store.tasks[i].clear();
	}
	memset(store, 0, sizeof(*store));
	store.next_id = 1;
}

void (ViewFilter *f).init() {
	str_free(&f.cc);
	str_free(&f.text);
	memset(f, 0, sizeof(*f));
	f.show_complete = false;
}

Task *(TaskStore *store).get(int index) {
	if (index < 0 || index >= store.count) {
		return NULL;
	}
	return &store.tasks[index];
}

bool (TaskStore *store).add(const Task *src) {
	char idbuf[32] = {0};
	if (src == NULL || store.count >= StoreMaxTasks) {
		return false;
	}
	Task *t = &store.tasks[store.count];
	memset(t, 0, sizeof(*t));
	if (!task_copy_into(t, src)) {
		return false;
	}
	if (len(t.id) == 0) {
		snprintf(idbuf, sizeof(idbuf), "t%d", store.next_id);
		store.next_id++;
		if (!field_set_cstr(&t.id, idbuf)) {
			t.clear();
			return false;
		}
	} else if (len(t.id) > 1 && t.id[0] == 't') {
		int n = 0;
		if (sscanf(ptr(t.id) + 1, "%d", &n) == 1 && n >= store.next_id) {
			store.next_id = n + 1;
		}
	}
	if (len(t.status) == 0) {
		if (!field_set_cstr(&t.status, "A:Now")) {
			t.clear();
			return false;
		}
	}
	if (len(t.updated) == 0) {
		t.touch();
	}
	store.count++;
	store.dirty = true;
	return true;
}

bool (TaskStore *store).set_status(int index, const char[..] status) {
	Task *t = store.get(index);
	if (t == NULL || !model_status_ok(status)) {
		return false;
	}
	if (!field_set(&t.status, status)) {
		return false;
	}
	t.touch();
	store.dirty = true;
	return true;
}

bool (TaskStore *store).cycle_status(int index) {
	Task *t = store.get(index);
	int n = model_status_count();
	int tries = 0;
	if (t == NULL) {
		return false;
	}
	int i = model_status_index(t.status);
	if (i < 0) {
		i = 0;
	}
	do {
		i = (i + 1) % n;
		tries++;
	} while (tries < n && strcmp(g_statuses[i], "E:Complete") == 0);
	return store.set_status(index, str_from_cstr(g_statuses[i]));
}

bool (TaskStore *store).set_title(int index, const char[..] title) {
	Task *t = store.get(index);
	if (t == NULL) {
		return false;
	}
	if (!field_set(&t.title, title)) {
		return false;
	}
	t.touch();
	store.dirty = true;
	return true;
}

/* Attn: comma-separated short names; trim and join with ", ". */
static bool normalize_attn(char[..]* dst, const char[..] src) {
	char[..] out = str_empty();
	size_t i = 0;
	defer str_free(&out);
	while (i < len(src)) {
		size_t start = 0;
		size_t end = 0;
		const char[..] name = {0};
		while (i < len(src) && (src[i] == ' ' || src[i] == '\t')) {
			i++;
		}
		start = i;
		while (i < len(src) && src[i] != ',') {
			i++;
		}
		end = i;
		while (end > start && (src[end - 1] == ' ' || src[end - 1] == '\t')) {
			end--;
		}
		if (end > start) {
			name = src[start..end];
			if (len(out) > 0) {
				if (!str_append(&out, ", ") || !str_append(&out, name)) {
					return false;
				}
			} else if (!str_append(&out, name)) {
				return false;
			}
		}
		if (i < len(src) && src[i] == ',') {
			i++;
		}
	}
	return field_set(dst, out);
}

bool (TaskStore *store).set_cc(int index, const char[..] cc) {
	Task *t = store.get(index);
	if (t == NULL) {
		return false;
	}
	if (!normalize_attn(&t.cc, cc)) {
		return false;
	}
	t.touch();
	store.dirty = true;
	return true;
}

static char ascii_lower(char c) {
	if (c >= 'A' && c <= 'Z') {
		return (char)(c - 'A' + 'a');
	}
	return c;
}

static bool ascii_istartswith(const char[..] s, const char[..] prefix) {
	if (len(prefix) > len(s)) {
		return false;
	}
	for (size_t i = 0; i < len(prefix); i++) {
		if (ascii_lower(s[i]) != ascii_lower(prefix[i])) {
			return false;
		}
	}
	return true;
}

static bool ascii_ieq(const char[..] a, const char[..] b) {
	if (len(a) != len(b)) {
		return false;
	}
	for (size_t i = 0; i < len(a); i++) {
		if (ascii_lower(a[i]) != ascii_lower(b[i])) {
			return false;
		}
	}
	return true;
}

static bool ascii_icontains(const char[..] hay, const char[..] needle) {
	if (len(needle) == 0) {
		return true;
	}
	if (len(needle) > len(hay)) {
		return false;
	}
	for (size_t i = 0; i + len(needle) <= len(hay); i++) {
		size_t j = 0;
		for (; j < len(needle); j++) {
			if (ascii_lower(hay[i + j]) != ascii_lower(needle[j])) {
				break;
			}
		}
		if (j == len(needle)) {
			return true;
		}
	}
	return false;
}

struct AttnName {
	char[..] s;
};

static void attn_names_free(AttnName[..] names, int count) {
	for (int i = 0; i < count; i++) {
		str_free(&names[i].s);
	}
}

static int collect_attn_names(const TaskStore *store, AttnName[..] names) {
	int count = 0;
	if (store == NULL || ptr(names) == NULL) {
		return 0;
	}
	for (int ti = 0; ti < store.count; ti++) {
		const char[..] cc = store.tasks[ti].cc;
		size_t i = 0;
		while (i < len(cc)) {
			size_t start = 0;
			size_t end = 0;
			bool seen = false;
			while (i < len(cc) && (cc[i] == ' ' || cc[i] == '\t')) {
				i++;
			}
			start = i;
			while (i < len(cc) && cc[i] != ',') {
				i++;
			}
			end = i;
			while (end > start && (cc[end - 1] == ' ' || cc[end - 1] == '\t')) {
				end--;
			}
			if (end > start) {
				const char[..] nv = cc[start..end];
				for (int j = 0; j < count; j++) {
					if (ascii_ieq(names[j].s, nv)) {
						seen = true;
						break;
					}
				}
				if (!seen && count < (int)len(names)) {
					if (!field_set(&names[count].s, nv)) {
						attn_names_free(names, count);
						return 0;
					}
					count++;
				}
			}
			if (i < len(cc) && cc[i] == ',') {
				i++;
			}
		}
	}
	return count;
}

/* out is a writable fixed buffer view (e.g. ranged(stack, n)); uses cstr_write. */
bool (TaskStore *store).attn_complete(const char[..] prefix, char[..] out) {
	AttnName names[AttnNamesMax] = {0};
	int matches = 0;
	int first = -1;
	size_t common = 0;
	if (ptr(out) == NULL || cap(out) == 0) {
		return false;
	}
	int n = collect_attn_names(store, ranged(names, AttnNamesMax));
	defer attn_names_free(ranged(names, AttnNamesMax), n);
	for (int i = 0; i < n; i++) {
		const char[..] cand = names[i].s;
		if (!ascii_istartswith(cand, prefix)) {
			continue;
		}
		if (first < 0) {
			first = i;
			common = len(cand);
		} else {
			const char[..] a = names[first].s;
			size_t k = 0;
			while (k < common && k < len(a) && k < len(cand) &&
				ascii_lower(a[k]) == ascii_lower(cand[k])) {
				k++;
			}
			common = k;
		}
		matches++;
	}
	if (matches == 0 || first < 0) {
		return false;
	}
	if (matches == 1) {
		(void)cstr_write(out, names[first].s);
		return true;
	}
	{
		const char[..] a = names[first].s;
		if (common > len(a)) {
			common = len(a);
		}
		(void)cstr_write(out, a[0..common]);
		return common > len(prefix);
	}
}

static int status_rank(const char[..] s) {
	int i = model_status_index(s);
	if (i < 0) {
		return 100;
	}
	return i;
}

static int task_cmp(const Task *a, const Task *b) {
	int ra = status_rank(a.status);
	int rb = status_rank(b.status);
	if (ra != rb) {
		return ra - rb;
	}
	int c = str_cmp(a.cc, b.cc);
	if (c != 0) {
		return c;
	}
	return str_cmp(a.title, b.title);
}

void (TaskStore *store).sort() {
	if (store.count < 2) {
		return;
	}
	/* Assignment moves char[..] headers; ownership rides with the Task. */
	for (int i = 1; i < store.count; i++) {
		Task key = store.tasks[i];
		int j = i - 1;
		while (j >= 0 && task_cmp(&store.tasks[j], &key) > 0) {
			store.tasks[j + 1] = store.tasks[j];
			j--;
		}
		store.tasks[j + 1] = key;
	}
}

int (TaskStore *store).build_visible(ViewFilter *f, int[..] out) {
	int n = 0;
	int out_cap = (int)len(out);
	if (f == NULL || ptr(out) == NULL || out_cap <= 0) {
		return 0;
	}
	for (int i = 0; i < store.count && n < out_cap; i++) {
		Task *t = &store.tasks[i];
		if (!f.show_complete && str_eq_cstr(t.status, "E:Complete")) {
			continue;
		}
		if (len(f.cc) != 0 && !ascii_icontains(t.cc, f.cc)) {
			continue;
		}
		if (len(f.text) != 0) {
			if (!ascii_icontains(t.title, f.text) &&
				!ascii_icontains(t.cc, f.text) &&
				!ascii_icontains(t.status, f.text)) {
				continue;
			}
		}
		out[n++] = i;
	}
	return n;
}

/* Replace task at index with a deep copy of src (for LWW merge). */
bool (TaskStore *store).replace(int index, const Task *src) {
	if (src == NULL) {
		return false;
	}
	Task *t = store.get(index);
	if (t == NULL) {
		return false;
	}
	t.clear();
	if (!task_copy_into(t, src)) {
		return false;
	}
	store.dirty = true;
	return true;
}
