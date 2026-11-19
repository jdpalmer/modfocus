// store — JSON load/save for TaskStore.
import "model";
import "json";
import "fs";
import "os";
import "path";
import "str";

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

static void field_set(char[..] dst, const char *src) {
	size_t n = cap(dst);
	if (ptr(dst) == NULL || n == 0) {
		return;
	}
	(void)snprintf(ptr(dst), n, "%s", src != NULL ? src : "");
}

static const char *obj_str(const JsonValue *obj, const char *key) {
	if (obj == NULL || key == NULL) {
		return "";
	}
	const JsonValue *v = json_object_get(obj, key);
	const char *s = json_string_value(v);
	return s != NULL ? s : "";
}

bool store_default_path(char[..] dst) {
	auto (env_ok, env) = os_env("Q2DB");
	if (ptr(dst) == NULL || cap(dst) == 0) {
		return false;
	}
	if (env_ok && len(env) > 0) {
		(void)snprintf(ptr(dst), cap(dst), "%s", env);
		return true;
	}
	pool p {
		auto (cfg, cok) = os_user_config_dir(&p);
		if (!cok) {
			return false;
		}
		auto (dir, dok) = path_join(&p, cfg, "q2");
		if (!dok) {
			return false;
		}
		auto (file, fok) = path_join(&p, dir, "tasks.json");
		if (!fok) {
			return false;
		}
		(void)snprintf(ptr(dst), cap(dst), "%s", file);
		return true;
	}
}

bool store_ensure_parent_dir(const char[..] db_path) {
	const char[..] parent = path_dir(db_path);
	if (len(parent) == 0) {
		return true;
	}
	(void)fs_mkdir(parent);
	return true;
}

static (char[..], bool) read_file_all(const char[..] path) {
	auto (r, ok) = reader_open(path, OpenRead, 0);
	char[..] data = str_empty();
	if (!ok) {
		return (str_empty(), false);
	}
	defer r.close();
	for (;;) {
		char chunk[8192] = {0};
		auto (n, rok) = r.read(ranged(chunk, sizeof(chunk)));
		if (!rok) {
			str_free(&data);
			return (str_empty(), false);
		}
		if (n == 0) {
			break;
		}
		if (!str_append(&data, ranged(chunk, n))) {
			str_free(&data);
			return (str_empty(), false);
		}
	}
	return (data, true);
}

bool store_load(TaskStore *store, const char[..] path) {
	JsonError err = {0};
	size_t i = 0;
	if (store == NULL) {
		return false;
	}
	model_init(store);
	auto (text, tok) = read_file_all(path);
	if (!tok) {
		return false;
	}
	defer str_free(&text);
	JsonValue *root = json_parse_n(ptr(text), len(text), &err);
	if (root == NULL) {
		return false;
	}
	defer json_free(root);
	if (root.type != JSON_OBJECT) {
		return false;
	}
	const JsonValue *tasks = json_object_get(root, "tasks");
	if (tasks == NULL || tasks.type != JSON_ARRAY) {
		return true;
	}
	for (; i < json_array_size(tasks); i++) {
		const JsonValue *item = json_array_get(tasks, i);
		Task t = {0};
		if (item == NULL || item.type != JSON_OBJECT) {
			continue;
		}
		field_set(ranged(t.id, sizeof(t.id)), obj_str(item, "id"));
		field_set(ranged(t.status, sizeof(t.status)), obj_str(item, "status"));
		field_set(ranged(t.category, sizeof(t.category)), obj_str(item, "category"));
		field_set(ranged(t.title, sizeof(t.title)), obj_str(item, "title"));
		field_set(ranged(t.cc, sizeof(t.cc)), obj_str(item, "cc"));
		field_set(ranged(t.due, sizeof(t.due)), obj_str(item, "due"));
		field_set(ranged(t.notes, sizeof(t.notes)), obj_str(item, "notes"));
		field_set(ranged(t.updated, sizeof(t.updated)), obj_str(item, "updated"));
		if (strlen(t.title) == 0 && strlen(t.id) == 0) {
			continue;
		}
		if (!model_add(store, &t)) {
			break;
		}
	}
	store.dirty = false;
	model_sort(store);
	return true;
}

