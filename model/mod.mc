// model — task records, filter/sort (idiomatic %C: char[..], receivers).
import "str";
import "crash";

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
	TaskTagsCap = 160,
	StoreMaxTasks = 4096,
	FilterTextCap = 128,
	VisibleMax = StoreMaxTasks,
	AttnNamesMax = 64,
	AttnNameCap = 40,
	TagNamesMax = 64,
	TagNameCap = 40
};

struct Task {
	char[..] id;
	char[..] status;
	char[..] title;
	char[..] cc;
	char[..] tags;
	/* space-separated #tags */
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
	char[..] tag;
	/* focus substring against tags field */
	char[..] text;
	bool show_complete;
};

/* Fixed status vocabulary. Set only via cycle / complete. */
static const char* g_statuses[] = {
	"A:Inbox", "B:Now", "C:Soon", "D:Later", "E:Waiting", "F:Complete", "G:Someday", };

int model_status_count() {
	return (int)(sizeof(g_statuses) / sizeof(g_statuses[0]));
}

const char* model_status_at(int i) {
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

static bool field_set_cstr(char[..]* dst, const char* src) {
	return str_set(dst, str_from_cstr(src != NULL ? src: ""));
}

void (Task* t).clear() {
	str_free(&t.id);
	str_free(&t.status);
	str_free(&t.title);
	str_free(&t.cc);
	str_free(&t.tags);
	str_free(&t.updated);
}

void (Task* t).touch() {
	char buf[40] = { 0 };
	int64_t now = time(NULL);
	struct PfTm* tm = gmtime(&now);
	if (tm == NULL) {
		(void)field_set_cstr(&t.updated, "0");
		return;
	}
	snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02dZ", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
	(void)field_set_cstr(&t.updated, buf);
}

/* Deep-copy src into dst (dst must be empty or cleared). */
static bool task_copy_into(Task* dst, const Task* src) {
	if (!field_set(&dst.id, src.id) || !field_set(&dst.status, src.status) || !field_set(&dst.title, src.title) || !field_set(&dst.cc, src.cc) || !field_set(&dst.tags, src.tags) || !field_set(&dst.updated, src.updated)) {
		dst.clear();
		return false;
	}
	return true;
}

void (TaskStore* store).init() {
	for (int i = 0; i < store.count; i++) {
		store.tasks[i].clear();
	}
	memset(store, 0, sizeof(*store));
	store.next_id = 1;
}

void (ViewFilter* f).init() {
	str_free(&f.cc);
	str_free(&f.tag);
	str_free(&f.text);
	memset(f, 0, sizeof(*f));
	f.show_complete = false;
}

Task* (TaskStore* store).get(int index) {
	if (index < 0 || index >= store.count) {
		return NULL;
	}
	return &store.tasks[index];
}

[[nodiscard]] bool (TaskStore* store).add(const Task* src) {
	char idbuf[32] = { 0 };
	if (src == NULL || store.count >= StoreMaxTasks) {
		return false;
	}
	Task* t = &store.tasks[store.count];
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
		if (!field_set_cstr(&t.status, "A:Inbox")) {
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

[[nodiscard]] bool (TaskStore* store).remove(int index) {
	Task* t = store.get(index);
	if (t == NULL) {
		return false;
	}
	t.clear();
	for (int i = index; i + 1 < store.count; i++) {
		store.tasks[i] = store.tasks[i + 1];
	}
	memset(&store.tasks[store.count - 1], 0, sizeof(Task));
	store.count--;
	store.dirty = true;
	return true;
}

[[nodiscard]] bool (TaskStore* store).set_status(int index, const char[..] status) {
	Task* t = store.get(index);
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

[[nodiscard]] bool (TaskStore* store).cycle_status(int index) {
	Task* t = store.get(index);
	int n = model_status_count();
	int tries = 0;
	if (t == NULL) {
		return false;
	}
	if (n <= 0) {
		panic("modfocus: empty status table");
	}
	int i = model_status_index(t.status);
	if (i < 0) {
		i = 0;
	}
	do {
		i = (i + 1) % n;
		tries++;
	}
	while (tries < n && strcmp(g_statuses[i], "F:Complete") == 0);
	return store.set_status(index, str_from_cstr(g_statuses[i]));
}

[[nodiscard]] bool (TaskStore* store).set_title(int index, const char[..] title) {
	Task* t = store.get(index);
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

static bool attn_is_space(char c) {
	return c == ' ' || c == '\t';
}

static bool attn_has_comma(const char[..] src) {
	for (auto c: src) {
		if (c == ',') {
			return true;
		}
	}
	return false;
}

/* Collapse internal whitespace; result is pool-backed. */
static(char[..], bool) attn_collapse_name([[region]] Pool * p, const char[..] src) {
	char[..] dst = { 0 };
	bool sp = false;
	for (auto c: src) {
		if (attn_is_space(c)) {
			sp = true;
			continue;
		}
		if (sp && len(dst) > 0) {
			if (!p.append(&dst, " ")) {
				return (str_empty(), false);
			}
		}
		sp = false;
		if (!p.push(&dst, c)) {
			return (str_empty(), false);
		}
	}
	return (dst, true);
}

static(char[..], bool) attn_append_name([[region]] Pool * p, char[..] out, const char[..] raw) {
	auto (name, nok) = attn_collapse_name(p, raw);
	if (!nok) {
		return (str_empty(), false);
	}
	if (len(name) == 0) {
		return (out, true);
	}
	if (len(out) > 0) {
		if (!p.append(&out, ", ") || !p.append(&out, name)) {
			return (str_empty(), false);
		}
	} else if (!p.append(&out, name)) {
		return (str_empty(), false);
	}
	return (out, true);
}

/*
 * Attn names joined with ", " (pool-backed).
 * If src has any comma → split on commas (spaces inside a name kept, collapsed).
 * Else → split on whitespace ("Brian Jessica" → "Brian, Jessica").
 */
static(char[..], bool) normalize_attn([[region]] Pool * p, const char[..] src) {
	char[..] out = { 0 };
	size_t i = 0;
	if (attn_has_comma(src)) {
		while (i < len(src)) {
			size_t start = i;
			size_t end = 0;
			while (i < len(src) && src[i] != ',') {
				i++;
			}
			end = i;
			auto (nout, ok) = attn_append_name(p, out, src[start .. end]);
			if (!ok) {
				return (str_empty(), false);
			}
			out = nout;
			if (i < len(src) && src[i] == ',') {
				i++;
			}
		}
	} else {
		while (i < len(src)) {
			size_t start = 0;
			size_t end = 0;
			while (i < len(src) && attn_is_space(src[i])) {
				i++;
			}
			start = i;
			while (i < len(src) && !attn_is_space(src[i])) {
				i++;
			}
			end = i;
			if (end > start) {
				auto (nout, ok) = attn_append_name(p, out, src[start .. end]);
				if (!ok) {
					return (str_empty(), false);
				}
				out = nout;
			}
		}
	}
	return (out, true);
}

[[nodiscard]] bool (TaskStore* store).set_cc(int index, const char[..] cc) {
	Task* t = store.get(index);
	if (t == NULL) {
		return false;
	}
	pool p {
		auto (norm, ok) = normalize_attn(&p, cc);
		if (!ok || !field_set(&t.cc, norm)) {
			return false;
		}
		t.touch();
		store.dirty = true;
		return true;
	}
}

static char ascii_lower(char c) {
	if (c >= 'A' && c <= 'Z') {
		return (char)(c - 'A' + 'a');
	}
	return c;
}

static bool ascii_istartswith(const char[..] s, const char[..] prefix) {
	size_t i = 0;
	if (len(prefix) > len(s)) {
		return false;
	}
	for (auto pc: prefix) {
		if (ascii_lower(s[i]) != ascii_lower(pc)) {
			return false;
		}
		i++;
	}
	return true;
}

static bool ascii_ieq(const char[..] a, const char[..] b) {
	size_t i = 0;
	if (len(a) != len(b)) {
		return false;
	}
	for (auto ca: a) {
		if (ascii_lower(ca) != ascii_lower(b[i])) {
			return false;
		}
		i++;
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

/* Tags: space/comma-separated; each as #name (pool-backed). */
static(char[..], bool) normalize_tags([[region]] Pool * p, const char[..] src) {
	char[..] out = { 0 };
	char one[TagNameCap + 2] = { 0 };
	size_t i = 0;
	while (i < len(src)) {
		size_t start = 0;
		size_t end = 0;
		size_t n = 0;
		bool seen = false;
		while (i < len(src) && (src[i] == ' ' || src[i] == '\t' || src[i] == ',')) {
			i++;
		}
		start = i;
		while (i < len(src) && src[i] != ' ' && src[i] != '\t' && src[i] != ',') {
			i++;
		}
		end = i;
		if (end <= start) {
			continue;
		}
		if (src[start] == '#') {
			start++;
		}
		while (start < end && (src[start] == ' ' || src[start] == '\t')) {
			start++;
		}
		while (end > start && (src[end - 1] == ' ' || src[end - 1] == '\t')) {
			end--;
		}
		if (end <= start) {
			continue;
		}
		n = end - start;
		if (n > TagNameCap) {
			n = TagNameCap;
		}
		one[0] = '#';
		memcpy(one + 1, ptr(src) + start, n);
		one[n + 1] = 0;
		{
			const char[..] nv = ranged(one, n + 1);
			size_t oi = 0;
			while (oi < len(out)) {
				size_t os = 0;
				size_t oe = 0;
				while (oi < len(out) && out[oi] == ' ') {
					oi++;
				}
				os = oi;
				while (oi < len(out) && out[oi] != ' ') {
					oi++;
				}
				oe = oi;
				if (oe > os && ascii_ieq(out[os .. oe], nv)) {
					seen = true;
					break;
				}
			}
			if (seen) {
				continue;
			}
			if (len(out) > 0) {
				if (!p.append(&out, " ") || !p.append(&out, nv)) {
					return (str_empty(), false);
				}
			} else if (!p.append(&out, nv)) {
				return (str_empty(), false);
			}
		}
	}
	return (out, true);
}

[[nodiscard]] bool (TaskStore* store).set_tags(int index, const char[..] tags) {
	Task* t = store.get(index);
	if (t == NULL) {
		return false;
	}
	pool p {
		auto (norm, ok) = normalize_tags(&p, tags);
		if (!ok || !field_set(&t.tags, norm)) {
			return false;
		}
		t.touch();
		store.dirty = true;
		return true;
	}
}

static bool tag_body_char(char c) {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
}

static bool tag_start_char(char c) {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

/*
 * Pull whitespace-bounded #tags (must start with a letter) out of src.
 * Returns pool-backed title and normalized tags.
 */
[[nodiscard]](char[..], char[..], bool) model_parse_title_tags([[region]] Pool * p, const char[..] src) {
	char[..] title = { 0 };
	char[..] tags_raw = { 0 };
	size_t i = 0;
	bool sp = false;
	if (p == NULL) {
		return (str_empty(), str_empty(), false);
	}
	while (i < len(src)) {
		bool at_bound = (i == 0) || src[i - 1] == ' ' || src[i - 1] == '\t';
		if (at_bound && src[i] == '#' && i + 1 < len(src) && tag_start_char(src[i + 1])) {
			size_t start = i;
			size_t end = i + 1;
			while (end < len(src) && tag_body_char(src[end])) {
				end++;
			}
			/* Only a tag if ended by whitespace/end (not issue#12 glued). */
			if (end >= len(src) || src[end] == ' ' || src[end] == '\t') {
				const char[..] tok = src[start .. end];
				if (len(tags_raw) > 0) {
					if (!p.append(&tags_raw, " ") || !p.append(&tags_raw, tok)) {
						return (str_empty(), str_empty(), false);
					}
				} else if (!p.append(&tags_raw, tok)) {
					return (str_empty(), str_empty(), false);
				}
				i = end;
				continue;
			}
		}
		char ch = src[i];
		if (ch == ' ' || ch == '\t') {
			sp = true;
			i++;
			continue;
		}
		if (sp && len(title) > 0) {
			if (!p.append(&title, " ")) {
				return (str_empty(), str_empty(), false);
			}
		}
		sp = false;
		if (!p.push(&title, ch)) {
			return (str_empty(), str_empty(), false);
		}
		i++;
	}
	auto (tags, tok) = normalize_tags(p, tags_raw);
	if (!tok) {
		return (str_empty(), str_empty(), false);
	}
	return (title, tags, true);
}

/* Write "title #a #b" into dst (fixed buffer). */
[[nodiscard]] bool model_format_title_tags(const char[..] title, const char[..] tags, char[..] dst) {
	if (ptr(dst) == NULL || cap(dst) == 0) {
		return false;
	}
	size_t need = len(title);
	if (len(title) > 0 && len(tags) > 0) {
		need += 1;
	}
	need += len(tags);
	if (need + 1 > cap(dst)) {
		return false;
	}
	size_t off = 0;
	if (len(title) > 0) {
		memcpy(ptr(dst) + off, ptr(title), len(title));
		off += len(title);
	}
	if (len(title) > 0 && len(tags) > 0) {
		dst[off] = ' ';
		off++;
	}
	if (len(tags) > 0) {
		memcpy(ptr(dst) + off, ptr(tags), len(tags));
		off += len(tags);
	}
	dst[off] = 0;
	return true;
}

struct NameEntry {
	char[..] s;
};

static void names_free(NameEntry[..] names, int count) {
	if (count <= 0) {
		return;
	}
	for (auto* n: names[0 ..(size_t)count]) {
		str_free(&n.s);
	}
}

static bool names_push_unique(NameEntry[..] names, int* count, const char[..] nv) {
	if (count == NULL ||*count < 0) {
		return false;
	}
	if (*count > 0) {
		for (auto n: names[0 ..(size_t)* count]) {
			if (ascii_ieq(n.s, nv)) {
				return true;
			}
		}
	}
	if (*count >= (int)len(names)) {
		return true;
	}
	if (!field_set(&names[*count].s, nv)) {
		names_free(names,*count);
		*count = 0;
		return false;
	}
	(*count)++;
	return true;
}

static int collect_attn_names(const TaskStore* store, NameEntry[..] names) {
	int count = 0;
	if (store == NULL || ptr(names) == NULL) {
		return 0;
	}
	if (store.count > 0) {
		for (auto t: store.tasks[0 ..(size_t)store.count]) {
			const char[..] cc = t.cc;
			size_t i = 0;
			while (i < len(cc)) {
				size_t start = 0;
				size_t end = 0;
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
				if (end > start && !names_push_unique(names, &count, cc[start .. end])) {
					return 0;
				}
				if (i < len(cc) && cc[i] == ',') {
					i++;
				}
			}
		}
	}
	return count;
}

static int collect_tag_names(const TaskStore* store, NameEntry[..] names) {
	int count = 0;
	if (store == NULL || ptr(names) == NULL) {
		return 0;
	}
	if (store.count > 0) {
		for (auto t: store.tasks[0 ..(size_t)store.count]) {
			const char[..] tags = t.tags;
			size_t i = 0;
			while (i < len(tags)) {
				size_t start = 0;
				size_t end = 0;
				while (i < len(tags) && (tags[i] == ' ' || tags[i] == '\t')) {
					i++;
				}
				start = i;
				while (i < len(tags) && tags[i] != ' ' && tags[i] != '\t') {
					i++;
				}
				end = i;
				if (end > start && !names_push_unique(names, &count, tags[start .. end])) {
					return 0;
				}
			}
		}
	}
	return count;
}

/*
 * Match names against prefix; write the unique match or shared LCP into out.
 * False if no match, or if multiple matches share only the current prefix.
 */
static bool complete_from_names(NameEntry[..] names, int n, const char[..] prefix, char[..] out) {
	int matches = 0;
	int first = -1;
	size_t common = 0;
	if (ptr(out) == NULL || cap(out) == 0) {
		return false;
	}
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
			while (k < common && k < len(a) && k < len(cand) && ascii_lower(a[k]) == ascii_lower(cand[k])) {
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
		(void)cstr_write(out, a[0 .. common]);
		return common > len(prefix);
	}
}

/* out is a writable fixed buffer view (e.g. ranged(stack, n)); uses cstr_write. */
[[nodiscard]] bool (TaskStore* store).attn_complete(const char[..] prefix, char[..] out) {
	NameEntry names[AttnNamesMax] = { 0 };
	int n = collect_attn_names(store, ranged(names, AttnNamesMax));
	defer names_free(ranged(names, AttnNamesMax), n);
	return complete_from_names(ranged(names, AttnNamesMax), n, prefix, out);
}

/* Complete a tag token; prefix may omit leading #. Writes #name into out. */
[[nodiscard]] bool (TaskStore* store).tag_complete(const char[..] prefix, char[..] out) {
	NameEntry names[TagNamesMax] = { 0 };
	char wantbuf[TagNameCap + 2] = { 0 };
	const char[..] want = { 0 };
	if (len(prefix) > 0 && prefix[0] == '#') {
		want = prefix;
	} else if (len(prefix) + 1 < sizeof(wantbuf)) {
		wantbuf[0] = '#';
		if (len(prefix) > 0) {
			memcpy(wantbuf + 1, ptr(prefix), len(prefix));
		}
		wantbuf[len(prefix) + 1] = 0;
		want = ranged(wantbuf, len(prefix) + 1);
	} else {
		return false;
	}
	int n = collect_tag_names(store, ranged(names, TagNamesMax));
	defer names_free(ranged(names, TagNamesMax), n);
	return complete_from_names(ranged(names, TagNamesMax), n, want, out);
}

static int status_rank(const char[..] s) {
	int i = model_status_index(s);
	if (i < 0) {
		return 100;
	}
	return i;
}

static int task_cmp(const Task* a, const Task* b) {
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

void (TaskStore* store).sort() {
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

int (TaskStore* store).build_visible(const ViewFilter* f, int[..] out) {
	int n = 0;
	int out_cap = (int)len(out);
	if (f == NULL || ptr(out) == NULL || out_cap <= 0) {
		return 0;
	}
	for (int i = 0; i < store.count && n < out_cap; i++) {
		Task* t = &store.tasks[i];
		if (!f.show_complete && str_eq_cstr(t.status, "F:Complete")) {
			continue;
		}
		if (len(f.cc) != 0 && !ascii_icontains(t.cc, f.cc)) {
			continue;
		}
		if (len(f.tag) != 0 && !ascii_icontains(t.tags, f.tag)) {
			continue;
		}
		if (len(f.text) != 0) {
			if (!ascii_icontains(t.title, f.text) && !ascii_icontains(t.cc, f.text) && !ascii_icontains(t.tags, f.text) && !ascii_icontains(t.status, f.text)) {
				continue;
			}
		}
		out[n++] = i;
	}
	return n;
}

/* Replace task at index with a deep copy of src (for LWW merge). */
[[nodiscard]] bool (TaskStore* store).replace(int index, const Task* src) {
	if (src == NULL) {
		return false;
	}
	Task* t = store.get(index);
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
