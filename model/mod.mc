// model — task records, enums, filter/sort.
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
	TaskStatusCap = 40,
	TaskCategoryCap = 40,
	TaskTitleCap = 256,
	TaskCcCap = 160,
	TaskDueCap = 40,
	TaskNotesCap = 1024,
	TaskUpdatedCap = 40,
	StoreMaxTasks = 4096,
	FilterTextCap = 128,
	VisibleMax = StoreMaxTasks
};

struct Task {
	char id[TaskIdCap];
	char status[TaskStatusCap];
	char category[TaskCategoryCap];
	char title[TaskTitleCap];
	char cc[TaskCcCap];
	char due[TaskDueCap];
	char notes[TaskNotesCap];
	char updated[TaskUpdatedCap];
};

struct TaskStore {
	Task tasks[StoreMaxTasks];
	int count;
	int next_id;
	bool dirty;
};

/* Fixed vocabularies (from the sheet data validations). Set only via cycle. */
static const char *g_statuses[] = {
	"A:Next",
	"B:Next",
	"C:Next",
	"D:Waiting:Followup",
	"D:Waiting:MyReview",
	"E:Complete",
	"F:Backlog",
	"G:FYI",
};

static const char *g_categories[] = {
	"Academics",
	"Student Affairs",
	"Faculty Affairs",
	"Community Affairs",
	"R&D",
	"Operations",
	"Other",
	"Personal",
};

int model_status_count() {
	return (int)(sizeof(g_statuses) / sizeof(g_statuses[0]));
}

int model_category_count() {
	return (int)(sizeof(g_categories) / sizeof(g_categories[0]));
}

const char *model_status_at(int i) {
	if (i < 0 || i >= model_status_count()) {
		return "";
	}
	return g_statuses[i];
}

const char *model_category_at(int i) {
	if (i < 0 || i >= model_category_count()) {
		return "";
	}
	return g_categories[i];
}

bool model_status_ok(const char *s) {
	int i = 0;
	const char[..] sv = str_from_cstr(s);
	if (len(sv) == 0) {
		return false;
	}
	for (; i < model_status_count(); i++) {
		if (str_eq_cstr(sv, g_statuses[i])) {
			return true;
		}
	}
	return false;
}

bool model_category_ok(const char *s) {
	int i = 0;
	const char[..] sv = str_from_cstr(s);
	if (len(sv) == 0) {
		return false;
	}
	for (; i < model_category_count(); i++) {
		if (str_eq_cstr(sv, g_categories[i])) {
			return true;
		}
	}
	return false;
}

int model_status_index(const char *s) {
	int i = 0;
	const char[..] sv = str_from_cstr(s);
	if (len(sv) == 0) {
		return -1;
	}
	for (; i < model_status_count(); i++) {
		if (str_eq_cstr(sv, g_statuses[i])) {
			return i;
		}
	}
	return -1;
}

int model_category_index(const char *s) {
	int i = 0;
	const char[..] sv = str_from_cstr(s);
	if (len(sv) == 0) {
		return -1;
	}
	for (; i < model_category_count(); i++) {
		if (str_eq_cstr(sv, g_categories[i])) {
			return i;
		}
	}
	return -1;
}

void model_init(TaskStore *store) {
	if (store == NULL) {
		return;
	}
	memset(store, 0, sizeof(*store));
	store.next_id = 1;
}

void model_touch(Task *t) {
	int64_t now = time(NULL);
	struct Q2Tm *tm = gmtime(&now);
	if (t == NULL) {
		return;
	}
	if (tm == NULL) {
		snprintf(t.updated, sizeof(t.updated), "0");
		return;
	}
	snprintf(t.updated, sizeof(t.updated), "%04d-%02d-%02dT%02d:%02d:%02dZ",
		tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
		tm.tm_hour, tm.tm_min, tm.tm_sec);
}

static void copy_field(char[..] dst, const char *src) {
	if (cap(dst) == 0 || ptr(dst) == NULL) {
		return;
	}
	size_t n = cap(dst);
	if (src == NULL) {
		(void)snprintf(ptr(dst), n, "%s", "");
		return;
	}
	(void)snprintf(ptr(dst), n, "%s", src);
}

void model_task_clear(Task *t) {
	if (t == NULL) {
		return;
	}
	memset(t, 0, sizeof(*t));
}

bool model_add(TaskStore *store, Task *src) {
	if (store == NULL || src == NULL || store.count >= StoreMaxTasks) {
		return false;
	}
	Task *t = &store.tasks[store.count];
	*t = *src;
	if (strlen(t.id) == 0) {
		snprintf(t.id, sizeof(t.id), "t%d", store.next_id);
		store.next_id++;
	} else {
		const char[..] idv = ranged(t.id, strlen(t.id));
		if (len(idv) > 1 && idv[0] == 't') {
			int n = 0;
			if (sscanf(ptr(idv) + 1, "%d", &n) == 1 && n >= store.next_id) {
				store.next_id = n + 1;
			}
		}
	}
	if (strlen(t.status) == 0) {
		copy_field(ranged(t.status, sizeof(t.status)), "A:Next");
	}
	if (strlen(t.category) == 0) {
		copy_field(ranged(t.category, sizeof(t.category)), "Other");
	}
	if (strlen(t.updated) == 0) {
		model_touch(t);
	}
	store.count++;
	store.dirty = true;
	return true;
}

Task *model_get(TaskStore *store, int index) {
	if (store == NULL || index < 0 || index >= store.count) {
		return NULL;
	}
	return &store.tasks[index];
}