bool store_save(TaskStore *store, const char[..] path) {
	char tmp[1024] = {0};
	int i = 0;
	if (store == NULL) {
		return false;
	}
	if (!store_ensure_parent_dir(path)) {
		return false;
	}
	JsonValue *root = json_new_object();
	if (root == NULL) {
		return false;
	}
	defer json_free(root);
	if (!json_object_set(root, "version", json_new_number(1))) {
		return false;
	}
	JsonValue *arr = json_new_array();
	if (arr == NULL) {
		return false;
	}
	if (!json_object_set(root, "tasks", arr)) {
		return false;
	}
	arr = json_object_get_mutable(root, "tasks");
	for (; i < store.count; i++) {
		Task *t = &store.tasks[i];
		JsonValue *obj = json_new_object();
		if (obj == NULL) {
			return false;
		}
		if (!json_object_set(obj, "id", json_new_string(t.id)) ||
			!json_object_set(obj, "status", json_new_string(t.status)) ||
			!json_object_set(obj, "category", json_new_string(t.category)) ||
			!json_object_set(obj, "title", json_new_string(t.title)) ||
			!json_object_set(obj, "cc", json_new_string(t.cc)) ||
			!json_object_set(obj, "due", json_new_string(t.due)) ||
			!json_object_set(obj, "notes", json_new_string(t.notes)) ||
			!json_object_set(obj, "updated", json_new_string(t.updated))) {
			json_free(obj);
			return false;
		}
		if (!json_array_append(arr, obj)) {
			return false;
		}
	}
	char *text = json_stringify(root);
	if (text == NULL) {
		return false;
	}
	defer free(text);
	(void)snprintf(tmp, sizeof(tmp), "%s.tmp", path);
	{
		auto (w, wok) = writer_open(ranged(tmp, strlen(tmp)), OpenWrite | OpenCreate | OpenTrunc, 0);
		if (!wok) {
			return false;
		}
		defer w.close();
		auto (n, ok) = w.write(str_from_cstr(text));
		if (!ok || n != (int64_t)strlen(text)) {
			return false;
		}
		if (!w.flush()) {
			return false;
		}
	}
	if (!fs_rename(ranged(tmp, strlen(tmp)), path)) {
		(void)fs_remove(ranged(tmp, strlen(tmp)));
		return false;
	}
	store.dirty = false;
	return true;
}

bool store_import_file(TaskStore *store, const char[..] src, const char[..] dst) {
	/* Static: TaskStore is too large for a QBE stack frame. */
	static TaskStore seed;
	model_init(&seed);
	if (!store_load(&seed, src)) {
		return false;
	}
	/* Merge into existing dest when present; otherwise seed becomes the DB. */
	if (!store_load(store, dst)) {
		model_init(store);
	}
	(void)store_merge(store, &seed);
	store.dirty = true;
	return store_save(store, dst);
}

static int store_find_id(const TaskStore *store, const char *id) {
	int i = 0;
	if (store == NULL || id == NULL || strlen(id) == 0) {
		return -1;
	}
	for (; i < store.count; i++) {
		if (strcmp(store.tasks[i].id, id) == 0) {
			return i;
		}
	}
	return -1;
}

/* ISO-8601 timestamps from model_touch; empty counts as oldest. */
static int updated_cmp(const char *a, const char *b) {
	bool a_empty = a == NULL || strlen(a) == 0;
	bool b_empty = b == NULL || strlen(b) == 0;
	if (a_empty && b_empty) {
		return 0;
	}
	if (a_empty) {
		return -1;
	}
	if (b_empty) {
		return 1;
	}
	return strcmp(a, b);
}

/*
 * Task-level last-write-wins merge by id + updated.
 * Incoming tasks newer than local replace; incoming-only tasks are appended.
 * Local-only tasks are kept. Equal updated keeps local (stable).
 * Returns true if local changed.
 */
bool store_merge(TaskStore *local, const TaskStore *incoming) {
	int i = 0;
	bool changed = false;
	if (local == NULL || incoming == NULL) {
		return false;
	}
	for (; i < incoming.count; i++) {
		const Task *src = &incoming.tasks[i];
		int at = store_find_id(local, src.id);
		if (at < 0) {
			Task copy = *src;
			if (!model_add(local, &copy)) {
				break;
			}
			changed = true;
			continue;
		}
		if (updated_cmp(src.updated, local.tasks[at].updated) > 0) {
			local.tasks[at] = *src;
			changed = true;
			local.dirty = true;
		}
	}
	return changed;
}