bool model_set_status(TaskStore *store, int index, const char *status) {
	Task *t = model_get(store, index);
	if (t == NULL || !model_status_ok(status)) {
		return false;
	}
	copy_field(ranged(t.status, sizeof(t.status)), status);
	model_touch(t);
	store.dirty = true;
	return true;
}

/* Cycle among non-complete statuses so items don't vanish from the default view. */
bool model_cycle_status(TaskStore *store, int index) {
	Task *t = model_get(store, index);
	if (t == NULL) {
		return false;
	}
	int i = model_status_index(t.status);
	int n = model_status_count();
	int tries = 0;
	if (i < 0) {
		i = 0;
	}
	do {
		i = (i + 1) % n;
		tries++;
	} while (tries < n && strcmp(g_statuses[i], "E:Complete") == 0);
	return model_set_status(store, index, g_statuses[i]);
}

bool model_set_category(TaskStore *store, int index, const char *category) {
	Task *t = model_get(store, index);
	if (t == NULL || !model_category_ok(category)) {
		return false;
	}
	copy_field(ranged(t.category, sizeof(t.category)), category);
	model_touch(t);
	store.dirty = true;
	return true;
}

bool model_cycle_category(TaskStore *store, int index) {
	Task *t = model_get(store, index);
	if (t == NULL) {
		return false;
	}
	int i = model_category_index(t.category);
	if (i < 0) {
		i = 0;
	} else {
		i = (i + 1) % model_category_count();
	}
	return model_set_category(store, index, g_categories[i]);
}

bool model_set_title(TaskStore *store, int index, const char *title) {
	Task *t = model_get(store, index);
	if (t == NULL || title == NULL) {
		return false;
	}
	copy_field(ranged(t.title, sizeof(t.title)), title);
	model_touch(t);
	store.dirty = true;
	return true;
}

bool model_set_cc(TaskStore *store, int index, const char *cc) {
	Task *t = model_get(store, index);
	if (t == NULL) {
		return false;
	}
	copy_field(ranged(t.cc, sizeof(t.cc)), cc != NULL ? cc : "");
	model_touch(t);
	store.dirty = true;
	return true;
}

bool model_set_due(TaskStore *store, int index, const char *due) {
	Task *t = model_get(store, index);
	if (t == NULL) {
		return false;
	}
	copy_field(ranged(t.due, sizeof(t.due)), due != NULL ? due : "");
	model_touch(t);
	store.dirty = true;
	return true;
}

bool model_set_notes(TaskStore *store, int index, const char *notes) {
	Task *t = model_get(store, index);
	if (t == NULL) {
		return false;
	}
	copy_field(ranged(t.notes, sizeof(t.notes)), notes != NULL ? notes : "");
	model_touch(t);
	store.dirty = true;
	return true;
}

struct ViewFilter {
	char cc[TaskCcCap]; /* focus: substring match on CC / person */
	char text[FilterTextCap];
	bool show_complete;
};

void model_filter_init(ViewFilter *f) {
	if (f == NULL) {
		return;
	}
	memset(f, 0, sizeof(*f));
	f.show_complete = false;
}

static bool ascii_icontains(const char *hay, const char *needle) {
	const char[..] hv = str_from_cstr(hay);
	const char[..] nv = str_from_cstr(needle);
	size_t i = 0;
	if (len(nv) == 0) {
		return true;
	}
	if (len(nv) > len(hv)) {
		return false;
	}
	for (; i + len(nv) <= len(hv); i++) {
		size_t j = 0;
		for (; j < len(nv); j++) {
			char a = hv[i + j];
			char b = nv[j];
			if (a >= 'A' && a <= 'Z') {
				a = (char)(a - 'A' + 'a');
			}
			if (b >= 'A' && b <= 'Z') {
				b = (char)(b - 'A' + 'a');
			}
			if (a != b) {
				break;
			}
		}
		if (j == len(nv)) {
			return true;
		}
	}
	return false;
}

static int status_rank(const char *s) {
	int i = model_status_index(s);
	if (i < 0) {
		return 100;
	}
	return i;
}

static int task_cmp(const Task *a, const Task *b) {
	if (a == NULL || b == NULL) {
		return 0;
	}
	int ra = status_rank(a.status);
	int rb = status_rank(b.status);
	if (ra != rb) {
		return ra - rb;
	}
	int c = strcmp(a.category, b.category);
	if (c != 0) {
		return c;
	}
	return strcmp(a.title, b.title);
}

void model_sort(TaskStore *store) {
	if (store == NULL || store.count < 2) {
		return;
	}
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

int model_build_visible(TaskStore *store, ViewFilter *f, int[..] out) {
	int i = 0;
	int n = 0;
	int out_cap = (int)len(out);
	if (store == NULL || ptr(out) == NULL || out_cap <= 0 || f == NULL) {
		return 0;
	}
	for (; i < store.count && n < out_cap; i++) {
		Task *t = &store.tasks[i];
		if (!f.show_complete && strcmp(t.status, "E:Complete") == 0) {
			continue;
		}
		if (strlen(f.cc) != 0 && !ascii_icontains(t.cc, f.cc)) {
			continue;
		}
		if (strlen(f.text) != 0) {
			if (!ascii_icontains(t.title, f.text) &&
				!ascii_icontains(t.notes, f.text) &&
				!ascii_icontains(t.cc, f.text) &&
				!ascii_icontains(t.category, f.text) &&
				!ascii_icontains(t.status, f.text)) {
				continue;
			}
		}
		out[n++] = i;
	}
	return n;
}
